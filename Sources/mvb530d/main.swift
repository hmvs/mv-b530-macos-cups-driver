/// mvb530d - the print agent for MV-B530 class thermal printers.
///
/// Exists because a CUPS backend cannot use Bluetooth: cupsd runs backends as
/// the _lp user, a context that can hold no TCC grant and can show no
/// permission prompt. This runs in the user's login session instead, and the
/// backend hands jobs to it over the loopback interface.
///
/// The binary carries its own Info.plist in a __TEXT,__info_plist section, so
/// it declares NSBluetoothAlwaysUsageDescription without being an .app bundle.
import Foundation
import MVBProtocol

// MARK: - Configuration

struct Configuration {
    var port: UInt16 = 9101
    var printerName: String?
    /// How long to wait for a sleeping printer to appear before telling the
    /// backend to have CUPS retry.
    var waitSeconds: TimeInterval = 180
    var verbose = false
}

func parseArguments() -> Configuration {
    var config = Configuration()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()

    while let argument = iterator.next() {
        switch argument {
        case "--port":
            if let value = iterator.next(), let port = UInt16(value) {
                config.port = port
            }
        case "--printer":
            config.printerName = iterator.next()
        case "--wait":
            if let value = iterator.next(), let seconds = Double(value) {
                config.waitSeconds = seconds
            }
        case "--verbose":
            config.verbose = true
        case "--help", "-h":
            print("""
                usage: mvb530d [--port N] [--printer NAME] [--wait S] [--verbose]

                  --port N        loopback port to listen on (default 9101)
                  --printer NAME  exact Bluetooth name; default is the first
                                  supported printer found
                  --wait S        how long to wait for a sleeping printer to
                                  appear before asking CUPS to retry (180)
                  --verbose       log every request
                """)
            exit(0)
        default:
            break
        }
    }
    return config
}

let config = parseArguments()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

// MARK: - HTTP

struct Request {
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var body = [UInt8]()
}

func readRequest(_ client: Int32) -> Request? {
    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)

    var headerEnd: Int?
    while headerEnd == nil {
        let n = read(client, &chunk, chunk.count)
        if n <= 0 { return nil }
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.count > 64 * 1024 { return nil }

        if buffer.count >= 4 {
            for i in 3..<buffer.count where
                buffer[i - 3] == 13 && buffer[i - 2] == 10 &&
                buffer[i - 1] == 13 && buffer[i] == 10 {
                headerEnd = i + 1
                break
            }
        }
    }
    guard let bodyStart = headerEnd else { return nil }

    let headerText = String(decoding: buffer[0..<bodyStart], as: UTF8.self)
    var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: true)
    guard !lines.isEmpty else { return nil }

    var request = Request()
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    request.method = String(requestLine[0])
    request.path = String(requestLine[1])

    for line in lines {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { continue }
        request.headers[parts[0].lowercased()] =
            parts[1].trimmingCharacters(in: .whitespaces)
    }

    let expected = Int(request.headers["content-length"] ?? "0") ?? 0
    request.body = Array(buffer[bodyStart...])
    while request.body.count < expected {
        let n = read(client, &chunk, chunk.count)
        if n <= 0 { break }
        request.body.append(contentsOf: chunk[0..<n])
    }
    if request.body.count > expected {
        request.body = Array(request.body[0..<expected])
    }
    return request
}

func respond(_ client: Int32, status: Int, reason: String, body: String) {
    let payload = Array(body.utf8)
    let head = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
    var out = Array(head.utf8)
    out.append(contentsOf: payload)
    out.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var sent = 0
        while sent < buffer.count {
            let n = write(client, base + sent, buffer.count - sent)
            if n <= 0 { break }
            sent += n
        }
    }
}

// MARK: - Test page

/// A small self-contained pattern, so the hardware can be checked without
/// involving CUPS at all.
func testPageStream() -> [UInt8] {
    let width = 1600
    let height = 240
    var pixels = [UInt8](repeating: 0, count: width * height)

    for y in 0..<height {
        for x in 0..<width {
            let border = x < 4 || x >= width - 4 || y < 4 || y >= height - 4
            let ticks = (y > 20 && y < 60) && (x % 100 < 3)
            let bars = (y > 100 && y < 180) && ((x / 40) % 2 == 0)
            pixels[y * width + x] = (border || ticks || bars) ? 1 : 0
        }
    }

    var options = JobOptions()
    options.paperMode = .a4Sheet
    options.a4SheetMaxHeight = 2460
    return Wire.buildJob(pixels: pixels, width: width, height: height,
                         options: options) ?? []
}

// MARK: - Server

let printer = Printer()
let printLock = NSLock()

func handle(_ request: Request, client: Int32) {
    switch (request.method, request.path) {
    case ("GET", "/health"):
        respond(client, status: 200, reason: "OK",
                body: "ok\nbluetooth: \(printer.bluetoothState)\n")

    case ("GET", "/scan"):
        let devices = printer.scan()
        if devices.isEmpty {
            respond(client, status: 200, reason: "OK",
                    body: "no supported printers found\n")
        } else {
            let listing = devices
                .map { "\($0.name)  \($0.identifier)" }
                .joined(separator: "\n")
            respond(client, status: 200, reason: "OK", body: listing + "\n")
        }

    case ("POST", "/print"), ("POST", "/testpage"):
        let payload = request.path == "/testpage"
            ? testPageStream()
            : request.body
        guard !payload.isEmpty else {
            respond(client, status: 400, reason: "Bad Request",
                    body: "empty job\n")
            return
        }

        printLock.lock()
        defer { printLock.unlock() }

        var transcript = [String]()
        do {
            // /testpage is an interactive diagnostic, so it should answer
            // quickly rather than sit waiting for a printer to wake up.
            let wait = request.path == "/testpage" ? 20 : config.waitSeconds
            try printer.send(payload, to: config.printerName, waitFor: wait) { line in
                transcript.append(line)
                if config.verbose { log(line) }
            }
            respond(client, status: 200, reason: "OK",
                    body: transcript.joined(separator: "\n") + "\nprinted\n")
        } catch let error as PrinterError {
            log("job failed: \(error)")
            // 503 tells the backend this is worth retrying; 500 does not.
            respond(client, status: error.isTransient ? 503 : 500,
                    reason: error.isTransient ? "Service Unavailable"
                                              : "Internal Server Error",
                    body: "\(error)\n")
        } catch {
            log("job failed: \(error)")
            respond(client, status: 500, reason: "Internal Server Error",
                    body: "\(error)\n")
        }

    default:
        respond(client, status: 404, reason: "Not Found", body: "not found\n")
    }
}

func serve(port: UInt16) -> Never {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else {
        log("cannot create socket")
        exit(1)
    }

    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes,
               socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    // Loopback only: this speaks for the logged-in user's printer and has no
    // business being reachable from the network.
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else {
        log("cannot bind 127.0.0.1:\(port) - is another agent running?")
        exit(1)
    }
    guard listen(listener, 8) == 0 else {
        log("cannot listen on 127.0.0.1:\(port)")
        exit(1)
    }

    log("mvb530d listening on http://127.0.0.1:\(port)")

    while true {
        let client = accept(listener, nil, nil)
        if client < 0 { continue }
        if let request = readRequest(client) {
            handle(request, client: client)
        }
        close(client)
    }
}

// CoreBluetooth needs a live run loop, so the socket server runs beside it.
Thread.detachNewThread {
    serve(port: config.port)
}
RunLoop.main.run()
