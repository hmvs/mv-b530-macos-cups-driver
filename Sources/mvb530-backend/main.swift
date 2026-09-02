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

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
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
    FileHandle.standardError.write(Data("""
        ERROR: cannot reach the print agent at \(agentURL)
        ERROR: \(transportError.localizedDescription)
        ERROR: start it with start-agent.sh, then the job will retry

        """.utf8))
    exit(backendRetry)
}

switch status {
case 200:
    FileHandle.standardError.write(Data("INFO: printed\n".utf8))
    exit(backendOK)
case 503:
    // Printer asleep or out of range: keep the queue enabled and come back.
    FileHandle.standardError.write(
        Data("INFO: printer unreachable, will retry - \(body)\n".utf8))
    exit(backendRetry)
default:
    fail("ERROR: print failed (HTTP \(status)): \(body)", code: backendFailed)
}
