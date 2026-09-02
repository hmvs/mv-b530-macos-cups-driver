/// CUPS backend for MV-B530 class thermal printers.
///
/// Runs as _lp under cupsd, which can hold no Bluetooth grant, so it only
/// forwards the job to mvb530d in the user session over the loopback
/// interface. Backends are allowed to do networking - the stock ipp, socket
/// and lpd backends all depend on it - whereas macOS sandboxes them away from
/// arbitrary filesystem paths, which rules out a shared spool directory.
import Foundation

// CUPS backend exit codes.
let backendOK: Int32 = 0
let backendFailed: Int32 = 1
let backendRetry: Int32 = 6

/// cupsd reads STATE:, INFO: and ERROR: lines from a backend's stderr.
/// STATE: +offline-report is what surfaces as "Printer is offline" in the UI.
func report(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}

func fail(_ message: String, code: Int32) -> Never {
    report(message)
    exit(code)
}

let arguments = CommandLine.arguments

// No arguments: device discovery.
if arguments.count == 1 {
    print("""
        direct mvb530:/ "Anko Inkless A4" "Anko Inkless A4 Printer (MV-B530)" \
        "MFG:KM;MDL:P800;CMD:MVB530;"
        """)
    exit(backendOK)
}

guard arguments.count == 6 || arguments.count == 7 else {
    fail("Usage: mvb530 job-id user title copies options [file]", code: backendFailed)
}

let agentURL = ProcessInfo.processInfo.environment["MVB530_AGENT_URL"]
    ?? "http://127.0.0.1:9101/print"

let payload: Data
if arguments.count == 7 {
    guard let data = FileManager.default.contents(atPath: arguments[6]) else {
        fail("ERROR: cannot read \(arguments[6])", code: backendFailed)
    }
    payload = data
} else {
    payload = FileHandle.standardInput.readDataToEndOfFile()
}

guard !payload.isEmpty else {
    fail("ERROR: empty print job", code: backendFailed)
}

guard let url = URL(string: agentURL) else {
    fail("ERROR: invalid agent URL \(agentURL)", code: backendFailed)
}

FileHandle.standardError.write(
    Data("INFO: sending \(payload.count) bytes to the print agent\n".utf8))

var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
request.httpBody = payload
// Generous: the agent waits for the printer to wake and a page takes seconds
// to stream over BLE.
request.timeoutInterval = 300

let semaphore = DispatchSemaphore(value: 0)
var status = -1
var body = ""
var transportError: Error?

URLSession.shared.dataTask(with: request) { data, response, error in
    transportError = error
    if let http = response as? HTTPURLResponse { status = http.statusCode }
    if let data { body = String(decoding: data, as: UTF8.self) }
    semaphore.signal()
}.resume()

if semaphore.wait(timeout: .now() + 310) == .timedOut {
    fail("ERROR: the print agent did not respond in time", code: backendRetry)
}

if let transportError {
    // Agent not running is worth retrying: the queue should stay enabled so
    // the job goes through once the user starts it.
    // The agent being down is not the printer being offline, so report it as
    // its own condition rather than blaming the hardware.
    report("STATE: +connecting-to-device")
    FileHandle.standardError.write(Data("""
        ERROR: cannot reach the print agent at \(agentURL)
        ERROR: \(transportError.localizedDescription)
        ERROR: start it with 'make agent-start', then the job will retry

        """.utf8))
    exit(backendRetry)
}

switch status {
case 200:
    report("STATE: -offline-report,connecting-to-device")
    report("INFO: printed")
    exit(backendOK)
case 503:
    // Printer asleep or out of range. offline-report is what macOS turns into
    // "Printer is offline" in Printers & Scanners and the print dialog; the
    // queue stays enabled and CUPS comes back to the job.
    report("STATE: +offline-report")
    report("INFO: printer is offline - the job will print when it is switched on")
    exit(backendRetry)
default:
    report("STATE: -offline-report")
    fail("ERROR: print failed (HTTP \(status)): \(body)", code: backendFailed)
}
