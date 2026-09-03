/// Greyscale to 1-bit conversion for the thermal head.
///
/// CUPS hands the filter 8-bit greyscale at the PPD's imageable width; the
/// printer wants one bit per dot at the profile's render width. Everything
/// here works on a luma buffer where 0 is black and 255 is white.
import Foundation

public enum Dither: Sendable {
    /// Plain threshold. Best for text and line art.
    case none
    /// Diffuses error to neighbouring pixels. Best for photos.
    case atkinson
}

/// How a raster row encodes ink.
public enum Polarity: Sendable {
    /// 0 is black (CUPS_CSPACE_W / SW, and PWG sGray).
    case whiteIsHigh
    /// 255 is black (CUPS_CSPACE_K).
    case blackIsHigh
}

public enum Bilevel {
    /// Normalise one raster row to luma, where 0 is black and 255 is white.
    ///
    /// `row` must hold at least the bytes the geometry implies; callers are
    /// expected to have validated that against the raster header, since a
    /// header claiming more pixels than the row holds is a real failure mode.
    /// Anything unrecognised comes back white, so a page prints blank rather
    /// than solid black and wastes the sheet.
    public static func lumaRow(_ row: ArraySlice<UInt8>, width: Int,
                               bitsPerPixel: Int,
                               polarity: Polarity) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: max(0, width))
        guard width > 0 else { return out }
        let base = row.startIndex
        let inverted = polarity == .blackIsHigh

        switch bitsPerPixel {
        case 8:
            guard row.count >= width else { return out }
            for x in 0..<width {
                let value = row[base + x]
                out[x] = inverted ? 255 &- value : value
            }
        case 1:
            guard row.count >= (width + 7) / 8 else { return out }
            for x in 0..<width {
                let bit = (row[base + x / 8] >> UInt8(7 - x % 8)) & 1
                // In K a set bit means ink; in W it means white.
                let black = inverted ? bit == 1 : bit == 0
                out[x] = black ? 0 : 255
            }
        case 24:
            guard row.count >= width * 3 else { return out }
            for x in 0..<width {
                let r = Int(row[base + x * 3])
                let g = Int(row[base + x * 3 + 1])
                let b = Int(row[base + x * 3 + 2])
                // Rec. 601 luma, the usual greyscale conversion.
                out[x] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
            }
        default:
            break
        }
        return out
    }

    /// Scale one row horizontally with nearest-neighbour sampling. Cheap and
    /// artefact-free at the near-integer ratios we see, and it keeps hard
    /// edges crisp, which matters more than smoothness on a 1-bit device.
    /// Places one row of luma on the head's line.
    ///
    /// The raster covers the whole sheet, margins included, and names the
    /// printable window inside it. That window is what the head prints, so it
    /// is mapped across rather than the whole sheet being squeezed: for A4 the
    /// window is exactly the head's 1600 dots, and the pixels go straight
    /// through untouched. A narrower page - A5 on the same paper - is centred
    /// at its true size instead of being stretched to fit.
    public static func fitRow(_ window: ArraySlice<UInt8>,
                              to destinationWidth: Int) -> [UInt8] {
        guard destinationWidth > 0 else { return [] }
        guard window.count > destinationWidth else {
            var out = [UInt8](repeating: 255, count: destinationWidth)
            let offset = (destinationWidth - window.count) / 2
            for (index, value) in window.enumerated() {
                out[offset + index] = value
            }
            return out
        }
        return scaleRow(window, to: destinationWidth)
    }

    public static func scaleRow(_ source: ArraySlice<UInt8>,
                                to destinationWidth: Int) -> [UInt8] {
        guard destinationWidth > 0 else { return [] }
        let sourceWidth = source.count
        guard sourceWidth > 0 else {
            return [UInt8](repeating: 255, count: destinationWidth)
        }
        if sourceWidth == destinationWidth {
            return Array(source)
        }

        let base = source.startIndex
        var out = [UInt8](repeating: 0, count: destinationWidth)

        if destinationWidth < sourceWidth {
            // Downscaling keeps the darkest pixel of the span each destination
            // pixel covers, rather than sampling one of them. The output is
            // bilevel, and a sample that happens to land between the stems of a
            // letter deletes them: at A4's 1654 to 1600 that is 54 columns of
            // text thrown away. Taking the darkest cannot lose a stroke, and at
            // this ratio - barely more than one source pixel per destination
            // one - it does not thicken anything either.
            for x in 0..<destinationWidth {
                let start = (x * sourceWidth) / destinationWidth
                var end = ((x + 1) * sourceWidth) / destinationWidth
                if end <= start { end = start + 1 }

                var darkest = source[base + start]
                for sx in (start + 1)..<min(end, sourceWidth) {
                    darkest = min(darkest, source[base + sx])
                }
                out[x] = darkest
            }
            return out
        }

        for x in 0..<destinationWidth {
            // Sample the centre of the destination pixel. Sampling the left
            // edge instead shifts the image half a pixel, which shows up as a
            // shaved column at the page edge.
            var sx = ((2 * x + 1) * sourceWidth) / (2 * destinationWidth)
            if sx >= sourceWidth { sx = sourceWidth - 1 }
            out[x] = source[base + sx]
        }
        return out
    }

    /// Convert a greyscale image to one byte per pixel, 1 meaning "burn a
    /// dot". `threshold` is the luma cutoff.
    ///
    /// Returns an empty array when the dimensions do not match the buffer.
    public static func convert(luma: [UInt8], width: Int, height: Int,
                               dither: Dither, threshold: Int) -> [UInt8] {
        guard width > 0, height > 0, luma.count == width * height else {
            return []
        }
        switch dither {
        case .none:
            return luma.map { $0 < UInt8(clamping: threshold) ? 1 : 0 }
        case .atkinson:
            return atkinson(luma: luma, width: width, height: height,
                            threshold: threshold)
        }
    }

    /// Atkinson diffuses six eighths of the error and deliberately discards
    /// the rest, which keeps contrast high on a device that can only burn or
    /// not burn.
    ///
    ///          X  1  1
    ///       1  1  1
    ///          1            (each 1/8)
    private static func atkinson(luma: [UInt8], width: Int, height: Int,
                                 threshold: Int) -> [UInt8] {
        // Diffused error can push values outside 0...255, so accumulate wide.
        var buffer = luma.map { Int($0) }
        var out = [UInt8](repeating: 0, count: luma.count)

        for y in 0..<height {
            for x in 0..<width {
                let at = y * width + x
                let old = buffer[at]
                let new = old < threshold ? 0 : 255
                out[at] = new == 0 ? 1 : 0

                let error = (old - new) / 8
                if error == 0 { continue }

                if x + 1 < width { buffer[at + 1] += error }
                if x + 2 < width { buffer[at + 2] += error }
                if y + 1 < height {
                    let below = at + width
                    if x > 0 { buffer[below - 1] += error }
                    buffer[below] += error
                    if x + 1 < width { buffer[below + 1] += error }
                }
                if y + 2 < height { buffer[at + 2 * width] += error }
            }
        }
        return out
    }
}
