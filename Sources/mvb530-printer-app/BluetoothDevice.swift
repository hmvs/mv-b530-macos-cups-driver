/// A PAPPL device scheme that forwards jobs to the mvb530d transport agent.
///
/// The radio work cannot happen in this process. PAPPL must own the main
/// thread on macOS - it creates an NSStatusItem, and AppKit throws
/// "NSWindow should only be instantiated on the main thread" otherwise - and
/// it never pumps a CFRunLoop there. A CBCentralManager created in this
/// process stays in .unknown for ever and delivers no state callback, with or
/// without an explicit dispatch queue, on the main thread or a worker, and
/// regardless of which code-signing identity is used.
///
/// So the BLE link lives in mvb530d, whose main thread does run a run loop,
/// and this scheme hands each job to it over the loopback interface. That is
/// one extra small user-session process, against a CUPS filter and backend
/// installed as root in the previous design.
import CPAPPL
import CPAPPLSupport
import Foundation

func deviceLog(_ message: String) {
    // papplLog needs a system pointer we do not have in device callbacks, so
    // go straight to stderr - launchd and the shell both capture it.
    FileHandle.standardError.write(Data("mvb530: \(message)\n".utf8))
}

/// Where mvb530d listens.
let agentURL = ProcessInfo.processInfo.environment["MVB530_AGENT_URL"]
    ?? "http://127.0.0.1:9101"

/// How long to wait for a sleeping printer before giving up on a job.
var printerWaitSeconds: TimeInterval = 180

/// Ask the agent a question. Returns (status, body), or nil if unreachable.
func agentRequest(_ path: String, method: String = "GET",
                  body: Data? = nil, timeout: TimeInterval = 30)
    -> (status: Int, body: String)? {
    guard let url = URL(string: agentURL + path) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = timeout

    let semaphore = DispatchSemaphore(value: 0)
    var result: (Int, String)?
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let http = response as? HTTPURLResponse {
            result = (http.statusCode,
                      data.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 5)
    return result
}

/// Buffers one job, then hands it to the transport on close.
///
/// The protocol could be streamed row by row, but a page is only ~90 KB and
/// buffering keeps the radio link open for the shortest possible time — and
/// it reuses the send path that is already tested.
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

/// Report supported printers so `--device` listing and the web UI work.
private let listCallback: pappl_devlist_cb_t = { callback, data, errorCallback, errorData in
    // The agent owns the radio, so discovery goes through it too.
    guard let reply = agentRequest("/scan", timeout: 40), reply.status == 200
    else { return false }

    for line in reply.body.split(separator: "\n") {
        let name = String(line.split(separator: " ").first ?? "")
        guard !name.isEmpty, name != "no" else { continue }
        let uri = "bluetooth://\(name)/"
        let id = "MFG:KM;MDL:P800;CMD:MVB530;SN:\(name);"
        if uri.withCString({ uriPtr in
            name.withCString { namePtr in
                id.withCString { idPtr in
                    callback?(uriPtr, idPtr, namePtr, data) ?? false
                }
            }
        }) {
            // A true return from the callback means "stop listing".
            return true
        }
    }
    return false
}

private let openCallback: pappl_devopen_cb_t = { device, deviceURI, _ in
    // bluetooth://NAME/ pins one printer; bluetooth:// takes the first found.
    var wanted: String?
    if let deviceURI {
        let uri = String(cString: deviceURI)
        let host = uri
            .replacingOccurrences(of: "bluetooth://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !host.isEmpty { wanted = host }
    }

    let buffer = DeviceBuffer(printerName: wanted)
    papplDeviceSetData(device, Unmanaged.passRetained(buffer).toOpaque())
    deviceLog("device open: printer=\(wanted ?? "<first found>")")
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
    // The printer sends nothing we act on, and PAPPL tolerates a device that
    // cannot be read.
    0
}

private let closeCallback: pappl_devclose_cb_t = { device in
    guard let raw = papplDeviceGetData(device) else { return }
    let buffer = Unmanaged<DeviceBuffer>.fromOpaque(raw).takeRetainedValue()
    papplDeviceSetData(device, nil)

    guard !buffer.bytes.isEmpty else { return }

    deviceLog("handing \(buffer.bytes.count) bytes to the agent")
    guard let reply = agentRequest("/print", method: "POST",
                                   body: Data(buffer.bytes),
                                   timeout: printerWaitSeconds + 60) else {
        deviceLog("agent unreachable at \(agentURL)")
        mvb_device_error(device, "print agent is not running")
        return
    }

    switch reply.status {
    case 200:
        deviceLog("printed")
    case 503:
        deviceLog("printer offline: \(reply.body)")
        mvb_device_error(device, "printer is offline")
    default:
        deviceLog("agent error \(reply.status): \(reply.body)")
        mvb_device_error(device, "print failed: \(reply.body)")
    }
}

private let statusCallback: pappl_devstatus_cb_t = { device in
    guard let buffer = bufferOf(device) else { return pappl_preason_t(0) }
    // Report the printer as offline when it is not in range, which is what
    // macOS surfaces as "Printer is offline".
    guard let reply = agentRequest("/health", timeout: 5),
          reply.status == 200 else {
        return PAPPL_PREASON_OFFLINE.rawValue
    }
    _ = buffer
    return pappl_preason_t(0)
}

private let idCallback: pappl_devid_cb_t = { device, buffer, size in
    guard let buffer, size > 0 else { return nil }
    let id = "MFG:KM;MDL:P800;CMD:MVB530;"
    id.withCString { _ = strlcpy(buffer, $0, size) }
    return buffer
}

func registerBluetoothScheme() {
    papplDeviceAddScheme("bluetooth", PAPPL_DEVTYPE_CUSTOM_LOCAL.rawValue,
                         listCallback, openCallback, closeCallback,
                         readCallback, writeCallback, statusCallback,
                         idCallback)
}
