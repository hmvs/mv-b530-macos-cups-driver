/// Wire protocol for MV-B530 class thermal printers (the "tiny" family,
/// `line_eight` variant).
///
/// Packet framing:
///
///     51 78 | cmd 00 len_lo len_hi | payload | crc8(payload) ff
///
/// A job is: blackening, energy, print mode, feed, one packet per pixel row
/// (plus a feed every 200 rows), a tail feed, then a device-state query.
import Foundation

public enum Encoding: Sendable {
    case rle
    case raw
}

public enum PaperMode: Sendable {
    case plain
    case a4Sheet
}

public struct JobOptions: Sendable {
    /// Clamped to 1...5 when the job is built.
    public var blackening: Int = 3
    /// The energy packet is omitted entirely when this is not positive.
    public var energy: Int = 15000
    public var isText: Bool = false
    public var speed: Int = 40
    /// Bit order for the raw fallback rows.
    public var lsbFirst: Bool = true
    public var encoding: Encoding = .rle
    public var paperMode: PaperMode = .a4Sheet
    /// Zero selects the resolution-dependent default.
    public var a4SheetMaxHeight: Int = 2460
    public var postPrintFeedCount: Int = 2
    public var devDPI: Int = 200
    /// White pixels prepended to every row. The x9 head is 1632 dots wide and
    /// the printable area starts 32 in, so a page rendered at 1600 has to be
    /// shifted by that much or it prints 4 mm left of where it should.
    public var leftPadding: Int = 32
    public var endsMediaPage: Bool = true

    /// Defaults matching the x9 profile, which is what MV-B530 resolves to.
    public init() {}
}

public enum Wire {
    static let prefix: [UInt8] = [0x51, 0x78]

    enum Command {
        static let retract: UInt8 = 0xA0
        static let feedCheck: UInt8 = 0xA1
        static let lineRaw: UInt8 = 0xA2
        static let deviceState: UInt8 = 0xA3
        static let blackening: UInt8 = 0xA4
        static let energy: UInt8 = 0xAF
        static let feed: UInt8 = 0xBD
        static let printMode: UInt8 = 0xBE
        static let lineRLE: UInt8 = 0xBF
    }

    static let feedEveryRows = 200
    static let maxRun = 127

    /// CRC-8, polynomial 0x07, init 0x00, no reflection, no final xor.
    public static func crc8<C: Collection>(_ data: C) -> UInt8
    where C.Element == UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    public static func packet(_ command: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 8)
        appendPacket(&out, command, payload)
        return out
    }

    static func appendPacket(_ out: inout [UInt8], _ command: UInt8,
                             _ payload: [UInt8]) {
        let length = payload.count
        out.append(contentsOf: prefix)
        out.append(command)
        out.append(0x00)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(contentsOf: payload)
        out.append(crc8(payload))
        out.append(0xFF)
    }

    /// Run-length encode one row of 0/1 pixels. Each byte is
    /// `(colour << 7) | run`, with runs longer than 127 split across bytes.
    public static func rleEncodeLine<C: Collection>(_ line: C) -> [UInt8]
    where C.Element == UInt8 {
        var out = [UInt8]()
        guard let first = line.first else { return out }
        out.reserveCapacity(min(line.count, 256))

        var previous: UInt8 = first != 0 ? 1 : 0
        var count = 0

        func flush() {
            var remaining = count
            while remaining > maxRun {
                out.append((previous << 7) | UInt8(maxRun))
                remaining -= maxRun
            }
            if remaining > 0 {
                out.append((previous << 7) | UInt8(remaining))
            }
        }

        for pixel in line {
            let value: UInt8 = pixel != 0 ? 1 : 0
            if value == previous {
                count += 1
            } else {
                flush()
                previous = value
                count = 1
            }
        }
        flush()
        return out
    }

    /// Pack 0/1 pixels into bits, one byte per eight pixels.
    public static func packLine<C: Collection>(_ line: C,
                                               lsbFirst: Bool) -> [UInt8]
    where C.Element == UInt8 {
        let width = line.count
        var out = [UInt8](repeating: 0, count: (width + 7) / 8)
        for (index, pixel) in line.enumerated() where pixel != 0 {
            let bit = index % 8
            out[index / 8] |= 1 << UInt8(lsbFirst ? bit : 7 - bit)
        }
        return out
    }

    /// Dots to feed after the last row. May be negative, which retracts.
    public static func tailFeed(height: Int, options: JobOptions) -> Int {
        switch options.paperMode {
        case .a4Sheet:
            var maxHeight = options.a4SheetMaxHeight
            if maxHeight <= 0 {
                maxHeight = options.devDPI == 300 ? 3800 : 2400
            }
            return max(0, maxHeight - height)
        case .plain:
            // MSB-order devices use a fixed feed; the rest scale with the
            // number of sheets the user asked to eject.
            if !options.lsbFirst { return 100 }
            let dotsPerPaper = options.devDPI == 300 ? 72 : 48
            return max(0, options.postPrintFeedCount + 1) * dotsPerPaper
        }
    }

    /// The printer's 1...5 blackening level for an IPP darkness setting.
    ///
    /// IPP splits darkness in two: printer-darkness-configured is the printer's
    /// own setting, 0 to 100, and a job's print-darkness is a relative
    /// adjustment either side of it. Both have to be read - taking only the
    /// job's leaves the printer's own control doing nothing at all.
    public static func blackeningLevel(configured: Int, jobDelta: Int) -> Int {
        let combined = min(100, max(0, configured + jobDelta))
        return min(5, max(1, 1 + combined * 4 / 100))
    }

    /// Build a complete job from one byte per pixel (0 or 1), row-major.
    ///
    /// Returns nil when `pixels` does not hold exactly `width * height`
    /// entries, rather than reading past the end.
    public static func buildJob(pixels: [UInt8], width: Int, height: Int,
                                options: JobOptions) -> [UInt8]? {
        guard width > 0, height > 0, pixels.count == width * height else {
            return nil
        }

        let padding = max(0, options.leftPadding)
        let paddedWidth = width + padding
        let widthBytes = (paddedWidth + 7) / 8

        var out = [UInt8]()
        out.reserveCapacity(height * (widthBytes + 8) + 64)

        let blackening = min(5, max(1, options.blackening))
        appendPacket(&out, Command.blackening, [UInt8(0x30 + blackening)])

        if options.energy > 0 {
            appendPacket(&out, Command.energy, [
                UInt8(options.energy & 0xFF),
                UInt8((options.energy >> 8) & 0xFF),
            ])
        }

        appendPacket(&out, Command.printMode, [options.isText ? 1 : 0])
        appendPacket(&out, Command.feed, [UInt8(options.speed & 0xFF)])

        var row = [UInt8](repeating: 0, count: paddedWidth)
        for y in 0..<height {
            let start = y * width
            for x in 0..<width {
                row[padding + x] = pixels[start + x]
            }

            var emitted = false
            if options.encoding == .rle {
                let encoded = rleEncodeLine(row)
                if encoded.count <= widthBytes {
                    appendPacket(&out, Command.lineRLE, encoded)
                    emitted = true
                }
            }
            if !emitted {
                appendPacket(&out, Command.lineRaw,
                             packLine(row, lsbFirst: options.lsbFirst))
            }

            if (y + 1) % feedEveryRows == 0 {
                appendPacket(&out, Command.feed, [UInt8(options.speed & 0xFF)])
            }
        }

        if options.endsMediaPage {
            let amount = tailFeed(height: height, options: options)
            let command = amount < 0 ? Command.retract : Command.feedCheck
            let magnitude = abs(amount)
            appendPacket(&out, command, [
                UInt8(magnitude & 0xFF),
                UInt8((magnitude >> 8) & 0xFF),
                0x11,
            ])
        }

        appendPacket(&out, Command.deviceState, [0x00])
        return out
    }
}
