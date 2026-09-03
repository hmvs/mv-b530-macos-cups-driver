/// Test runner for the MV-B530 driver.
///
/// Built as an executable rather than an XCTest bundle so it runs with the
/// Command Line Tools alone — XCTest needs xcode-select pointed at a full
/// Xcode, which is a lot to ask of someone who just wants their printer to
/// work.
import Foundation
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
    // Downscaling keeps the darkest of each pair, so no stroke is dropped.
    check(Bilevel.scaleRow(eight[...], to: 4) == [0, 2, 4, 6],
          "downscale = \(Bilevel.scaleRow(eight[...], to: 4))")

    // The case that matters: a one-pixel black stroke must survive a scale
    // that has fewer destination pixels than source ones.
    var stroke = [UInt8](repeating: 255, count: 1654)
    stroke[800] = 0
    check(Bilevel.scaleRow(stroke[...], to: 1600).contains(0),
          "a single dark column must not be scaled away")

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
    check(Bilevel.scaleRow(slice, to: 2) == [4, 6],
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

/// x9 profile render width, mirrored here so the tests do not depend on the
/// printer app target.
let renderWidthUnderTest = 1600

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

// MARK: - Row conversion

func testLumaRow() {
    group("lumaRow")

    // 8-bit: W has 0 as black, K has 255 as black. Getting this backwards
    // prints a solid black page and wastes the sheet.
    let grey: [UInt8] = [0, 64, 128, 255]
    check(Bilevel.lumaRow(grey[...], width: 4, bitsPerPixel: 8,
                          polarity: .whiteIsHigh) == [0, 64, 128, 255],
          "8-bit W must pass through")
    check(Bilevel.lumaRow(grey[...], width: 4, bitsPerPixel: 8,
                          polarity: .blackIsHigh) == [255, 191, 127, 0],
          "8-bit K must invert")

    // 1-bit: in K a set bit is ink, in W a set bit is white.
    let bits: [UInt8] = [0b10000000]
    check(Bilevel.lumaRow(bits[...], width: 2, bitsPerPixel: 1,
                          polarity: .blackIsHigh) == [0, 255],
          "1-bit K: set bit is ink")
    check(Bilevel.lumaRow(bits[...], width: 2, bitsPerPixel: 1,
                          polarity: .whiteIsHigh) == [255, 0],
          "1-bit W: set bit is white")

    // 24-bit uses Rec. 601 luma.
    let rgb: [UInt8] = [255, 255, 255, 0, 0, 0]
    let luma24 = Bilevel.lumaRow(rgb[...], width: 2, bitsPerPixel: 24,
                                 polarity: .whiteIsHigh)
    check(luma24[0] > 240 && luma24[1] == 0, "24-bit luma = \(luma24)")

    // A row shorter than the geometry claims must come back white rather than
    // reading past the end - that was a real heap overread in an earlier draft.
    let truncated: [UInt8] = [10, 20]
    check(Bilevel.lumaRow(truncated[...], width: 1000, bitsPerPixel: 8,
                          polarity: .whiteIsHigh).allSatisfy { $0 == 255 },
          "a short row must not be read past its end")
    check(Bilevel.lumaRow(truncated[...], width: 1000, bitsPerPixel: 1,
                          polarity: .blackIsHigh).allSatisfy { $0 == 255 },
          "a short 1-bit row must not be read past its end")
    check(Bilevel.lumaRow(truncated[...], width: 1000, bitsPerPixel: 24,
                          polarity: .whiteIsHigh).allSatisfy { $0 == 255 },
          "a short 24-bit row must not be read past its end")

    // Unknown depths are white, not black.
    check(Bilevel.lumaRow(grey[...], width: 4, bitsPerPixel: 16,
                          polarity: .whiteIsHigh) == [255, 255, 255, 255],
          "an unsupported depth must come back white")

    check(Bilevel.lumaRow(grey[...], width: 0, bitsPerPixel: 8,
                          polarity: .whiteIsHigh).isEmpty,
          "zero width yields nothing")

    // Slices that do not start at zero must be honoured.
    let padded: [UInt8] = [9, 9, 1, 2, 3, 4]
    check(Bilevel.lumaRow(padded[2...], width: 4, bitsPerPixel: 8,
                          polarity: .whiteIsHigh) == [1, 2, 3, 4],
          "a non-zero-based slice must be read from its own start")
}

/// The whole page path, end to end, without CUPS or hardware: luma rows in,
/// a framed command stream out.
func testPagePipeline() {
    group("page pipeline")

    let sourceWidth = 1654          // A4 at 200dpi across the full sheet
    let height = 8
    var page = [UInt8]()
    for _ in 0..<height {
        var row = [UInt8](repeating: 255, count: sourceWidth)
        row[0] = 0
        row[sourceWidth - 1] = 0
        page += Bilevel.scaleRow(row[...], to: renderWidthUnderTest)
    }

    let bits = Bilevel.convert(luma: page, width: renderWidthUnderTest,
                               height: height, dither: .none, threshold: 128)
    check(bits.count == renderWidthUnderTest * height, "bilevel size")

    var options = JobOptions()
    options.paperMode = .a4Sheet
    options.a4SheetMaxHeight = 2460
    guard let stream = Wire.buildJob(pixels: bits, width: renderWidthUnderTest,
                                     height: height, options: options) else {
        check(false, "buildJob returned nil")
        return
    }

    let stats = decode(stream)
    check(stats.valid, "stream framing is not decodable")
    check(stats.badCRC == 0, "\(stats.badCRC) packets with a bad CRC")
    check(stats.badTerminator == 0, "\(stats.badTerminator) missing 0xff")
    check(stats.counts[0xA4] == 1, "one blackening packet")
    check(stats.counts[0xBE] == 1, "one print-mode packet")
    check(stats.counts[0xA3] == 1, "one device-state packet")
    check(stats.counts[0xBF] + stats.counts[0xA2] == height,
          "row packets = \(stats.counts[0xBF] + stats.counts[0xA2]), want \(height)")
    // Rows go out padded to the head's full width, not the render width.
    check(stats.firstRowPixels == renderWidthUnderTest + options.leftPadding,
          "first row covers \(stats.firstRowPixels) px, want "
          + "\(renderWidthUnderTest + options.leftPadding)")
}

// MARK: - Notifications from the printer

/// Frames a packet the way the printer does, flags = 1.
func printerPacket(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
    [0x51, 0x78, opcode, 1,
     UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF)]
        + payload + [Wire.crc8(payload), 0xFF]
}

func testPacketDecoder() {
    group("packet decoder")

    var decoder = PacketDecoder()
    let pause = printerPacket(opcode: 0xAE, payload: [0x10])
    let resume = printerPacket(opcode: 0xAE, payload: [0x00])

    let one = decoder.feed(pause)
    check(one.count == 1, "one packet from one frame, got \(one.count)")
    check(one.first.map(FlowControl.state) == true, "0x10 means pause")

    // BLE coalesces notifications, so several can arrive in one callback.
    let both = decoder.feed(resume + pause)
    check(both.count == 2, "two coalesced packets, got \(both.count)")
    check(both.first.map(FlowControl.state) == false, "0x00 means resume")
    check(both.last.map(FlowControl.state) == true, "second is the pause")

    // And it fragments them just as readily: nothing until the last byte.
    var fragmented = PacketDecoder()
    check(fragmented.feed(pause.dropLast(3)).isEmpty, "no packet from a fragment")
    check(fragmented.feed(pause.suffix(3)).count == 1, "packet completed by the rest")

    // A byte-at-a-time delivery must still yield exactly one packet.
    var drip = PacketDecoder()
    var dripped = 0
    for byte in pause { dripped += drip.feed([byte]).count }
    check(dripped == 1, "one packet delivered a byte at a time, got \(dripped)")

    // Rubbish before a packet is skipped rather than swallowing it.
    var noisy = PacketDecoder()
    let withNoise = noisy.feed([0x00, 0x51, 0x99, 0xFF] + pause)
    check(withNoise.count == 1, "packet found after noise, got \(withNoise.count)")

    // A corrupt CRC must not be accepted as flow control.
    var corrupt = PacketDecoder()
    var bad = pause
    bad[bad.count - 2] ^= 0xFF
    check(corrupt.feed(bad).isEmpty, "packet with a bad CRC is rejected")

    // Only the printer's own opcode and direction mean anything.
    var others = PacketDecoder()
    let other = others.feed(printerPacket(opcode: 0xA3, payload: [0x10]))
    check(other.count == 1, "the 0xA3 packet still decodes")
    check(other.first.flatMap(FlowControl.state) == nil, "0xA3 is not flow control")
    let outbound = DecodedPacket(opcode: 0xAE, flags: 0, payload: [0x10])
    check(FlowControl.state(of: outbound) == nil, "our own packets are not flow control")
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
testLumaRow()
testPagePipeline()
testPacketDecoder()

print("\n\(checksRun) checks, \(checksFailed) failed")
exit(checksFailed == 0 ? 0 : 1)
