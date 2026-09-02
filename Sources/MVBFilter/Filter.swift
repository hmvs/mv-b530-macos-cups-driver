/// CUPS raster in, MV-B530 command stream out.
///
/// Kept separate from the executable so tests can drive it directly with a
/// synthetic raster instead of going through cupsd.
import CCups
import Foundation
import MVBImage
import MVBProtocol

/// x9 profile: 1600 dots across at 200 dpi.
public let renderWidthDefault = 1600

public struct FilterOptions: Sendable {
    public var renderWidth = renderWidthDefault
    public var darkness = 3
    public var threshold = 128
    public var dither: Dither = .atkinson
    public var copies = 1
    public var job = JobOptions()

    public init() {}

    /// Apply a CUPS option string such as `"Darkness=4 MvbDither=None"`.
    public mutating func apply(optionString: String?) {
        guard let optionString else { return }

        // Only match at a token boundary, so "Darkness" does not also match
        // "ExtraDarkness".
        func value(for key: String) -> String? {
            for token in optionString.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let parts = token.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == Substring(key) {
                    return String(parts[1])
                }
            }
            return nil
        }

        if let raw = value(for: "Darkness"), let parsed = Int(raw),
           (1...5).contains(parsed) {
            darkness = parsed
        }
        if let raw = value(for: "MvbDither") {
            dither = raw.lowercased() == "none" ? .none : .atkinson
        }
        if let raw = value(for: "MvbThreshold"), let parsed = Int(raw),
           (1...255).contains(parsed) {
            threshold = parsed
        }
        if let raw = value(for: "copies"), let parsed = Int(raw),
           (1...100).contains(parsed) {
            copies = parsed
        }
    }
}

public enum FilterError: Error, CustomStringConvertible {
    case cannotOpenRaster
    case inconsistentHeader(width: Int, bytesPerLine: Int, bitsPerPixel: Int)
    case encodingFailed

    public var description: String {
        switch self {
        case .cannotOpenRaster:
            return "input is not a readable CUPS raster stream"
        case let .inconsistentHeader(width, bytesPerLine, bitsPerPixel):
            return """
                raster header is inconsistent: width=\(width) \
                bytesPerLine=\(bytesPerLine) bitsPerPixel=\(bitsPerPixel)
                """
        case .encodingFailed:
            return "could not encode the page"
        }
    }
}

public enum Filter {
    /// Read every page from `inputFD` and hand each encoded job to `sink`.
    /// Returns the number of pages converted.
    public static func process(inputFD: Int32,
                               options: FilterOptions,
                               sink: ([UInt8]) throws -> Void) throws -> Int {
        // A zero-byte job means "nothing to print", not a broken stream, and
        // cupsRasterOpen cannot tell the two apart. Only seekable inputs can
        // be checked this way; a pipe falls through to the normal path.
        let size = lseek(inputFD, 0, SEEK_END)
        if size == 0 { return 0 }
        if size > 0 { _ = lseek(inputFD, 0, SEEK_SET) }

        guard let raster = cupsRasterOpen(inputFD, CUPS_RASTER_READ) else {
            throw FilterError.cannotOpenRaster
        }
        defer { cupsRasterClose(raster) }

        var header = cups_page_header2_t()
        var pages = 0

        while cupsRasterReadHeader2(raster, &header) != 0 {
            try convertPage(raster: raster, header: header,
                            options: options, sink: sink)
            pages += 1
        }
        return pages
    }

    private static func convertPage(raster: OpaquePointer,
                                    header: cups_page_header2_t,
                                    options: FilterOptions,
                                    sink: ([UInt8]) throws -> Void) throws {
        let sourceWidth = Int(header.cupsWidth)
        let height = Int(header.cupsHeight)
        let bytesPerLine = Int(header.cupsBytesPerLine)
        let bitsPerPixel = Int(header.cupsBitsPerPixel)
        guard sourceWidth > 0, height > 0, bytesPerLine > 0 else { return }

        // A row buffer is only bytesPerLine long, so a header claiming more
        // pixels than fit would otherwise read past the end.
        let requiredBytes: Int
        switch bitsPerPixel {
        case 1:  requiredBytes = (sourceWidth + 7) / 8
        case 8:  requiredBytes = sourceWidth
        case 24: requiredBytes = sourceWidth * 3
        default: requiredBytes = 0
        }
        guard requiredBytes > 0, bytesPerLine >= requiredBytes else {
            throw FilterError.inconsistentHeader(width: sourceWidth,
                                                 bytesPerLine: bytesPerLine,
                                                 bitsPerPixel: bitsPerPixel)
        }

        let destinationWidth = options.renderWidth
        var page = [UInt8](repeating: 255, count: destinationWidth * height)
        var row = [UInt8](repeating: 0, count: bytesPerLine)

        let inverted = header.cupsColorSpace == CUPS_CSPACE_K

        for y in 0..<height {
            let read = row.withUnsafeMutableBufferPointer { buffer -> UInt32 in
                cupsRasterReadPixels(raster, buffer.baseAddress,
                                     UInt32(bytesPerLine))
            }
            if read == 0 {
                // Short page: leave the rest white so a truncated job still
                // prints the part that arrived.
                break
            }

            let luma = lumaRow(row, width: sourceWidth,
                               bitsPerPixel: bitsPerPixel, inverted: inverted)
            let scaled = Bilevel.scaleRow(luma[...], to: destinationWidth)
            page.replaceSubrange(y * destinationWidth ..< (y + 1) * destinationWidth,
                                 with: scaled)
        }

        let bits = Bilevel.convert(luma: page, width: destinationWidth,
                                   height: height, dither: options.dither,
                                   threshold: options.threshold)
        guard !bits.isEmpty else { throw FilterError.encodingFailed }

        var job = options.job
        job.blackening = options.darkness

        guard let stream = Wire.buildJob(pixels: bits, width: destinationWidth,
                                         height: height, options: job) else {
            throw FilterError.encodingFailed
        }
        for _ in 0..<max(1, options.copies) {
            try sink(stream)
        }
    }

    /// Normalise one raster row to luma, where 0 is black and 255 is white.
    static func lumaRow(_ row: [UInt8], width: Int, bitsPerPixel: Int,
                        inverted: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width)

        switch bitsPerPixel {
        case 8:
            for x in 0..<width {
                out[x] = inverted ? 255 &- row[x] : row[x]
            }
        case 1:
            for x in 0..<width {
                let bit = (row[x / 8] >> UInt8(7 - x % 8)) & 1
                // In K a set bit means ink; in W it means white.
                let black = inverted ? bit == 1 : bit == 0
                out[x] = black ? 0 : 255
            }
        case 24:
            for x in 0..<width {
                let r = Int(row[x * 3])
                let g = Int(row[x * 3 + 1])
                let b = Int(row[x * 3 + 2])
                // Rec. 601 luma, the usual greyscale conversion.
                out[x] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
            }
        default:
            break
        }
        return out
    }
}
