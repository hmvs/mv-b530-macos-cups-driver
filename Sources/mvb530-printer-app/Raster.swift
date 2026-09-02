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

    // print-darkness arrives as -100...100; map it onto the printer's 1...5.
    let requested = Int(options.pointee.print_darkness)
    rasterJob.darkness = requested == 0 ? 3 : min(5, max(1, (requested + 100) * 5 / 200 + 1))

    // Photos want diffusion; text and line art are crisper with a threshold.
    rasterJob.dither = options.pointee.print_content_optimize == PAPPL_CONTENT_PHOTO.rawValue
        ? .atkinson : .none

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

    rasterJob.page = [UInt8](repeating: 255, count: renderWidth * rasterJob.height)
    _ = device
    return true
}

let writeLineCallback: pappl_pr_rwriteline_cb_t = { _, _, _, y, line in
    guard let line, Int(y) < rasterJob.height else { return true }

    let row = UnsafeBufferPointer(start: line, count: rasterJob.bytesPerLine)
    var luma = [UInt8](repeating: 255, count: rasterJob.sourceWidth)

    switch rasterJob.bitsPerPixel {
    case 8:
        for x in 0..<rasterJob.sourceWidth {
            luma[x] = rasterJob.inverted ? 255 &- row[x] : row[x]
        }
    case 1:
        for x in 0..<rasterJob.sourceWidth {
            let bit = (row[x / 8] >> UInt8(7 - x % 8)) & 1
            // In K a set bit means ink; in W it means white.
            let black = rasterJob.inverted ? bit == 1 : bit == 0
            luma[x] = black ? 0 : 255
        }
    case 24:
        for x in 0..<rasterJob.sourceWidth {
            let r = Int(row[x * 3]), g = Int(row[x * 3 + 1]), b = Int(row[x * 3 + 2])
            // Rec. 601 luma.
            luma[x] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
        }
    default:
        break
    }

    let scaled = Bilevel.scaleRow(luma[...], to: renderWidth)
    let start = Int(y) * renderWidth
    rasterJob.page.replaceSubrange(start..<(start + renderWidth), with: scaled)
    return true
}

let endPageCallback: pappl_pr_rendpage_cb_t = { job, _, device, _ in
    guard !rasterJob.page.isEmpty else { return false }

    let bits = Bilevel.convert(luma: rasterJob.page, width: renderWidth,
                               height: rasterJob.height,
                               dither: rasterJob.dither, threshold: 128)
    guard !bits.isEmpty else {
        mvb_log_job(job, PAPPL_LOGLEVEL_ERROR, "could not dither the page")
        return false
    }

    var options = JobOptions()
    options.blackening = rasterJob.darkness
    options.paperMode = .a4Sheet
    options.a4SheetMaxHeight = 2460

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
