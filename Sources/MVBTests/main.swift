/// Test runner for the MV-B530 driver.
///
/// Built as an executable rather than an XCTest bundle so it runs with the
/// Command Line Tools alone — XCTest needs xcode-select pointed at a full
/// Xcode, which is a lot to ask of someone who just wants their printer to
/// work.
import CCups
import Foundation
import MVBFilter
import MVBImage
import MVBProtocol

var checksRun = 0
var checksFailed = 0
var currentGroup = ""

func group(_ name: String) {
    currentGroup = name
    print(name)
}

func check(_ condition: Bool, _ message: @autoclosure () -> String,
           line: Int = #line) {
    checksRun += 1
    if !condition {
        checksFailed += 1
        print("  FAIL \(currentGroup):\(line): \(message())")
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func unhex(_ string: String) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(string.count / 2)
    var index = string.startIndex
    while index < string.endIndex,
          let next = string.index(index, offsetBy: 2, limitedBy: string.endIndex) {
        out.append(UInt8(string[index..<next], radix: 16) ?? 0)
        index = next
    }
    return out
}

// MARK: - CRC-8

func testCRC8() {
    group("crc8")
    // 0x33 -> 0x99 is lifted from a packet the printer actually accepted.
    check(Wire.crc8([0x33]) == 0x99,
          "crc8(0x33) = \(Wire.crc8([0x33])), want 0x99")
    check(Wire.crc8([]) == 0x00, "crc8 of empty input must be 0")
    check(Wire.crc8([0x00]) == 0x00, "crc8(0x00) must be 0")
    // CRC-8/ATM check value.
    check(Wire.crc8(Array("123456789".utf8)) == 0xF4,
          "crc8(\"123456789\") = \(Wire.crc8(Array("123456789".utf8))), want 0xf4")
    check(Wire.crc8([0x98, 0x3A]) == 0xEF,
          "crc8(983a) = \(Wire.crc8([0x98, 0x3A])), want 0xef")
}

// MARK: - Framing

func testFraming() {
    group("framing")
    check(hex(Wire.packet(0xA4, [0x33])) == "5178a40001003399ff",
          "framing = \(hex(Wire.packet(0xA4, [0x33])))")

    // Length is little-endian across two bytes, so >255 must not truncate.
    let big = Wire.packet(0xBF, [UInt8](repeating: 0, count: 300))
    check(big.count == 300 + 8, "big packet length = \(big.count)")
    check(big[4] == 0x2C && big[5] == 0x01,
          "length bytes = \(big[4]) \(big[5]), want 44 1")
    check(big.last == 0xFF, "packet must end with 0xff")

    let empty = Wire.packet(0xA3, [])
    check(empty.count == 8, "empty packet length = \(empty.count), want 8")
}

// MARK: - RLE

func testRLE() {
    group("rle")
    check(Wire.rleEncodeLine([UInt8](repeating: 0, count: 8)) == [0x08],
          "all white must encode to one run")
    check(Wire.rleEncodeLine([UInt8](repeating: 1, count: 8)) == [0x88],
          "all black must encode to one run")
    check(Wire.rleEncodeLine([0, 1, 0, 1] as [UInt8]) == [0x01, 0x81, 0x01, 0x81],
          "alternating pixels")

    // Runs longer than 127 split, remainder last.
    check(Wire.rleEncodeLine([UInt8](repeating: 1, count: 300)) == [0xFF, 0xFF, 0xAE],
          "long run splits at 127")
    check(Wire.rleEncodeLine([UInt8](repeating: 1, count: 127)) == [0xFF],
          "exactly 127 stays one byte")
    check(Wire.rleEncodeLine([UInt8](repeating: 1, count: 128)) == [0xFF, 0x81],
          "128 splits into two")
    check(Wire.rleEncodeLine([UInt8]()).isEmpty,
          "empty line encodes to nothing")
}

// MARK: - Bit packing

func testPackLine() {
    group("packLine")
    let line: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0]
    check(Wire.packLine(line, lsbFirst: true) == [0x01], "lsb-first")
    check(Wire.packLine(line, lsbFirst: false) == [0x80], "msb-first")
    // A partial final byte is zero-padded.
    check(Wire.packLine([1, 1, 1, 1] as [UInt8], lsbFirst: false) == [0xF0],
          "partial byte padding")
}

// MARK: - Tail feed

func testTailFeed() {
    group("tailFeed")
    var options = JobOptions()
    options.paperMode = .a4Sheet
    options.a4SheetMaxHeight = 2460
    check(Wire.tailFeed(height: 2300, options: options) == 160,
          "a4 tail = \(Wire.tailFeed(height: 2300, options: options)), want 160")
    check(Wire.tailFeed(height: 3000, options: options) == 0,
          "a4 tail must clamp at 0 for an over-long page")

    options.a4SheetMaxHeight = 0
    check(Wire.tailFeed(height: 400, options: options) == 2000,
          "a4 default tail = \(Wire.tailFeed(height: 400, options: options))")

    options.paperMode = .plain
    options.postPrintFeedCount = 2
    check(Wire.tailFeed(height: 20, options: options) == 144,
          "plain tail = \(Wire.tailFeed(height: 20, options: options)), want 144")

    options.devDPI = 300
    check(Wire.tailFeed(height: 20, options: options) == 216,
          "plain 300dpi tail = \(Wire.tailFeed(height: 20, options: options))")

    options.lsbFirst = false
    check(Wire.tailFeed(height: 20, options: options) == 100,
          "msb-order tail = \(Wire.tailFeed(height: 20, options: options))")
}

// MARK: - Job guards

func testBuildJobGuards() {
    group("buildJob guards")
    check(Wire.buildJob(pixels: [1, 0, 1], width: 2, height: 2,
                        options: JobOptions()) == nil,
          "mismatched pixel count must be rejected")
    check(Wire.buildJob(pixels: [], width: 0, height: 0,
                        options: JobOptions()) == nil,
          "zero dimensions must be rejected")
    check(Wire.buildJob(pixels: [1], width: 1, height: 1,
                        options: JobOptions()) != nil,
          "a well-formed one-pixel job must build")
}

// MARK: - Golden vectors

struct Fixture {
    var name = ""
    var width = 0
    var height = 0
    var a4Max = 0
    var leftPad = 0
    var isText = false
    var lsbFirst = true
    var raw = false
    var a4Sheet = false
    var speed = 40
    var energy = 15000
    var blackening = 3
    var pixelsHex = ""
    var expected = ""
}

func unpackPixels(_ hexString: String, width: Int, height: Int) -> [UInt8] {
    let packed = unhex(hexString)
    let stride = (width + 7) / 8
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let index = y * stride + x / 8
            guard index < packed.count else { continue }
            pixels[y * width + x] = (packed[index] >> UInt8(7 - x % 8)) & 1
        }
    }
    return pixels
}

func runFixture(_ fixture: Fixture) {
    var options = JobOptions()
    options.speed = fixture.speed
    options.energy = fixture.energy
    options.blackening = fixture.blackening
    options.isText = fixture.isText
    options.lsbFirst = fixture.lsbFirst
    options.leftPadding = fixture.leftPad
    options.encoding = fixture.raw ? .raw : .rle
    options.paperMode = fixture.a4Sheet ? .a4Sheet : .plain
    options.a4SheetMaxHeight = fixture.a4Max

    let pixels = unpackPixels(fixture.pixelsHex, width: fixture.width,
                              height: fixture.height)
    guard let stream = Wire.buildJob(pixels: pixels, width: fixture.width,
                                     height: fixture.height,
                                     options: options) else {
        check(false, "\(fixture.name): buildJob returned nil")
        return
    }

    let got = hex(stream)
    checksRun += 1
    if got != fixture.expected {
        checksFailed += 1
        let gotBytes = Array(got.utf8)
        let wantBytes = Array(fixture.expected.utf8)
        var at = 0
        while at < min(gotBytes.count, wantBytes.count),
              gotBytes[at] == wantBytes[at] { at += 1 }
        print("  FAIL golden \(fixture.name): differs at byte \(at / 2)")
        let from = max(0, at - 20)
        print("       got  ...\(String(got.dropFirst(from).prefix(40)))")
        print("       want ...\(String(fixture.expected.dropFirst(from).prefix(40)))")
    }
}

func testGolden(path: String) {
    group("golden")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        check(false, "cannot read fixtures at \(path)")
        return
    }

    var fixture = Fixture()
    var count = 0

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: " ", maxSplits: 1)
        let key = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]) : ""

        switch key {
        case "case":       fixture = Fixture(); fixture.name = value
        case "width":      fixture.width = Int(value) ?? 0
        case "height":     fixture.height = Int(value) ?? 0
        case "paper":      fixture.a4Sheet = (value == "a4_sheet")
        case "a4max":      fixture.a4Max = Int(value) ?? 0
        case "leftpad":    fixture.leftPad = Int(value) ?? 0
        case "istext":     fixture.isText = (value == "1")
        case "lsbfirst":   fixture.lsbFirst = (value == "1")
        case "encoding":   fixture.raw = (value == "raw")
        case "speed":      fixture.speed = Int(value) ?? 0
        case "energy":     fixture.energy = Int(value) ?? 0
        case "blackening": fixture.blackening = Int(value) ?? 0
        case "pixels":     fixture.pixelsHex = value
        case "expected":   fixture.expected = value
        case "end":        runFixture(fixture); count += 1
        default:           break
        }
    }

    print("  (\(count) golden cases)")
    check(count == 13, "expected 13 golden cases, parsed \(count)")
}

// MARK: - Scaling and dithering

func testScaling() {
    group("scaling")
    let source: [UInt8] = [10, 20, 30, 40]
    check(Bilevel.scaleRow(source[...], to: 4) == source,
          "equal widths must copy unchanged")

    let eight: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
    check(Bilevel.scaleRow(eight[...], to: 4) == [1, 3, 5, 7],
          "downscale = \(Bilevel.scaleRow(eight[...], to: 4))")

    let two: [UInt8] = [100, 200]
    check(Bilevel.scaleRow(two[...], to: 4) == [100, 100, 200, 200],
          "upscale = \(Bilevel.scaleRow(two[...], to: 4))")

    // A black column at each edge must survive: losing them shows up as a
    // page border with shaved sides.
    var wide = [UInt8](repeating: 255, count: 1654)
    wide[0] = 0
    wide[wide.count - 1] = 0
    let scaled = Bilevel.scaleRow(wide[...], to: 1600)
    check(scaled.first == 0, "first column lost in scaling")
    check(scaled.last == 0, "last column lost in scaling")

    check(Bilevel.scaleRow(ArraySlice<UInt8>(), to: 4) == [255, 255, 255, 255],
          "empty source must produce white")
    check(Bilevel.scaleRow(two[...], to: 0).isEmpty,
          "zero width must produce nothing")

    // Scaling must work on a slice that does not start at zero.
    let slice = eight[4...]
    check(Bilevel.scaleRow(slice, to: 2) == [5, 7],
          "slice with non-zero start = \(Bilevel.scaleRow(slice, to: 2))")
}

func testBilevel() {
    group("bilevel")
    let luma: [UInt8] = [0, 100, 127, 128, 255]
    let bits = Bilevel.convert(luma: luma, width: 5, height: 1,
                               dither: .none, threshold: 128)
    check(bits == [1, 1, 1, 0, 0], "threshold = \(bits)")

    let count = 64 * 64
    let white = Bilevel.convert(luma: [UInt8](repeating: 255, count: count),
                                width: 64, height: 64,
                                dither: .atkinson, threshold: 128)
    check(white.reduce(0) { $0 + Int($1) } == 0, "pure white must burn nothing")

    let black = Bilevel.convert(luma: [UInt8](repeating: 0, count: count),
                                width: 64, height: 64,
                                dither: .atkinson, threshold: 128)
    check(black.reduce(0) { $0 + Int($1) } == count, "pure black must burn all")

    // A flat midtone should land near half coverage. Atkinson discards some
    // error by design, so this is a band rather than an exact figure.
    let midCount = 128 * 128
    let mid = Bilevel.convert(luma: [UInt8](repeating: 128, count: midCount),
                              width: 128, height: 128,
                              dither: .atkinson, threshold: 128)
    let ratio = Double(mid.reduce(0) { $0 + Int($1) }) / Double(midCount)
    check(ratio > 0.30 && ratio < 0.70,
          "midtone coverage \(String(format: "%.2f", ratio)) outside 0.30..0.70")
    check(mid.allSatisfy { $0 <= 1 }, "output must be 0 or 1")

    let noisy = (0..<1024).map { UInt8(($0 * 37) % 256) }
    let a = Bilevel.convert(luma: noisy, width: 32, height: 32,
                            dither: .atkinson, threshold: 128)
    let b = Bilevel.convert(luma: noisy, width: 32, height: 32,
                            dither: .atkinson, threshold: 128)
    check(a == b, "dithering must be deterministic")

    check(Bilevel.convert(luma: [1, 2, 3], width: 2, height: 2,
                          dither: .none, threshold: 128).isEmpty,
          "mismatched dimensions must be rejected")
}

// MARK: - Filter integration

struct Pattern {
    var width: Int
    var height: Int
    var bitsPerPixel: Int
    var colorSpace: cups_cspace_t
    var sample: (Int, Int) -> UInt8
}

func writeRaster(_ pattern: Pattern, pages: Int) -> String? {
    let path = NSTemporaryDirectory() + "mvb_raster_\(UUID().uuidString)"
    guard FileManager.default.createFile(atPath: path, contents: nil) else {
        return nil
    }
    let fd = open(path, O_WRONLY)
    guard fd >= 0, let raster = cupsRasterOpen(fd, CUPS_RASTER_WRITE) else {
        return nil
    }

    var header = cups_page_header2_t()
    header.cupsWidth = UInt32(pattern.width)
    header.cupsHeight = UInt32(pattern.height)
    header.cupsBitsPerColor = pattern.bitsPerPixel == 1 ? 1 : 8
    header.cupsBitsPerPixel = UInt32(pattern.bitsPerPixel)
    header.cupsBytesPerLine = UInt32((pattern.width * pattern.bitsPerPixel + 7) / 8)
    header.cupsColorSpace = pattern.colorSpace
    header.cupsNumColors = pattern.bitsPerPixel == 24 ? 3 : 1
    header.HWResolution = (200, 200)

    let lineBytes = Int(header.cupsBytesPerLine)
    for _ in 0..<pages {
        cupsRasterWriteHeader2(raster, &header)
        for y in 0..<pattern.height {
            var row = [UInt8](repeating: 0, count: lineBytes)
            for x in 0..<pattern.width {
                let value = pattern.sample(x, y)
                switch pattern.bitsPerPixel {
                case 8:
                    row[x] = value
                case 1:
                    if value == 0 { row[x / 8] |= 1 << UInt8(7 - x % 8) }
                case 24:
                    row[x * 3] = value
                    row[x * 3 + 1] = value
                    row[x * 3 + 2] = value
                default:
                    break
                }
            }
            _ = row.withUnsafeMutableBufferPointer { buffer in
                cupsRasterWritePixels(raster, buffer.baseAddress, UInt32(lineBytes))
            }
        }
    }

    cupsRasterClose(raster)
    close(fd)
    return path
}

struct StreamStats {
    var valid = true
    var packets = 0
    var counts = [Int](repeating: 0, count: 256)
    var badCRC = 0
    var badTerminator = 0
    var firstRowPixels = -1
}

func decode(_ data: [UInt8]) -> StreamStats {
    var stats = StreamStats()
    var at = 0
    while at < data.count {
        guard at + 6 <= data.count, data[at] == 0x51, data[at + 1] == 0x78 else {
            stats.valid = false
            break
        }
        let command = Int(data[at + 2])
        let payloadLength = Int(data[at + 4]) | (Int(data[at + 5]) << 8)
        let total = 6 + payloadLength + 2
        guard at + total <= data.count else {
            stats.valid = false
            break
        }
        let payload = Array(data[(at + 6)..<(at + 6 + payloadLength)])
        if Wire.crc8(payload) != data[at + 6 + payloadLength] { stats.badCRC += 1 }
        if data[at + total - 1] != 0xFF { stats.badTerminator += 1 }
        stats.counts[command] += 1
        stats.packets += 1
        if command == 0xBF && stats.firstRowPixels < 0 {
            stats.firstRowPixels = payload.reduce(0) { $0 + Int($1 & 0x7F) }
        }
        at += total
    }
    return stats
}

func runFilter(path: String, options: FilterOptions) -> ([UInt8], Int)? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var collected = [UInt8]()
    do {
        let pages = try Filter.process(inputFD: fd, options: options) { bytes in
            collected.append(contentsOf: bytes)
        }
        return (collected, pages)
    } catch {
        return nil
    }
}

func testFilterGeometry() {
    group("filter geometry")
    let pattern = Pattern(width: 1600, height: 50, bitsPerPixel: 8,
                          colorSpace: CUPS_CSPACE_W) { _, _ in 255 }
    guard let path = writeRaster(pattern, pages: 1) else {
        check(false, "could not write raster")
        return
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    guard let (data, pages) = runFilter(path: path, options: FilterOptions()) else {
        check(false, "filter failed")
        return
    }
    let stats = decode(data)
    check(stats.valid, "stream framing is not decodable")
    check(stats.badCRC == 0, "\(stats.badCRC) packets with a bad CRC")
    check(stats.badTerminator == 0, "\(stats.badTerminator) missing 0xff")
    check(pages == 1, "converted \(pages) pages, want 1")
    check(stats.counts[0xA4] == 1, "blackening packets = \(stats.counts[0xA4])")
    check(stats.counts[0xAF] == 1, "energy packets = \(stats.counts[0xAF])")
    check(stats.counts[0xBE] == 1, "print mode packets = \(stats.counts[0xBE])")
    check(stats.counts[0xA3] == 1, "device state packets = \(stats.counts[0xA3])")
    check(stats.counts[0xBF] + stats.counts[0xA2] == 50,
          "row packets = \(stats.counts[0xBF] + stats.counts[0xA2]), want 50")
    check(stats.firstRowPixels == renderWidthDefault,
          "first row covers \(stats.firstRowPixels) px, want \(renderWidthDefault)")
}

func testFilterMultiPage() {
    group("filter multi-page")
    let pattern = Pattern(width: 1600, height: 10, bitsPerPixel: 8,
                          colorSpace: CUPS_CSPACE_W) { _, _ in 255 }
    guard let path = writeRaster(pattern, pages: 3),
          let (data, pages) = runFilter(path: path, options: FilterOptions()) else {
        check(false, "filter failed on multi-page input")
        return
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    let stats = decode(data)
    check(pages == 3, "converted \(pages) pages, want 3")
    check(stats.counts[0xA3] == 3,
          "one device-state per page, got \(stats.counts[0xA3])")
    check(stats.counts[0xBF] + stats.counts[0xA2] == 30,
          "row packets = \(stats.counts[0xBF] + stats.counts[0xA2]), want 30")
}

func testFilterColorSpace() {
    group("filter colorspace")
    // W: 0 is black. K: 255 is black. An all-black page in one space must not
    // come out all-white in the other.
    let cases: [(String, Pattern)] = [
        ("W", Pattern(width: 64, height: 4, bitsPerPixel: 8,
                      colorSpace: CUPS_CSPACE_W) { _, _ in 0 }),
        ("K", Pattern(width: 64, height: 4, bitsPerPixel: 8,
                      colorSpace: CUPS_CSPACE_K) { _, _ in 255 }),
        ("1bpp K", Pattern(width: 64, height: 4, bitsPerPixel: 1,
                           colorSpace: CUPS_CSPACE_K) { _, _ in 0 }),
        ("24bpp", Pattern(width: 64, height: 4, bitsPerPixel: 24,
                          colorSpace: CUPS_CSPACE_RGB) { _, _ in 0 }),
    ]

    var options = FilterOptions()
    options.renderWidth = 64

    for (label, pattern) in cases {
        guard let path = writeRaster(pattern, pages: 1),
              let (data, _) = runFilter(path: path, options: options) else {
            check(false, "\(label): filter failed")
            continue
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let stats = decode(data)
        check(stats.valid, "\(label): stream invalid")
        check(stats.counts[0xBF] == 4,
              "\(label): row packets = \(stats.counts[0xBF]), want 4")
        check(stats.firstRowPixels == 64,
              "\(label): first row covers \(stats.firstRowPixels) px, want 64")
    }
}

func testFilterScaling() {
    group("filter scaling")
    // A4 at 200dpi is 1654px if the imageable area is the whole sheet.
    let pattern = Pattern(width: 1654, height: 8, bitsPerPixel: 8,
                          colorSpace: CUPS_CSPACE_W) { x, _ in x < 4 ? 0 : 255 }
    guard let path = writeRaster(pattern, pages: 1),
          let (data, _) = runFilter(path: path, options: FilterOptions()) else {
        check(false, "filter failed on 1654px input")
        return
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    let stats = decode(data)
    check(stats.valid, "scaled stream invalid")
    check(stats.firstRowPixels == renderWidthDefault,
          "scaled row covers \(stats.firstRowPixels) px, want \(renderWidthDefault)")
}

func testFilterEmpty() {
    group("filter empty")
    let path = NSTemporaryDirectory() + "mvb_empty_\(UUID().uuidString)"
    FileManager.default.createFile(atPath: path, contents: Data())
    defer { try? FileManager.default.removeItem(atPath: path) }

    guard let (data, pages) = runFilter(path: path, options: FilterOptions()) else {
        check(false, "empty raster should not fail")
        return
    }
    check(pages == 0, "empty raster produced \(pages) pages")
    check(data.isEmpty, "empty raster produced \(data.count) bytes")
}

func testFilterRejectsBadHeader() {
    group("filter header validation")
    // A header claiming more pixels than the row buffer holds must be
    // rejected, not read past the end of the buffer.
    let path = NSTemporaryDirectory() + "mvb_bad_\(UUID().uuidString)"
    guard FileManager.default.createFile(atPath: path, contents: nil) else {
        check(false, "could not create file")
        return
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    let fd = open(path, O_WRONLY)
    guard fd >= 0, let raster = cupsRasterOpen(fd, CUPS_RASTER_WRITE) else {
        check(false, "could not open raster for writing")
        return
    }
    var header = cups_page_header2_t()
    header.cupsWidth = 10000            // far more than the line can hold
    header.cupsHeight = 2
    header.cupsBitsPerColor = 8
    header.cupsBitsPerPixel = 8
    header.cupsBytesPerLine = 16
    header.cupsColorSpace = CUPS_CSPACE_W
    header.cupsNumColors = 1
    header.HWResolution = (200, 200)
    cupsRasterWriteHeader2(raster, &header)
    var row = [UInt8](repeating: 200, count: 16)
    for _ in 0..<2 {
        _ = row.withUnsafeMutableBufferPointer { buffer in
            cupsRasterWritePixels(raster, buffer.baseAddress, 16)
        }
    }
    cupsRasterClose(raster)
    close(fd)

    let readFD = open(path, O_RDONLY)
    defer { close(readFD) }
    var threw = false
    do {
        _ = try Filter.process(inputFD: readFD, options: FilterOptions()) { _ in }
    } catch {
        threw = true
    }
    check(threw, "an inconsistent raster header must be rejected")
}

func testFilterOptions() {
    group("filter options")
    var options = FilterOptions()
    options.apply(optionString: "Darkness=5 MvbDither=None")
    check(options.darkness == 5, "darkness = \(options.darkness), want 5")
    check(options.dither == .none, "dither should be none")

    options = FilterOptions()
    options.apply(optionString: "Darkness=99")
    check(options.darkness == 3, "out-of-range darkness must keep the default")

    options = FilterOptions()
    options.apply(optionString: "ExtraDarkness=1")
    check(options.darkness == 3, "a substring key must not match")

    options = FilterOptions()
    options.apply(optionString: nil)
    check(options.darkness == 3, "nil options must be safe")

    options = FilterOptions()
    options.apply(optionString: "MvbThreshold=200 Darkness=2")
    check(options.threshold == 200, "threshold = \(options.threshold)")
    check(options.darkness == 2, "darkness = \(options.darkness)")
}

// MARK: - Entry point

let fixturePath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "tests/fixtures/line_eight.txt"

testCRC8()
testFraming()
testRLE()
testPackLine()
testTailFeed()
testBuildJobGuards()
testGolden(path: fixturePath)
testScaling()
testBilevel()
testFilterGeometry()
testFilterMultiPage()
testFilterColorSpace()
testFilterScaling()
testFilterEmpty()
testFilterRejectsBadHeader()
testFilterOptions()

print("\n\(checksRun) checks, \(checksFailed) failed")
exit(checksFailed == 0 ? 0 : 1)
