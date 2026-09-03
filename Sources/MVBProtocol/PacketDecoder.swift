/// Decoder for packets coming *from* the printer.
///
/// The printer answers in the same framing it is sent:
///
///     51 78 | opcode flags len_lo len_hi | payload | crc8(payload) ff
///
/// with flags set to 1 on the way back. BLE notifications arrive fragmented
/// and coalesced, so bytes are buffered until whole packets can be lifted out.
public struct DecodedPacket: Equatable {
    public let opcode: UInt8
    public let flags: UInt8
    public let payload: [UInt8]

    public init(opcode: UInt8, flags: UInt8, payload: [UInt8]) {
        self.opcode = opcode
        self.flags = flags
        self.payload = payload
    }
}

public struct PacketDecoder {
    /// 51 78, opcode, flags, and two length bytes.
    private static let headerLength = 6
    private static let prefix: [UInt8] = [0x51, 0x78]

    private var buffer = [UInt8]()

    public init() {}

    /// Adds bytes and returns whatever complete packets they finished.
    public mutating func feed<C: Collection>(_ bytes: C) -> [DecodedPacket]
    where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)

        var packets = [DecodedPacket]()
        while !buffer.isEmpty {
            guard let start = indexOfPrefix() else {
                // Keep a trailing byte that could be the start of the prefix.
                buffer = buffer.last == Self.prefix[0] ? [Self.prefix[0]] : []
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= Self.headerLength else { break }

            let payloadLength = Int(buffer[4]) | (Int(buffer[5]) << 8)
            let total = Self.headerLength + payloadLength + 2
            guard buffer.count >= total else { break }

            let payload = Array(buffer[Self.headerLength..<(Self.headerLength + payloadLength)])
            if buffer[total - 1] == 0xFF, buffer[total - 2] == Wire.crc8(payload) {
                packets.append(DecodedPacket(opcode: buffer[2], flags: buffer[3],
                                             payload: payload))
                buffer.removeFirst(total)
            } else {
                // Not a packet after all: step over this prefix and resync.
                buffer.removeFirst(1)
            }
        }
        return packets
    }

    private func indexOfPrefix() -> Int? {
        guard buffer.count >= 2 else {
            return buffer.first == Self.prefix[0] ? nil : 0
        }
        for index in 0...(buffer.count - 2)
        where buffer[index] == Self.prefix[0] && buffer[index + 1] == Self.prefix[1] {
            return index
        }
        return nil
    }
}

/// What the printer is telling us about its buffer.
///
/// It sends these unprompted while a job is streaming: 0x10 when the buffer is
/// full and the host must stop, 0x00 when there is room again. Ignoring them
/// overruns the printer, which silently drops the lines it could not hold.
public enum FlowControl {
    static let opcode: UInt8 = 0xAE
    static let fromPrinter: UInt8 = 1

    public static func state(of packet: DecodedPacket) -> Bool? {
        guard packet.opcode == opcode, packet.flags == fromPrinter,
              packet.payload.count == 1 else { return nil }
        switch packet.payload[0] {
        case 0x10: return true      // pause
        case 0x00: return false     // resume
        default: return nil
        }
    }
}
