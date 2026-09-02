/// Bluetooth Low Energy transport for MV-B530 class printers.
///
/// The printer advertises the ISSC transparent UART service and takes the
/// command stream as a series of write-without-response chunks. Classic
/// RFCOMM is advertised by the device but does not accept a connection, so
/// BLE is the only route that works.
import CoreBluetooth
import Foundation

/// Bluetooth names of MV-B530 and its documented clones.
public let supportedNamePrefixes = ["MV-B530", "GL-VS9", "QDID", "X9"]

let uartService = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
let uartWriteCharacteristic = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")

public enum PrinterError: Error, CustomStringConvertible {
    case bluetoothUnavailable(String)
    case notFound
    case connectFailed(String)
    case noWriteCharacteristic
    case timedOut(String)

    public var description: String {
        switch self {
        case let .bluetoothUnavailable(state):
            return "Bluetooth is not available (\(state))"
        case .notFound:
            return "no supported printer found - is it powered on?"
        case let .connectFailed(reason):
            return "could not connect: \(reason)"
        case .noWriteCharacteristic:
            return "printer does not expose the expected write characteristic"
        case let .timedOut(stage):
            return "timed out while \(stage)"
        }
    }

    /// Whether the caller should ask CUPS to retry rather than fail the job.
    public var isTransient: Bool {
        switch self {
        case .notFound, .connectFailed, .timedOut:
            return true
        case .bluetoothUnavailable, .noWriteCharacteristic:
            return false
        }
    }
}

public struct DiscoveredPrinter {
    public let name: String
    public let identifier: UUID
}

/// Serialises all CoreBluetooth work onto one queue and exposes blocking
/// calls, which suits a print spooler: one job at a time, in order.
public final class Printer: NSObject {
    private let queue = DispatchQueue(label: "org.hmvs.mvb530d.ble")
    private var central: CBCentralManager!

    private var poweredOn = false
    private var powerWaiters: [(Bool) -> Void] = []

    private var found: [UUID: (peripheral: CBPeripheral, name: String)] = [:]
    private var scanDeadline: Date?

    private var target: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    private var connectContinuation: ((Result<Void, PrinterError>) -> Void)?
    private var readyContinuation: (() -> Void)?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Bring CoreBluetooth up and wait for it to report a state.
    ///
    /// Call this from the main thread during start-up. A central manager
    /// first touched from a worker thread never leaves `.unknown`, so the
    /// first print would otherwise fail with "Bluetooth is not available".
    @discardableResult
    public func prewarm(timeout: TimeInterval = 15) -> Bool {
        let ready = waitForPower(timeout: timeout)
        let note = "mvb530: bluetooth "
            + (ready ? "ready" : "not ready")
            + " (\(bluetoothState))\n"
        FileHandle.standardError.write(Data(note.utf8))
        return ready
    }

    // MARK: - Power

    private func waitForPower(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        queue.async {
            if self.poweredOn {
                result = true
                semaphore.signal()
                return
            }
            self.powerWaiters.append { ok in
                result = ok
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    // MARK: - Discovery

    /// Scan for supported printers. Always runs the full duration so the
    /// caller sees every device in range, not just the first.
    public func scan(duration: TimeInterval = 6.0) -> [DiscoveredPrinter] {
        guard waitForPower(timeout: 15) else { return [] }

        queue.sync {
            found.removeAll()
            central.scanForPeripherals(withServices: nil, options: nil)
        }
        Thread.sleep(forTimeInterval: duration)
        return queue.sync {
            central.stopScan()
            return found.map { DiscoveredPrinter(name: $0.value.name,
                                                 identifier: $0.key) }
                .sorted { $0.name < $1.name }
        }
    }

    /// Look for the printer until `timeout` elapses.
    ///
    /// These printers sleep and auto-power-off, so a job is very often
    /// submitted while the printer is unreachable. Waiting here rather than
    /// failing at once means the user can hit print, then switch the printer
    /// on, and the page still comes out.
    private func findPeripheral(named wanted: String?,
                                timeout: TimeInterval,
                                log: ((String) -> Void)? = nil) -> CBPeripheral? {
        let deadline = Date().addingTimeInterval(timeout)
        var announced = false

        while true {
            // Restart the scan periodically: a long-running CoreBluetooth
            // scan can go quiet, and a fresh one also picks up devices that
            // have only just started advertising.
            queue.sync {
                found.removeAll()
                central.stopScan()
                central.scanForPeripherals(withServices: nil, options: nil)
            }

            let burstEnd = min(Date().addingTimeInterval(15), deadline)
            while Date() < burstEnd {
                let match: CBPeripheral? = queue.sync {
                    for (_, entry) in found {
                        if let wanted, entry.name != wanted { continue }
                        return entry.peripheral
                    }
                    return nil
                }
                if let match {
                    queue.sync { central.stopScan() }
                    return match
                }
                Thread.sleep(forTimeInterval: 0.25)
            }

            if Date() >= deadline { break }
            if !announced {
                announced = true
                log?("printer not in range yet, waiting up to \(Int(timeout))s")
            }
        }

        queue.sync { central.stopScan() }
        return nil
    }

    // MARK: - Printing

    /// Connect, write the whole stream, and disconnect. Blocks until done.
    public func send(_ payload: [UInt8], to wanted: String?,
              waitFor: TimeInterval = 180,
              log: @escaping (String) -> Void) throws {
        guard waitForPower(timeout: 15) else {
            throw PrinterError.bluetoothUnavailable(stateDescription())
        }

        guard let peripheral = findPeripheral(named: wanted, timeout: waitFor,
                                              log: log) else {
            throw PrinterError.notFound
        }
        log("found \(peripheral.name ?? "printer") (\(peripheral.identifier))")

        try connect(peripheral)
        defer {
            queue.sync {
                central.cancelPeripheralConnection(peripheral)
                target = nil
                writeCharacteristic = nil
            }
        }

        guard let characteristic = queue.sync(execute: { writeCharacteristic })
        else {
            throw PrinterError.noWriteCharacteristic
        }

        let chunkSize = min(512,
                            peripheral.maximumWriteValueLength(for: .withoutResponse))
        log("connected, writing \(payload.count) bytes in \(chunkSize)-byte chunks")

        var offset = 0
        var chunks = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let chunk = Data(payload[offset..<end])

            // Flow control: wait for the peripheral to drain rather than
            // guessing with a fixed delay, which either stalls or overruns.
            try waitUntilReady(peripheral, timeout: 10)
            queue.sync {
                peripheral.writeValue(chunk, for: characteristic,
                                      type: .withoutResponse)
            }
            offset = end
            chunks += 1
        }

        log("wrote \(payload.count) bytes in \(chunks) chunks")
        // Let the last chunks reach the printer before tearing the link down.
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func connect(_ peripheral: CBPeripheral) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Void, PrinterError> = .failure(.timedOut("connecting"))

        queue.sync {
            target = peripheral
            writeCharacteristic = nil
            peripheral.delegate = self
            connectContinuation = { result in
                outcome = result
                semaphore.signal()
            }
            central.connect(peripheral, options: nil)
        }

        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            queue.sync { connectContinuation = nil }
            throw PrinterError.timedOut("connecting")
        }
        try outcome.get()
    }

    private func waitUntilReady(_ peripheral: CBPeripheral,
                                timeout: TimeInterval) throws {
        let ready = queue.sync { peripheral.canSendWriteWithoutResponse }
        if ready { return }

        let semaphore = DispatchSemaphore(value: 0)
        queue.sync { readyContinuation = { semaphore.signal() } }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            queue.sync { readyContinuation = nil }
            // Not fatal on its own: some stacks never raise the callback, so
            // fall through and let the write itself surface any problem.
        }
    }

    private func stateDescription() -> String {
        switch central.state {
        case .poweredOff:   return "powered off"
        case .unauthorized: return "not authorised - grant Bluetooth access"
        case .unsupported:  return "unsupported"
        case .resetting:    return "resetting"
        case .unknown:      return "unknown"
        case .poweredOn:    return "powered on"
        @unknown default:   return "unknown"
        }
    }

    public var bluetoothState: String { queue.sync { stateDescription() } }
}

// MARK: - CBCentralManagerDelegate

extension Printer: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        poweredOn = manager.state == .poweredOn
        let waiters = powerWaiters
        powerWaiters.removeAll()
        for waiter in waiters { waiter(poweredOn) }
    }

    public func centralManager(_ manager: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = advertised ?? peripheral.name else { return }
        guard supportedNamePrefixes.contains(where: { name.hasPrefix($0) }) else {
            return
        }
        found[peripheral.identifier] = (peripheral, name)
    }

    public func centralManager(_ manager: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([uartService])
    }

    public func centralManager(_ manager: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let continuation = connectContinuation
        connectContinuation = nil
        continuation?(.failure(.connectFailed(
            error?.localizedDescription ?? "unknown reason")))
    }

    public func centralManager(_ manager: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation(.failure(.connectFailed(
                error?.localizedDescription ?? "disconnected during setup")))
        }
    }
}

// MARK: - CBPeripheralDelegate

extension Printer: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let error {
            let continuation = connectContinuation
            connectContinuation = nil
            continuation?(.failure(.connectFailed(error.localizedDescription)))
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == uartService
        }) else {
            let continuation = connectContinuation
            connectContinuation = nil
            continuation?(.failure(.noWriteCharacteristic))
            return
        }
        peripheral.discoverCharacteristics([uartWriteCharacteristic], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let continuation = connectContinuation
        connectContinuation = nil

        if let error {
            continuation?(.failure(.connectFailed(error.localizedDescription)))
            return
        }
        guard let characteristic = service.characteristics?.first(where: {
            $0.uuid == uartWriteCharacteristic
        }) else {
            continuation?(.failure(.noWriteCharacteristic))
            return
        }
        writeCharacteristic = characteristic
        continuation?(.success(()))
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?()
    }
}
