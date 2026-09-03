/// The web interface's "Print Test Page" button.
///
/// PAPPL asks the driver for a file and submits it as an ordinary job, so the
/// page has to be in a format the printer accepts. This build advertises only
/// PWG raster and URF - PAPPL was compiled without the image libraries - so a
/// raster file is what gets written, drawn with CoreGraphics and CoreText and
/// handed back through the normal job path. That means the test page exercises
/// the same code a real print does.
import CPAPPL
import CoreGraphics
import CoreText
import Foundation

/// A4 at 200 dpi. The driver rescales to the head's 1600 dots either way, so
/// these need only be the right shape.
private let pageWidth = 1654
private let pageHeight = 2339
private let dpi = 200

/// Rewritten in place rather than accumulating temporary files.
private var testPagePath: String {
    NSTemporaryDirectory() + "mvb530-testpage.pwg"
}

private func draw(into context: CGContext) {
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

    // CoreGraphics counts up from the bottom; everything below is placed from
    // the top, which is how the page reads.
    func fromTop(_ y: Int) -> CGFloat { CGFloat(pageHeight - y) }

    func text(_ string: String, size: CGFloat, x: Int, top: Int, bold: Bool = false) {
        let font = CTFontCreateWithName(
            (bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: string,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 0, alpha: 1),
            ]))
        context.textPosition = CGPoint(x: CGFloat(x), y: fromTop(top))
        CTLineDraw(line, context)
    }

    func rule(top: Int, height: Int = 3, from: Int = 120, to: Int = pageWidth - 120) {
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: CGFloat(from), y: fromTop(top),
                            width: CGFloat(to - from), height: CGFloat(height)))
    }

    text("Anko Inkless A4", size: 74, x: 120, top: 220, bold: true)
    text("MV-B530 test page", size: 38, x: 120, top: 290)
    rule(top: 330)

    let stamp = DateFormatter()
    stamp.dateFormat = "d MMMM yyyy, HH:mm"
    text(stamp.string(from: Date()), size: 32, x: 120, top: 420)
    text("200 dpi greyscale over Bluetooth LE", size: 32, x: 120, top: 480)

    // A grey ramp: the head's response is not linear, and this is where the
    // darkness setting shows its effect.
    text("Greys", size: 34, x: 120, top: 620, bold: true)
    for step in 0..<10 {
        context.setFillColor(gray: CGFloat(step) / 9.0, alpha: 1)
        context.fill(CGRect(x: CGFloat(120 + step * 140), y: fromTop(780),
                            width: 130, height: 120))
    }

    // Thin lines and gaps at 1, 2 and 4 dots: anything missing here is a dead
    // element or a paper-feed problem rather than a driver fault.
    text("Fine lines", size: 34, x: 120, top: 920, bold: true)
    var y = 960
    for thickness in [1, 2, 4] {
        var x = 120
        while x < pageWidth - 120 {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: CGFloat(x), y: fromTop(y + 60),
                                width: CGFloat(thickness), height: 60))
            x += thickness * 4
        }
        y += 90
    }

    text("Text sizes", size: 34, x: 120, top: 1320, bold: true)
    var top = 1380
    for size in [16, 20, 26, 34, 44] {
        text("The quick brown fox jumps over the lazy dog - \(size) pt",
             size: CGFloat(size), x: 120, top: top)
        top += size + 34
    }

    rule(top: 1700)
    text("If the greys step evenly and the fine lines are unbroken,",
         size: 28, x: 120, top: 1770)
    text("the printer and this driver are working.", size: 28, x: 120, top: 1815)
    text("github.com/hmvs/mv-b530-macos-cups-driver", size: 26, x: 120, top: 1900)
}

/// Renders the page and writes it as PWG raster. Returns the path, or nil if
/// anything failed - PAPPL then reports that there is no test page.
private func writeTestPage() -> String? {
    let stride = pageWidth
    var pixels = [UInt8](repeating: 0xff, count: stride * pageHeight)

    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: pageWidth, height: pageHeight,
            bitsPerComponent: 8, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        draw(into: context)
        return true
    }
    guard drawn else { return nil }

    guard let media = pwgMediaForPWG("iso_a4_210x297mm") else { return nil }
    var header = cups_page_header2_t()
    guard cupsRasterInitPWGHeader(&header, media, "sgray_8",
                                  Int32(dpi), Int32(dpi), "one-sided", nil) == 1
    else { return nil }

    let path = testPagePath
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    guard let raster = cupsRasterOpen(fd, CUPS_RASTER_WRITE_PWG) else { return nil }
    defer { cupsRasterClose(raster) }

    // The header's own geometry wins: PWG raster readers trust it, and it may
    // differ by a dot or two from the numbers used for drawing.
    let width = Int(header.cupsWidth)
    let height = Int(header.cupsHeight)
    let bytesPerLine = Int(header.cupsBytesPerLine)
    guard cupsRasterWriteHeader2(raster, &header) == 1 else { return nil }

    var row = [UInt8](repeating: 0xff, count: bytesPerLine)
    for line in 0..<height {
        // A CoreGraphics bitmap is stored top row first, the same order raster
        // lines are written in, so the rows are copied straight across. Only
        // the drawing needs flipping, and fromTop() above does that.
        let source = line * stride
        if line < pageHeight {
            for x in 0..<min(width, pageWidth, bytesPerLine) {
                row[x] = pixels[source + x]
            }
        }
        guard cupsRasterWritePixels(raster, &row, UInt32(bytesPerLine))
            == UInt32(bytesPerLine) else { return nil }
    }

    return path
}

/// PAPPL's test page callback: hand back a file it can print.
let testPageCallback: pappl_pr_testpage_cb_t = { printer, buffer, size in
    guard let buffer, size > 0 else { return nil }
    _ = printer

    guard let path = writeTestPage() else {
        deviceLog("test page: could not be generated")
        buffer[0] = 0
        return nil
    }

    deviceLog("test page: written to \(path)")
    _ = path.withCString { strlcpy(buffer, $0, size) }
    return UnsafePointer(buffer)
}
