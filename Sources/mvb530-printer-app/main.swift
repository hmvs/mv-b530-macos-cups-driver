/// mvb530-printer-app - an IPP Everywhere printer application for MV-B530
/// class thermal printers.
///
/// This replaces the CUPS filter + backend + agent trio. PAPPL runs an IPP
/// service in the user's login session and advertises it over DNS-SD, so
/// macOS discovers it as a driverless printer. Three consequences:
///
///   - No PPD, no /usr/libexec/cups. CUPS 3.x removes PPD and filter support
///     entirely, which the previous design was built on.
///   - No separate agent. The process is already a user agent, so
///     CoreBluetooth and its TCC grant work here directly.
///   - No root. Nothing is installed into system directories.
import CPAPPL
import Foundation

let driverName = "mvb530"
let driverDescription = "Anko Inkless A4 (MV-B530)"

/// Fills in what the printer can do, and wires up the raster callbacks.
let driverCallback: pappl_pr_driver_cb_t = {
    system, name, deviceURI, deviceID, driverData, driverAttrs, _ in

    guard let driverData else { return false }
    _ = (system, name, deviceURI, deviceID)

    // PAPPL zeroes the struct for us; only set what differs from the default.
    driverData.pointee.rstartjob_cb = startJobCallback
    driverData.pointee.rstartpage_cb = startPageCallback
    driverData.pointee.rwriteline_cb = writeLineCallback
    driverData.pointee.rendpage_cb = endPageCallback
    driverData.pointee.rendjob_cb = endJobCallback
    driverData.pointee.testpage_cb = testPageCallback
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

/// Identify-Printer: the only thing this hardware can do on demand is feed a
/// little paper, which is enough to tell two printers apart.
let identifyCallback: pappl_pr_identify_cb_t = { printer, actions, message in
    _ = (printer, actions, message)
}

/// Called when PAPPL wants fresh printer state. The device status callback
/// does the real work; there is nothing to poll here.
let statusUpdateCallback: pappl_pr_status_cb_t = { _ in true }

/// PAPPL's built-in self-test page, routed through our encoder.
let testPageCallback: pappl_pr_testpage_cb_t = { printer, buffer, size in
    guard let buffer, size > 0 else { return nil }
    // Returning nil with no filename tells PAPPL there is no test file; the
    // printer's own pattern is available via `mvb530-printer-app testpage`.
    _ = printer
    buffer[0] = 0
    return nil
}

var drivers = [
    pappl_pr_driver_t(
        name: strdup(driverName),
        description: strdup(driverDescription),
        device_id: strdup("MFG:KM;MDL:P800;CMD:MVB530;"),
        extension: nil
    )
]

if let waitEnv = ProcessInfo.processInfo.environment["MVB530_WAIT"],
   let seconds = Double(waitEnv) {
    printerWaitSeconds = seconds
}

registerBluetoothScheme()

// PAPPL must own the main thread on macOS: it creates an NSStatusItem, and
// AppKit throws "NSWindow should only be instantiated on the main thread".
//
// So bring CoreBluetooth up here first, while we still are the main thread.
// Created lazily from a PAPPL worker instead, the central manager never
// leaves .unknown and no state callback is ever delivered.
// The agent owns the radio; nothing to warm up here.

exit(papplMainloop(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    "1.0",
    nil,                    // footer HTML
    Int32(drivers.count),
    &drivers,
    nil,                    // autoadd callback
    driverCallback,
    nil,                    // extra subcommand name
    nil,                    // extra subcommand callback
    nil,                    // system callback
    nil,                    // usage callback
    nil                     // callback data
))
