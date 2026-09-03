/// First-run setup for the .app: the printer, then the CUPS queue.
///
/// The Makefile used to do this with two commands after starting the service.
/// A double-clicked bundle has no such step, and it cannot shell out to its
/// own subcommands either: papplMainloop replaces argv with a plain "server"
/// invocation whenever argv[0] sits inside a .app, so `add` would start a
/// second server instead. The printer itself is created by PAPPL's own
/// first-run auto-add, so what is left here is the CUPS queue.
import CPAPPL
import Foundation

/// The PAPPL printer's name, and so its resource path, /ipp/print/anko.
let printerName = "anko"

/// The CUPS queue name users see in the print dialog.
let queueName = "Anko_Inkless_A4"

/// The device URI a queue must have to reach this service.
private func deviceURI(port: Int) -> String {
    "ipp://localhost:\(port)/ipp/print/\(printerName)"
}

/// Creates the CUPS queue, or repoints an existing one after a port change.
///
/// -m everywhere makes CUPS build the queue from the IPP attributes the
/// service advertises, so no PPD is authored or installed.
private func createQueue(port: Int) {
    let wanted = deviceURI(port: port)

    if run("/usr/bin/lpstat", ["-p", queueName]) == 0 {
        // The port can be changed by editing the config file, and a queue
        // left pointing at the old one fails every job with no explanation.
        if let current = capture("/usr/bin/lpstat", ["-v", queueName]),
           !current.contains(wanted) {
            _ = run("/usr/sbin/lpadmin", ["-p", queueName, "-v", wanted])
            deviceLog("queue \(queueName) repointed at \(wanted)")
        }
        return
    }

    let status = run("/usr/sbin/lpadmin", [
        "-p", queueName, "-E", "-m", "everywhere",
        "-v", wanted,
        "-o", "printer-is-shared=false",
        // Without this a job that outlives the printer's patience disables
        // the queue instead of retrying it.
        "-o", "printer-error-policy=retry-job",
    ])
    if status == 0 {
        deviceLog("first run: created the queue \(queueName)")
        _ = run("/usr/bin/lpoptions", ["-d", queueName])
    } else {
        deviceLog("first run: lpadmin failed (\(status)); add the printer by hand")
    }
}

/// Runs a command and returns its standard output, or nil if it failed.
private func capture(_ path: String, _ arguments: [String]) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return task.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
}

private func run(_ path: String, _ arguments: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    } catch {
        deviceLog("first run: could not run \(path): \(error.localizedDescription)")
        return -1
    }
}

/// Brings a freshly installed .app to the same state `make install` left:
/// a printer on the IPP service, and a CUPS queue pointing at it.
func performFirstRunSetup(port: Int) {
    createQueue(port: port)
}

/// Starts a fresh copy of the app after this one has exited.
///
/// Changing which addresses are bound needs a restart, and a LaunchAgent used
/// to provide one. A login item is only started at login, so the app arranges
/// its own return. It waits for the port to be released first: PAPPL takes a
/// moment to shut down, and a second instance that finds the port still held
/// exits without a word.
func relaunchBundle(port: Int) {
    let bundle = Bundle.main.bundlePath
    guard bundle.hasSuffix(".app") else { return }

    let script = """
        for _ in $(seq 1 30); do
          /usr/sbin/lsof -nP -iTCP:\(port) -sTCP:LISTEN >/dev/null 2>&1 || break
          sleep 1
        done
        /usr/bin/open -a "\(bundle)"
        """
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", script]
    try? task.run()
}
