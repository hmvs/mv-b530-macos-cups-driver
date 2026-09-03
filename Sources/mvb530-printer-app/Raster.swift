/// PAPPL raster callbacks: greyscale raster in, MV-B530 command stream out.
///
/// PAPPL hands us the same shape of data the old CUPS filter received, so the
/// conversion is unchanged — `Bilevel` and `Wire` are reused as-is.
import CPAPPL
import CPAPPLSupport
import Foundation
import MVBImage
import MVBProtocol

/// x9 profile: 1600 dots across at 200 dpi.
let renderWidth = 1600

/// How dark a grey has to be before the head burns it, for text and line art.
///
/// Not the obvious 128, and the reason is not antialiasing: rendered with
/// antialiasing off, the rules a form draws are still grey. Documents draw
/// their borders in grey rather than black, so a threshold at half black
/// deletes them - the text between them prints perfectly and the page arrives
/// with no borders.
///
/// Measured over 22 pages of real documents, 16528 horizontal rules in all,
/// the greys they are drawn in cluster at 0, 8-10, 33-36, 110, 129, 145 and
/// 160. Two of the largest populations sit just above 128, which is why a
/// threshold there printed only 71.8% of them. 176 clears the highest common
/// one and prints 99.5%; from there to 240 the curve is flat, so a higher
/// level finds no more lines and only burns more of the page - and past about
/// 208 the haloes around glyphs start filling in, which spends head energy
/// and makes the page look heavier than it was drawn.
let lineArtThreshold = 176

/// Photographs go through error diffusion instead, where the same level would
/// simply darken the whole image.
let photoThreshold = 128

/// Per-job conversion state.
///
/// A single instance is safe: PAPPL runs one job at a time per printer, and
/// the callbacks below are only ever invoked from that job's thread.
final class RasterJob {
    var sourceWidth = 0
    var height = 0
    var bytesPerLine = 0
    var bitsPerPixel = 0
    var inverted = false
    var darkness = 3
    var dither: Dither = .atkinson
    /// Text and line art are printed hotter and slower than photographs; the
    /// x9 profile carries a separate set of head settings for each.
    var isText = true
    /// The printable window inside the sheet-wide raster, in source pixels.
    var windowStart = 0
    var windowWidth = 0
    /// Luma, one byte per pixel at the render width. White until written.
    var page = [UInt8]()
}

let rasterJob = RasterJob()

let startJobCallback: pappl_pr_rstartjob_cb_t = { _, _, _ in true }

let startPageCallback: pappl_pr_rstartpage_cb_t = { job, options, device, _ in
    guard let options else { return false }
    let header = options.pointee.header

    rasterJob.sourceWidth = Int(header.cupsWidth)
    rasterJob.height = Int(header.cupsHeight)
    rasterJob.bytesPerLine = Int(header.cupsBytesPerLine)
    rasterJob.bitsPerPixel = Int(header.cupsBitsPerPixel)
    rasterJob.inverted = header.cupsColorSpace == CUPS_CSPACE_K

    // The darkness set on the printer, adjusted by whatever the job asked for.
    rasterJob.darkness = Wire.blackeningLevel(
        configured: Int(options.pointee.darkness_configured),
        jobDelta: Int(options.pointee.print_darkness))

    // Photos want diffusion; text and line art are crisper with a threshold.
    // Everything that is not explicitly a photograph is treated as text,
    // because that is what this printer is nearly always asked for.
    let photo = options.pointee.print_content_optimize == PAPPL_CONTENT_PHOTO.rawValue
    rasterJob.isText = !photo
    switch configuredDither {
    case "diffuse", "atkinson": rasterJob.dither = .atkinson
    case "threshold", "none":   rasterJob.dither = .none
    default:                    rasterJob.dither = photo ? .atkinson : .none
    }

    guard rasterJob.sourceWidth > 0, rasterJob.height > 0,
          rasterJob.bytesPerLine > 0 else {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR, "empty raster page")
        return false
    }

    // A row buffer is only bytesPerLine long, so a header claiming more
    // pixels than fit would read past the end.
    let required: Int
    switch rasterJob.bitsPerPixel {
    case 1:  required = (rasterJob.sourceWidth + 7) / 8
    case 8:  required = rasterJob.sourceWidth
    case 24: required = rasterJob.sourceWidth * 3
    default: required = 0
    }
    guard required > 0, rasterJob.bytesPerLine >= required else {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR,
                    "inconsistent raster header: width=\(rasterJob.sourceWidth) "
                    + "bytesPerLine=\(rasterJob.bytesPerLine) "
                    + "bpp=\(rasterJob.bitsPerPixel)")
        return false
    }

    deviceLog("page \(rasterJob.sourceWidth)x\(rasterJob.height) at "
              + "\(rasterJob.bitsPerPixel) bpp, window "
              + "\(rasterJob.windowStart)+\(rasterJob.windowWidth)"
              + " -> \(renderWidth) dots, "
              + (rasterJob.isText ? "text" : "photo")
              + (rasterJob.dither == .atkinson ? ", diffused" : ", thresholded")
              + ", darkness \(rasterJob.darkness)")

    // PAPPL rasterises the whole sheet and marks the printable area with the
    // PWG image box. Printing that window, rather than the sheet, is what
    // keeps the page at its true size - and for A4 it is exactly the head's
    // width, so the pixels need no resampling at all.
    // cupsInteger is a C array, which Swift imports as a tuple: index 3 is
    // CUPS_RASTER_PWG_ImageBoxLeft and index 5 is ImageBoxRight.
    let boxLeft = Int(header.cupsInteger.3)
    let boxRight = Int(header.cupsInteger.5)
    if boxLeft >= 0, boxRight > boxLeft, boxRight < rasterJob.sourceWidth {
        rasterJob.windowStart = boxLeft
        rasterJob.windowWidth = boxRight - boxLeft + 1
    } else {
        rasterJob.windowStart = 0
        rasterJob.windowWidth = rasterJob.sourceWidth
    }

    rasterJob.page = [UInt8](repeating: 255, count: renderWidth * rasterJob.height)
    _ = device
    return true
}

let writeLineCallback: pappl_pr_rwriteline_cb_t = { _, _, _, y, line in
    guard let line, Int(y) < rasterJob.height else { return true }

    let row = Array(UnsafeBufferPointer(start: line,
                                        count: rasterJob.bytesPerLine))
    let luma = Bilevel.lumaRow(row[...], width: rasterJob.sourceWidth,
                               bitsPerPixel: rasterJob.bitsPerPixel,
                               polarity: rasterJob.inverted ? .blackIsHigh
                                                            : .whiteIsHigh)

    let end = min(rasterJob.windowStart + rasterJob.windowWidth, luma.count)
    let window = rasterJob.windowStart < end
        ? luma[rasterJob.windowStart..<end] : luma[...]
    let scaled = Bilevel.fitRow(window, to: renderWidth)
    let start = Int(y) * renderWidth
    rasterJob.page.replaceSubrange(start..<(start + renderWidth), with: scaled)
    return true
}

let endPageCallback: pappl_pr_rendpage_cb_t = { job, _, device, _ in
    guard !rasterJob.page.isEmpty else { return false }

    let bits = Bilevel.convert(luma: rasterJob.page, width: renderWidth,
                               height: rasterJob.height,
                               dither: rasterJob.dither,
                               threshold: rasterJob.isText ? configuredThreshold
                                                           : photoThreshold)
    guard !bits.isEmpty else {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR, "could not dither the page")
        return false
    }

    var options = JobOptions()
    options.blackening = rasterJob.darkness
    options.paperMode = .a4Sheet
    options.a4SheetMaxHeight = 2460

    // The head settings the x9 profile gives for each kind of page. Sending
    // the image ones for text is what makes a page of text come out faint:
    // the head is fired at less than half the energy the text mode asks for.
    options.isText = rasterJob.isText
    options.energy = rasterJob.isText ? 33000 : 15000
    options.speed = rasterJob.isText ? 30 : 40

    guard let stream = Wire.buildJob(pixels: bits, width: renderWidth,
                                     height: rasterJob.height,
                                     options: options) else {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR, "could not encode the page")
        return false
    }

    rasterJob.page = []

    let written = stream.withUnsafeBytes { raw in
        papplDeviceWrite(device, raw.baseAddress, raw.count)
    }
    if written != stream.count {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR,
                    "short write: \(written) of \(stream.count) bytes")
        return false
    }
    papplDeviceFlush(device)
    return true
}

let endJobCallback: pappl_pr_rendjob_cb_t = { _, _, _ in
    rasterJob.page = []
    return true
}

/// Prints a PWG raster *file*, as opposed to a raster stream over IPP.
///
/// PAPPL only streams raster through the callbacks above when the job arrives
/// over IPP. A job created from a file - which is how the web interface's test
/// page is submitted - looks for a filter to the driver's own format instead,
/// and aborts when it finds none. Declaring image/pwg-raster as that format
/// brings the file here, where it is read back and pushed through the very
/// same callbacks, so both routes share one implementation.
let printFileCallback: pappl_pr_printfile_cb_t = { job, options, device in
    guard let job, let options, let name = papplJobGetFilename(job) else {
        return false
    }

    let fd = open(name, O_RDONLY)
    guard fd >= 0 else {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR, "cannot open the job file")
        return false
    }
    defer { close(fd) }

    guard let raster = cupsRasterOpen(fd, CUPS_RASTER_READ) else {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR, "not a readable raster file")
        return false
    }
    defer { cupsRasterClose(raster) }

    guard startJobCallback(job, options, device) else { return false }

    var pages = 0
    var header = cups_page_header2_t()
    while cupsRasterReadHeader2(raster, &header) == 1 {
        // The page callbacks read their geometry from the options, which for a
        // file job describe no page until this is filled in.
        options.pointee.header = header
        guard startPageCallback(job, options, device, UInt32(pages + 1)) else {
            return false
        }

        var line = [UInt8](repeating: 0, count: Int(header.cupsBytesPerLine))
        for y in 0..<header.cupsHeight {
            guard cupsRasterReadPixels(raster, &line, header.cupsBytesPerLine)
                == header.cupsBytesPerLine else {
                mvb_log_job(job, PAPPL_LOGLEVEL_ERROR,
                            "raster ended after \(y) of \(header.cupsHeight) lines")
                return false
            }
            _ = writeLineCallback(job, options, device, y, &line)
        }

        guard endPageCallback(job, options, device, UInt32(pages + 1)) else {
            return false
        }
        pages += 1
    }

    guard pages > 0 else {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR, "no pages in the raster file")
        return false
    }

    return endJobCallback(job, options, device)
}
