#!/usr/bin/env python3
"""Generate golden protocol vectors from the reference implementation.

BUILD-TIME ONLY. Nothing in native/ depends on Python at build or run time;
this exists purely so the C unit tests can assert against byte streams
produced by TiMini-Print rather than against our own reimplementation.

Regenerate (only needed if the protocol understanding changes):

    python3 native/tools/gen_fixtures.py > native/tests/fixtures/line_eight.json

The committed JSON is the artefact the tests consume.
"""


import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.normpath(os.path.join(HERE, "..", "..", "vendor", "TiMini-Print"))
sys.path.insert(0, VENDOR)

from timiniprint.protocol.families.tiny.core import _build_line_eight_job  # noqa: E402
from timiniprint.protocol.families.base import PrintJobRequest  # noqa: E402
from timiniprint.protocol.family import ProtocolFamily  # noqa: E402
from timiniprint.protocol.types import (  # noqa: E402
    ImageEncoding,
    ImagePipelineConfig,
    PaperMode,
)
from timiniprint.raster import PixelFormat, RasterBuffer, RasterSet  # noqa: E402

# Values taken from the x9 profile, which is what MV-B530 resolves to.
X9 = dict(
    speed=40,
    energy=15000,
    blackening=3,
    dev_dpi=200,
    post_print_feed_count=2,
    protocol_variant="line_eight",
)


def build(pixels, width, *, paper_mode, a4_max=None, left_pad=0,
          is_text=False, encoding=ImageEncoding.TINY_RLE, lsb_first=True,
          speed=None, energy=None, blackening=None):
    raster = RasterBuffer(pixels=list(pixels), width=width,
                          pixel_format=PixelFormat.BW1)
    request = PrintJobRequest(
        raster_set=RasterSet(rasters={PixelFormat.BW1: raster}),
        image_pipeline=ImagePipelineConfig(
            formats=(PixelFormat.BW1,), encoding=encoding),
        is_text=is_text,
        speed=X9["speed"] if speed is None else speed,
        energy=X9["energy"] if energy is None else energy,
        blackening=X9["blackening"] if blackening is None else blackening,
        lsb_first=lsb_first,
        protocol_family=ProtocolFamily.from_value("tiny"),
        protocol_variant=X9["protocol_variant"],
        feed_padding=0,
        dev_dpi=X9["dev_dpi"],
        post_print_feed_count=X9["post_print_feed_count"],
        left_padding_pixels=left_pad,
        a4xii=False,
        a4_sheet_max_height=a4_max,
        paper_mode=paper_mode,
    )
    return _build_line_eight_job(request).hex()


def packed(pixels, width):
    """Pack 0/1 pixels MSB-first so the C test can rebuild the raster."""
    out = bytearray()
    for row in range(len(pixels) // width):
        line = pixels[row * width:(row + 1) * width]
        for i in range(0, width, 8):
            chunk = list(line[i:i + 8]) + [0] * max(0, 8 - len(line[i:i + 8]))
            value = 0
            for bit, pix in enumerate(chunk):
                if pix:
                    value |= 1 << (7 - bit)
            out.append(value)
    return out.hex()


def case(name, pixels, width, **kw):
    """One fixture, in a line format a dependency-free C test can parse."""
    encoding = kw.get("encoding", ImageEncoding.TINY_RLE)
    return "\n".join([
        "case %s" % name,
        "width %d" % width,
        "height %d" % (len(pixels) // width),
        "paper %s" % kw.get("paper_mode").value,
        "a4max %d" % (kw.get("a4_max") or 0),
        "leftpad %d" % kw.get("left_pad", 0),
        "istext %d" % int(bool(kw.get("is_text", False))),
        "lsbfirst %d" % int(bool(kw.get("lsb_first", True))),
        "encoding %s" % ("raw" if encoding == ImageEncoding.TINY_RAW else "rle"),
        "speed %d" % (kw.get("speed") if kw.get("speed") is not None else X9["speed"]),
        "energy %d" % (kw.get("energy") if kw.get("energy") is not None else X9["energy"]),
        "blackening %d" % (kw.get("blackening") if kw.get("blackening") is not None
                           else X9["blackening"]),
        "pixels %s" % packed(pixels, width),
        "expected %s" % build(pixels, width, **kw),
        "end",
    ])


def main():
    cases = []

    # Smallest useful unit: one all-white and one all-black 8px line.
    cases.append(case("white_8x1", [0] * 8, 8, paper_mode=PaperMode.PLAIN))
    cases.append(case("black_8x1", [1] * 8, 8, paper_mode=PaperMode.PLAIN))

    # Alternating pixels: worst case for RLE, forces the raw A2 fallback.
    cases.append(case("alternating_16x1", [i % 2 for i in range(16)], 16,
                      paper_mode=PaperMode.PLAIN))

    # Runs longer than 127 must split into multiple RLE bytes.
    cases.append(case("long_run_400x1", [1] * 400, 400,
                      paper_mode=PaperMode.PLAIN))

    # Mixed content at a realistic width.
    mixed = []
    for row in range(5):
        for col in range(1600):
            mixed.append(1 if (col // 37 + row) % 3 == 0 else 0)
    cases.append(case("mixed_1600x5", mixed, 1600, paper_mode=PaperMode.PLAIN))

    # Periodic feed packets are emitted every 200 rows.
    tall = []
    for row in range(205):
        for col in range(64):
            tall.append(1 if (col + row) % 11 == 0 else 0)
    cases.append(case("periodic_feed_64x205", tall, 64,
                      paper_mode=PaperMode.PLAIN))

    # A4 sheet mode: tail feed is max_height - height.
    a4 = []
    for row in range(300):
        for col in range(1600):
            a4.append(1 if (row % 97 == 0 or col % 211 == 0) else 0)
    cases.append(case("a4_sheet_1600x300", a4, 1600,
                      paper_mode=PaperMode.A4_SHEET, a4_max=2460))

    # Left padding shifts every row right by N white pixels.
    cases.append(case("left_padded_32x3",
                      [1 if (i % 5 == 0) else 0 for i in range(32 * 3)], 32,
                      paper_mode=PaperMode.A4_SHEET, a4_max=2460, left_pad=32))

    # Text mode changes the print-mode byte and is typically run hotter.
    cases.append(case("text_mode_64x2", [i % 3 == 0 for i in range(128)], 64,
                      paper_mode=PaperMode.PLAIN, is_text=True,
                      speed=30, energy=33000))

    # Raw encoding path, and MSB bit order.
    cases.append(case("raw_encoding_32x2",
                      [1 if i % 7 == 0 else 0 for i in range(64)], 32,
                      paper_mode=PaperMode.PLAIN,
                      encoding=ImageEncoding.TINY_RAW))
    cases.append(case("raw_msb_32x2",
                      [1 if i % 7 == 0 else 0 for i in range(64)], 32,
                      paper_mode=PaperMode.PLAIN,
                      encoding=ImageEncoding.TINY_RAW, lsb_first=False))

    # Blackening is clamped to 1..5 by the reference implementation.
    cases.append(case("blackening_clamped_8x1", [1] * 8, 8,
                      paper_mode=PaperMode.PLAIN, blackening=9))

    # Zero energy omits the energy packet entirely.
    cases.append(case("zero_energy_8x1", [1] * 8, 8,
                      paper_mode=PaperMode.PLAIN, energy=0))

    sys.stdout.write("# Generated by native/tools/gen_fixtures.py from "
                     "TiMini-Print. Do not edit by hand.\n")
    for entry in cases:
        sys.stdout.write(entry + "\n")


if __name__ == "__main__":
    main()
