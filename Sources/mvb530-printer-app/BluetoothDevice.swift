/// A PAPPL device scheme backed directly by CoreBluetooth.
///
/// The radio lives in this process. That is only possible because the central
/// manager is created **on the main queue after PAPPL has started**: PAPPL
/// brings up an NSApplication, whose run loop services the main queue, and a
/// CBCentralManager created before that (or on a worker thread) never leaves
/// `.unknown` and delivers no state callback.
import CPAPPL
import CPAPPLSupport
import Foundation
import MVBTransport
import os

/// Logs to the unified log and to stderr, which the LaunchAgent captures:
///
///     log stream --predicate 'subsystem == "org.hmvs.mvb530"' --info
let deviceLogger = Logger(subsystem: "org.hmvs.mvb530", category: "device")

func deviceLog(_ message: String) {
    deviceLogger.info("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("mvb530: \(message)\n".utf8))
}

/// How long to wait for a sleeping printer before giving up on a job.
var printerWaitSeconds: TimeInterval = 180

/// Bluetooth name to pin, or nil for the first supported printer found.
var pinnedPrinterName: String?

// MARK: - Transport

/// The transport, created on the main queue once PAPPL is running.
private let transportLock = NSLock()
private var transportStorage: Printer?

/// Scanning is not re-entrant: Printer.scan stops and restarts the central
/// manager's scan, so two concurrent callers interleave and both see nothing.
private let scanLock = NSLock()

func scanForPrinters(duration: TimeInterval) -> [DiscoveredPrinter] {
    guard let transport = transport() else { return [] }
    scanLock.lock()
    defer { scanLock.unlock() }
    return transport.scan(duration: duration)
}

/// Bring CoreBluetooth up. Must be called on the main queue, after
/// papplMainloop has started, or the manager never initialises.
func startTransport() {
    transportLock.lock()
    defer { transportLock.unlock() }
    guard transportStorage == nil else { return }
    transportStorage = Printer()
    deviceLog("CoreBluetooth starting")

    // Establish presence before anyone asks. Without this the cache answers
    // "offline" until something triggers a refresh, which is a lie whenever
    // the printer is switched on and waiting.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
        presence.refreshNow()
    }
}

private func transport() -> Printer? {
    transportLock.lock()
    defer { transportLock.unlock() }
    return transportStorage
}

// MARK: - Presence cache

/// Whether the printer was in range when last checked, and when that was.
///
/// Status has to be answered without blocking: PAPPL asks for it while
/// rendering the web interface, and a scan takes seconds. Blocking there
/// truncates the HTTP response and leaves the page half-drawn.
private final class Presence {
    private let lock = NSLock()
    private var inRange = false
    private var checkedAt = Date.distantPast
    private var refreshing = false

    /// Seconds before a cached answer is considered stale. Long enough that
    /// the radio is not scanning constantly, short enough that switching the
    /// printer on is reflected without printing something first.
    private let staleAfter: TimeInterval = 45

    /// The cached answer, kicking off a background refresh when stale.
    func current() -> Bool {
        lock.lock()
        let value = inRange
        let stale = Date().timeIntervalSince(checkedAt) > staleAfter
        let busy = refreshing
        if stale && !busy { refreshing = true }
        lock.unlock()

        if stale && !busy {
            DispatchQueue.global(qos: .utility).async { self.refresh() }
        }
        return value
    }

    /// Record what a job just observed - far cheaper than a scan, and more
    /// authoritative, since the job actually talked to the printer.
    func record(inRange found: Bool) {
        lock.lock()
        inRange = found
        checkedAt = Date()
        lock.unlock()
    }

    /// Scan now and update the cache. Safe to call from any thread.
    func refreshNow() {
        lock.lock()
        if refreshing { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        refresh()
    }

    private func refresh() {
        // Match the duration the device listing uses: a shorter scan can miss
        // a peripheral that advertises slowly.
        let devices = scanForPrinters(duration: 6)
        let found = devices.contains { device in
            pinnedPrinterName == nil || device.name == pinnedPrinterName
        }
        lock.lock()
        inRange = found
        checkedAt = Date()
        refreshing = false
        lock.unlock()
        deviceLog("presence: \(found ? "in range" : "not in range")"
                  + " (scan saw \(devices.count): "
                  + devices.map(\.name).joined(separator: ", ")
                  + "; pinned=\(pinnedPrinterName ?? "none"))")
    }
}

private let presence = Presence()

/// Printer-level status callback. PAPPL calls this to refresh state, so this
/// is what makes the queue show as offline when the printer is switched off.
let statusUpdateCallback: pappl_pr_status_cb_t = { printer in
    describePrinter(printer)
    let offline = PAPPL_PREASON_OFFLINE.rawValue
    if presence.current() {
        papplPrinterSetReasons(printer, PAPPL_PREASON_NONE.rawValue, offline)
    } else {
        papplPrinterSetReasons(printer, offline, PAPPL_PREASON_NONE.rawValue)
    }
    return true
}

// MARK: - Device scheme

/// Buffers one job, then prints it when the device is closed.
///
/// The protocol could be streamed row by row, but a page is only ~90 KB and
/// buffering keeps the radio link open for the shortest possible time.
final class DeviceBuffer {
    var bytes = [UInt8]()
    var printerName: String?

    init(printerName: String?) {
        self.printerName = printerName
    }
}

private func bufferOf(_ device: OpaquePointer?) -> DeviceBuffer? {
    guard let raw = papplDeviceGetData(device) else { return nil }
    return Unmanaged<DeviceBuffer>.fromOpaque(raw).takeUnretainedValue()
}

private let listCallback: pappl_devlist_cb_t = { callback, data, _, _ in
    for found in scanForPrinters(duration: 6) {
        let uri = "bluetooth://\(found.name)/"
        let id = "MFG:KM;MDL:P800;CMD:MVB530;SN:\(found.name);"
        let stop = uri.withCString { uriPtr in
            found.name.withCString { namePtr in
                id.withCString { idPtr in
                    callback?(uriPtr, idPtr, namePtr, data) ?? false
                }
            }
        }
        // A true return from the callback means "stop listing".
        if stop { return true }
    }
    return false
}

private let openCallback: pappl_devopen_cb_t = { device, deviceURI, _ in
    // bluetooth://NAME/ pins one printer; bluetooth:// takes the first found.
    var wanted = pinnedPrinterName
    if let deviceURI {
        let host = String(cString: deviceURI)
            .replacingOccurrences(of: "bluetooth://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !host.isEmpty { wanted = host }
    }

    let buffer = DeviceBuffer(printerName: wanted)
    papplDeviceSetData(device, Unmanaged.passRetained(buffer).toOpaque())
    return true
}

private let writeCallback: pappl_devwrite_cb_t = { device, bytes, count in
    // papplDeviceWrite flushes its internal buffer before a large write, and
    // that flush can be zero bytes. Treating it as an error fails the job.
    if count == 0 { return 0 }
    guard let buffer = bufferOf(device), let bytes else {
        deviceLog("write rejected: no device buffer")
        return -1
    }
    let raw = bytes.assumingMemoryBound(to: UInt8.self)
    buffer.bytes.append(contentsOf: UnsafeBufferPointer(start: raw, count: count))
    return ssize_t(count)
}

private let readCallback: pappl_devread_cb_t = { _, _, _ in
    // The printer sends nothing we act on.
    0
}

private let closeCallback: pappl_devclose_cb_t = { device in
    guard let raw = papplDeviceGetData(device) else { return }
    let buffer = Unmanaged<DeviceBuffer>.fromOpaque(raw).takeRetainedValue()
    papplDeviceSetData(device, nil)

    guard !buffer.bytes.isEmpty else { return }
    guard let transport = transport() else {
        deviceLog("CoreBluetooth is not up yet")
        mvb_device_error(device, "Bluetooth is not ready")
        return
    }

    do {
        try transport.send(buffer.bytes, to: buffer.printerName,
                           waitFor: printerWaitSeconds) { line in
            deviceLog(line)
        }
        presence.record(inRange: true)
    } catch let error as PrinterError {
        if case .notFound = error { presence.record(inRange: false) }
        deviceLog("print failed: \(error)")
        mvb_device_error(device, "\(error)")
    } catch {
        deviceLog("print failed: \(error)")
        mvb_device_error(device, "\(error)")
    }
}

private let statusCallback: pappl_devstatus_cb_t = { _ in
    // Cached, so this never blocks the web interface or a status query.
    presence.current() ? PAPPL_PREASON_NONE.rawValue
                       : PAPPL_PREASON_OFFLINE.rawValue
}

private let idCallback: pappl_devid_cb_t = { device, buffer, size in
    guard let buffer, size > 0 else { return nil }
    "MFG:KM;MDL:P800;CMD:MVB530;".withCString { _ = strlcpy(buffer, $0, size) }
    return buffer
}

func registerBluetoothScheme() {
    papplDeviceAddScheme("bluetooth", PAPPL_DEVTYPE_CUSTOM_LOCAL.rawValue,
                         listCallback, openCallback, closeCallback,
                         readCallback, writeCallback, statusCallback,
                         idCallback)
}
