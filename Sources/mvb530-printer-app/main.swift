/// mvb530-printer-app - an IPP Everywhere printer application for MV-B530
/// class thermal printers.
///
/// One process: an IPP service in the user's login session, advertised over
/// DNS-SD so macOS discovers it as a driverless printer, talking BLE to the
/// hardware itself.
///
///   - No PPD, no /usr/libexec/cups. CUPS 3.x removes PPD and filter support
///     entirely, which the previous design was built on.
///   - No separate transport agent. CoreBluetooth works here, but only if the
///     central manager is created on the main queue *after* papplMainloop has
///     started - see startTransport().
///   - No root. Nothing is installed into system directories.
import CPAPPL
import Foundation
import MVBTransport
import ServiceManagement

let driverName = "mvb530"
let driverDescription = "Anko Inkless A4 (MV-B530)"

/// Fills in what the printer can do, and wires up the raster callbacks.
let driverCallback: pappl_pr_driver_cb_t = {
    system, name, deviceURI, deviceID, driverData, driverAttrs, _ in

    guard let driverData else { return false }
    _ = (name, deviceURI, deviceID)

    // Only the name is worth setting. Location, geo-location, organisation
    // and contact are IPP deployment metadata for managed office fleets -
    // which floor a printer is on, who administers it. Filling them with
    // invented values for a printer on someone's desk is noise, not
    // information, so they are left empty for the owner to use or ignore.
    if let system {
        papplSystemSetDNSSDName(system, "Anko Inkless A4")
        papplSystemSetFooterHTML(system, """
            Anko Inkless A4 thermal printer (MV-B530 and clones), driven over             Bluetooth LE at 200&nbsp;dpi. The printer must be switched on to             accept a job; jobs submitted while it is asleep wait for it.
            <a href="https://github.com/hmvs/mv-b530-macos-cups-driver">Source</a>
            """)
    }

    // PAPPL zeroes the struct for us; only set what differs from the default.
    driverData.pointee.rstartjob_cb = startJobCallback
    driverData.pointee.rstartpage_cb = startPageCallback
    driverData.pointee.rwriteline_cb = writeLineCallback
    driverData.pointee.rendpage_cb = endPageCallback
    driverData.pointee.rendjob_cb = endJobCallback
    driverData.pointee.testpage_cb = testPageCallback
    driverData.pointee.printfile_cb = printFileCallback
    // Names the format a job file may be handed to printfile_cb in. Without
    // it PAPPL aborts file jobs - the test page among them - for want of a
    // filter, even though it is the format this printer already advertises.
    driverData.pointee.format = UnsafePointer(strdup("image/pwg-raster"))
    driverData.pointee.identify_cb = identifyCallback
    driverData.pointee.status_cb = statusUpdateCallback

    withUnsafeMutablePointer(to: &driverData.pointee.make_and_model) { field in
        field.withMemoryRebound(to: CChar.self, capacity: 128) { buffer in
            _ = strlcpy(buffer, "Anko Inkless A4 MV-B530", 128)
        }
    }

    driverData.pointee.kind = PAPPL_KIND_DOCUMENT.rawValue
    driverData.pointee.ppm = 6                  // roughly one A4 page per 6s

    // 200 dpi, greyscale only: it is a direct thermal head.
    driverData.pointee.num_resolution = 1
    driverData.pointee.x_resolution.0 = 200
    driverData.pointee.y_resolution.0 = 200
    driverData.pointee.x_default = 200
    driverData.pointee.y_default = 200

    driverData.pointee.raster_types = PAPPL_PWG_RASTER_TYPE_SGRAY_8.rawValue
        | PAPPL_PWG_RASTER_TYPE_BLACK_1.rawValue
    driverData.pointee.force_raster_type = PAPPL_PWG_RASTER_TYPE_SGRAY_8.rawValue
    driverData.pointee.color_supported = PAPPL_COLOR_MODE_MONOCHROME.rawValue
        | PAPPL_COLOR_MODE_AUTO_MONOCHROME.rawValue
    driverData.pointee.color_default = PAPPL_COLOR_MODE_MONOCHROME.rawValue

    // 1600 dots at 200 dpi is 203.2 mm; A4 is 210 mm, so 3.4 mm each side.
    driverData.pointee.borderless = false
    driverData.pointee.left_right = 340         // hundredths of a millimetre
    driverData.pointee.bottom_top = 0

    driverData.pointee.num_media = 3
    driverData.pointee.media.0 = UnsafePointer(strdup("iso_a4_210x297mm"))
    driverData.pointee.media.1 = UnsafePointer(strdup("iso_a5_148x210mm"))
    driverData.pointee.media.2 = UnsafePointer(strdup("na_letter_8.5x11in"))

    driverData.pointee.num_source = 1
    driverData.pointee.source.0 = UnsafePointer(strdup("main"))

    driverData.pointee.num_type = 2
    driverData.pointee.type.0 = UnsafePointer(strdup("stationery"))
    driverData.pointee.type.1 = UnsafePointer(strdup("labels"))

    // Darkness maps onto the printer's 1..5 blackening levels.
    driverData.pointee.darkness_configured = 50
    driverData.pointee.darkness_supported = 5

    var media = pappl_media_col_t()
    withUnsafeMutablePointer(to: &media.size_name) { field in
        field.withMemoryRebound(to: CChar.self, capacity: 64) { buffer in
            _ = strlcpy(buffer, "iso_a4_210x297mm", 64)
        }
    }
    withUnsafeMutablePointer(to: &media.source) { field in
        field.withMemoryRebound(to: CChar.self, capacity: 64) { buffer in
            _ = strlcpy(buffer, "main", 64)
        }
    }
    withUnsafeMutablePointer(to: &media.type) { field in
        field.withMemoryRebound(to: CChar.self, capacity: 64) { buffer in
            _ = strlcpy(buffer, "stationery", 64)
        }
    }
    media.size_width = 21000
    media.size_length = 29700
    media.left_margin = 340
    media.right_margin = 340
    media.top_margin = 0
    media.bottom_margin = 0
    driverData.pointee.media_default = media
    driverData.pointee.media_ready.0 = media

    _ = driverAttrs
    return true
}

/// Sets the DNS-SD name clients show. Deliberately does not touch location,
/// organisation or contact - see the note in the driver callback.
func describePrinter(_ printer: OpaquePointer?) {
    guard let printer else { return }
    papplPrinterSetDNSSDName(printer, "Anko Inkless A4")
}

/// Identify-Printer: the only thing this hardware can do on demand is feed a
/// little paper, which is enough to tell two printers apart.
let identifyCallback: pappl_pr_identify_cb_t = { printer, actions, message in
    _ = (printer, actions, message)
}

var drivers = [
    pappl_pr_driver_t(
        name: strdup(driverName),
        description: strdup(driverDescription),
        device_id: strdup("MFG:KM;MDL:P800;CMD:MVB530;"),
        extension: nil
    )
]

// A double-clicked app inherits no environment worth the name, so these can
// also be set in the config file, as mvb530-wait and mvb530-printer.
if let waitValue = ProcessInfo.processInfo.environment["MVB530_WAIT"]
    ?? configuredValue("mvb530-wait"), let seconds = Double(waitValue) {
    printerWaitSeconds = seconds
}
if let pinned = ProcessInfo.processInfo.environment["MVB530_PRINTER"]
    ?? configuredValue("mvb530-printer"), !pinned.isEmpty {
    pinnedPrinterName = pinned
}

/// How dark a grey has to be before it is printed, for text and line art.
/// Raise it to catch fainter rules, lower it if pages come out too heavy.
let configuredThreshold = configuredValue("mvb530-threshold")
    .flatMap(Int.init).map { min(254, max(1, $0)) } ?? lineArtThreshold

registerBluetoothScheme()

/// Port the bundled app listens on.
///
/// A double-clicked app has no command line and no environment to speak of,
/// so the port is read back from the config file the app itself writes. That
/// makes the file the place to change it - and the queue is repointed to
/// match on the next start, so the two cannot drift.
let defaultIPPPort = configuredValue("server-port").flatMap(Int.init).map { max($0, 1) }
    ?? Int(ProcessInfo.processInfo.environment["MVB530_PORT"] ?? "")
    ?? 8631

/// The config file the bundle reads and writes.
///
/// PAPPL looks for it by argv[0]'s base name, and reads any name=value lines
/// as if they had been given on the command line.
func configurationURL() -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first
    else { return nil }
    let baseName = (CommandLine.arguments[0] as NSString).lastPathComponent
    return support.appendingPathComponent("\(baseName).conf")
}

/// The lines currently in that file, comments and blanks dropped.
func configurationLines() -> [String] {
    guard let url = configurationURL(),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").map(String.init).filter {
        !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The value recorded for a setting, if there is one.
func configuredValue(_ key: String) -> String? {
    configurationLines()
        .first { $0.hasPrefix("\(key)=") }
        .map { String($0.dropFirst(key.count + 1)) }
}

/// Ask macOS to start the app at login.
///
/// SMAppService puts it in System Settings > General > Login Items, where it
/// can be seen and switched off, rather than a LaunchAgent plist the user
/// never knows exists. Failing is not fatal: the app still runs now, it just
/// will not come back after a reboot.
func registerAsLoginItem() {
    guard #available(macOS 13.0, *) else { return }
    let service = SMAppService.mainApp
    switch service.status {
    case .enabled:
        return
    case .requiresApproval:
        deviceLog("login item needs approval in System Settings > Login Items")
        return
    default:
        break
    }
    do {
        try service.register()
        deviceLog("registered to start at login")
    } catch {
        deviceLog("could not register as a login item: \(error.localizedDescription)")
    }
}

/// Writes the settings a bundled launch cannot pass on the command line.
///
/// The file is named after argv[0]'s base name because that is how PAPPL
/// looks for it, and it is rewritten in full every start: turning sharing off
/// has to remove the listen-hostname line, not merely stop adding it.
func writeBundleConfiguration(port: Int, shared: Bool) {
    guard let url = configurationURL() else { return }

    // Anything the owner put here is kept; only the lines this decides are
    // replaced, so turning sharing off removes listen-hostname rather than
    // leaving a stale one behind.
    let managed = ["server-port=", "server-options=", "listen-hostname="]
    var lines = configurationLines().filter { line in
        !managed.contains { line.hasPrefix($0) }
    }

    lines.append("server-port=\(port)")
    lines.append("server-options=no-tls,no-multi-queue")
    if !shared {
        lines.append("listen-hostname=localhost")
    }

    let header = """
        # Read by Anko Inkless A4 at start-up. Settings you add are kept;
        # server-port, server-options and listen-hostname are rewritten.
        # Recognised here as well: mvb530-wait, mvb530-printer.
        """
    try? ([header] + lines).joined(separator: "\n").appending("\n")
        .write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Network exposure
//
// PAPPL binds every interface by default, which means joining any Wi-Fi
// advertises this printer to that network - and its admin pages take no
// authentication, so anyone there could print to it or change its settings.
// Private is therefore the default, and sharing has to be asked for.
//
// The switch lives in the web interface, under Network, and is persisted;
// this reads it at start-up. The flag and environment variable remain for
// running the server by hand.
//
//   Network page          the normal way to change it
//   --share               bind all interfaces
//   MVB530_SHARE=1        the same, for a LaunchAgent
//
// An explicit -o listen-hostname=... on the command line always wins.

var arguments = CommandLine.arguments

let shareRequested = arguments.contains("--share")
    || ["1", "true", "yes"].contains(
        (ProcessInfo.processInfo.environment["MVB530_SHARE"] ?? "").lowercased())
    || isSharingEnabled()

// --share is ours, not PAPPL's; it would reject an option it does not know.
arguments.removeAll { $0 == "--share" }

// Inside a .app, PAPPL throws our command line away. papplMainloop replaces
// argc/argv with its own "server" invocation whenever argv[0] contains
// ".app/Contents/MacOS/", so options passed here never reach it. What it does
// still read is a config file named after argv[0], which is where the bundle's
// settings have to go. Options given on the command line keep priority:
// PAPPL's load_options only fills in what is unset.
let launchedFromBundle = arguments[0].contains(".app/Contents/MacOS/")

if launchedFromBundle {
    registerAsLoginItem()
    writeBundleConfiguration(port: defaultIPPPort, shared: shareRequested)
} else {
    let hostnameAlreadySet = arguments.contains { $0.hasPrefix("listen-hostname=") }
    if !shareRequested && !hostnameAlreadySet {
        arguments += ["-o", "listen-hostname=localhost"]
    }
}

var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
argv.append(nil)

// CoreBluetooth has to be created on the main queue *after* papplMainloop
// brings up NSApplication, whose run loop services that queue. Created before
// it, or on a worker thread, the central manager never leaves .unknown and no
// state callback is ever delivered. papplMainloop blocks, so this is queued
// now and runs once the run loop is live.
DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: startTransport)

// A bundle has no install step, so it sets itself up once the server answers.
if launchedFromBundle {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
        performFirstRunSetup(port: defaultIPPPort)
    }
}

// PAPPL must own the main thread on macOS: it creates an NSStatusItem, and
// AppKit throws "NSWindow should only be instantiated on the main thread".
//
// So bring CoreBluetooth up here first, while we still are the main thread.
// Created lazily from a PAPPL worker instead, the central manager never
// leaves .unknown and no state callback is ever delivered.
// The agent owns the radio; nothing to warm up here.

exit(papplMainloop(
    Int32(arguments.count),
    &argv,
    "1.0",
    """
    <p>Anko Inkless A4 thermal printer (MV-B530 and clones), driven over \
    Bluetooth LE. 200&nbsp;dpi greyscale, A4 / A5 / US&nbsp;Letter.<br>
    The printer must be switched on to accept a job; jobs submitted while it \
    is asleep wait for it. <br>
    <a href="https://github.com/hmvs/mv-b530-macos-cups-driver">\
    github.com/hmvs/mv-b530-macos-cups-driver</a></p>
    """,                    // footer HTML
    Int32(drivers.count),
    &drivers,
    autoAddCallback,
    driverCallback,
    nil,                    // extra subcommand name
    nil,                    // extra subcommand callback
    nil,                    // system callback
    nil,                    // usage callback
    nil                     // callback data
))
