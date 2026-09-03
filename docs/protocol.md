# The MV-B530 protocol

Reverse-engineered with reference to
[TiMini-Print](https://github.com/Dejniel/TiMini-Print), and pinned in the test
suite against 13 golden vectors produced by it, so the encoder is checked
against a known-good encoder rather than against itself.

## Packets

Packets are framed as:

```
51 78 | cmd 00 len_lo len_hi | payload | crc8(payload) ff
```

with CRC-8 (polynomial `0x07`, init `0x00`, no reflection). A page is
blackening (`A4`), energy (`AF`), print mode (`BE`), feed (`BD`), one packet per
pixel row — run-length encoded as `BF`, falling back to raw `A2` when RLE would
be larger — a feed every 200 rows, a tail feed (`A1`), then a device-state query
(`A3`).

## Geometry

Profile `x9`, 200 dpi, render width 1600 dots, paper width 1632,
left padding 32, maximum page height 2460 dots. Rows go out padded to the full
1632: a page sent at 1600 prints 4 mm left of where it belongs.

## Flow control

The printer sends unprompted notifications
while a job streams — `51 78 AE 01 01 00 10 70 ff` when its line buffer is
full, and the same packet with `00` when there is room again. These arrive on
a notify characteristic, framed exactly like the commands sent to it but with
the flags byte set to 1. The radio being ready to send is not the same thing:
ignoring these overruns the printer, which silently drops the lines it cannot
hold. Chunks are 512 bytes, 4 ms apart, and the link is held open for three
seconds after the last byte so the page is not cut off part-printed.

## Classic Bluetooth is a dead end

The device advertises RFCOMM and refuses
the connection (`status -536870212`); it publishes no SDP print service. BLE
GATT over the ISSC transparent UART service
`49535343-FE7D-4AE5-8FA9-9FAFD205E455` is the only path that works.
