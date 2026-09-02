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

public enum Bilevel {
    /// Scale one row horizontally with nearest-neighbour sampling. Cheap and
    /// artefact-free at the near-integer ratios we see, and it keeps hard
    /// edges crisp, which matters more than smoothness on a 1-bit device.
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
