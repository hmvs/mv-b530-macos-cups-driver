# MV-B530 macOS CUPS driver — Kmart / Anko "Inkless A4 Printer"

A native CUPS print queue for the **Kmart Anko Inkless A4 Printer**, so you can
press ⌘P from any macOS app instead of being limited to the phone app.

Swift, no runtime dependencies beyond macOS itself. No Python, no bundled
interpreter, no third-party app.

## Which printer is this?

| | |
|---|---|
| **Retail name** | Anko **Inkless A4 Printer** — White |
| **Kmart Australia SKU** | **43618996** — on the box: `K: 43-618-996` |
| **Target Australia SKU** | **71642758** — `T: 71-642-758` |
| **Manufacturer model** | `ZB2025041106` |
| **Bluetooth name** | `MV-B530-XXXX` |
| **Vendor app** | Tiny Print (`com.frogtosea.tinyPrint`) |
| **Output** | A4 / A5 / US Letter thermal, 200 dpi, greyscale |
| **Price** | AU$89 |

[Kmart product page](https://www.kmart.com.au/product/inkless-a4-printer-white-43618996/) ·
[Target listing](https://www.target.com.au/p/anko-inkless-a4-printer-white/71642758) ·
[official manual (PDF)](https://www.kmart.com.au/wcsstore/Kmart/pdfs/43618996_Manual.pdf)

`MV-B530` is a rebadged generic Chinese board, so this should also work for its
documented clones — **GL-VS9, QDID, X9**.

## Why this exists

The manual says macOS is supported over USB:

> Currently supported systems include: Windows 11, Windows 10, Windows 8,
> macOS with Intel chips, and macOS with ARM chips.
> Connect the printer to the computer using a USB Type-C cable.

**That procedure does not work.** On the unit tested here the USB-C port is
power-only — it presents no USB data interface at all:

- `ioreg -p IOUSB` — the printer never enumerates, powered on or off
- zero `AppleUSBHost` enumeration events on connect
- tested with a cable proven to carry data (an iPhone enumerated over it
  seconds earlier), plugged straight into the Mac, bypassing all hubs

macOS cannot reach it over Bluetooth either. The stock CUPS `bluetooth` backend
finds the device and then gives up, because it only speaks HCRP:

```
[HCRP-CUPS] Found device MV-B530-38AC
[HCRP-CUPS] No SDP record for MV-B530-38AC.
```

So the only route is the printer's own BLE protocol. This project implements
that protocol and wires it into CUPS.

## How it works

```
⌘P → cupsd → cgpdftoraster → rastertomvb530 → mvb530 backend
                                                    ↓ 127.0.0.1:9101
                                              mvb530d (login session)
                                                    ↓ CoreBluetooth
                                                 printer
```

| Component | Role |
|---|---|
| `rastertomvb530` | CUPS filter. Greyscale raster → dither → protocol stream. |
| `mvb530` | CUPS backend. Forwards the stream to the agent, maps the reply to a CUPS exit code. |
| `mvb530d` | Print agent. Holds the Bluetooth grant, talks BLE to the printer. |
| `mvb530.ppd` | A4 at 200 dpi, greyscale, darkness 1–5, dither on/off. |

### Why there is a separate agent

A CUPS backend is spawned by `cupsd` as the `_lp` user. That context can never
hold a Bluetooth TCC grant and can never show a permission prompt, so it cannot
touch CoreBluetooth in any language. The radio work has to happen in the user's
login session, and the two halves talk over loopback.

macOS additionally **sandboxes CUPS backends away from arbitrary filesystem
paths** — a spool directory at `/usr/local/var/spool/...`, mode `0770` and group
`_lp`, is not even `stat`-able from a backend, with no denial logged. Loopback
HTTP is used instead, which the sandbox does permit: the stock `ipp`, `socket`
and `lpd` backends all depend on networking.

### Why the agent is not an .app

`mvb530d` carries its own `Info.plist` in a `__TEXT,__info_plist` section, so it
declares `NSBluetoothAlwaysUsageDescription` as a plain signed binary. It must
still be started **by launchd** rather than from a shell: a shell-spawned
process inherits the terminal's TCC identity and is killed on first
CoreBluetooth call, whereas under launchd it is its own responsible process.

## Findings

**The wire protocol.** Packets are framed as:

```
51 78 | cmd 00 len_lo len_hi | payload | crc8(payload) ff
```

with CRC-8 (polynomial `0x07`, init `0x00`, no reflection). A page is
blackening (`A4`), energy (`AF`), print mode (`BE`), feed (`BD`), one packet per
pixel row — run-length encoded as `BF`, falling back to raw `A2` when RLE would
be larger — a feed every 200 rows, a tail feed (`A1`), then a device-state query
(`A3`).

**Geometry.** Profile `x9`, 200 dpi, render width 1600 dots, paper width 1632,
left padding 32, maximum page height 2460 dots.

**Classic Bluetooth is a dead end.** The device advertises RFCOMM and refuses
the connection (`status -536870212`); it publishes no SDP print service. BLE
GATT over the ISSC transparent UART service
`49535343-FE7D-4AE5-8FA9-9FAFD205E455` is the only path that works.

## Install

Requires macOS 12+, Apple Silicon or Intel, and the Command Line Tools.
No Xcode needed.

```bash
git clone https://github.com/hmvs/mv-b530-macos-cups-driver.git
cd mv-b530-macos-cups-driver
make test           # build and run the test suite
sudo make install   # filter, backend, PPD and the queue
make agent-start    # start the agent in your login session
```

The first print will raise a Bluetooth permission prompt. Approve it.

To start the agent automatically at login, create
`~/Library/LaunchAgents/org.hmvs.mvb530d.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.hmvs.mvb530d</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/mvb530d</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
```

then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.hmvs.mvb530d.plist`.

## Usage

Power the printer on — hold the power key for 3 seconds, a flashing green LED
means it is on and not yet connected — then print to **Anko Inkless A4** from
any app. A page takes about six seconds to transfer.

### Printing while the printer is off

You can hit ⌘P first and switch the printer on afterwards. The job waits.

- The **agent** keeps scanning for up to `--wait` seconds (default **180**).
- If it still cannot find the printer it returns 503, and the **backend** exits
  `CUPS_BACKEND_RETRY`, so the queue stays enabled and the job stays queued.
- CUPS then retries on its own schedule: `JobRetryInterval` (default **30 s**)
  and `JobRetryLimit` (default **5**).

So the default tolerance is roughly `5 × (180 + 30)` ≈ **17 minutes** before
CUPS gives up on the job. To wait longer, raise the agent's window — that lever
belongs to this driver, unlike the CUPS globals:

```bash
mvb530d --wait 900     # ~77 minutes of tolerance
```

### Does macOS show it as offline?

Yes, once a job has tried. The backend emits `STATE: +offline-report` when the
printer cannot be reached and `STATE: -offline-report` when a page goes
through, which is what Printers & Scanners and the print dialog turn into
"Printer is offline".

The important caveat: CUPS only learns this **when a job runs**. There is no
background polling, so switching the printer on does not immediately flip the
UI to online — the status updates on the next job or retry. A queue that has
never printed shows simply as idle.

If you want a live answer at any moment, ask the agent instead:

```bash
curl localhost:9101/scan
```

### Diagnostics

```bash
curl localhost:9101/health              # agent and Bluetooth state
curl localhost:9101/scan                # nearby supported printers
curl -X POST localhost:9101/testpage    # print a test pattern, no CUPS involved
make agent-status
```

## Tests

```bash
make test
```

95 checks, no hardware required. The protocol tests assert **byte-for-byte**
against 13 golden vectors produced by the reference implementation
([TiMini-Print](https://github.com/Dejniel/TiMini-Print)), so the encoder is
checked against a known-good encoder rather than against itself. Coverage
includes CRC-8, packet framing, RLE (including runs over 127 and the raw
fallback), bit order, tail-feed arithmetic, nearest-neighbour scaling, Atkinson
dithering, and the filter end to end against synthetic CUPS rasters in four
colour spaces — plus a malformed-header case that must be rejected rather than
read past the end of the row buffer.

Regenerating the golden vectors is the only thing that needs Python, and only
for maintainers:

```bash
make fixtures
```

## Limitations

- Greyscale only, 200 dpi. It is a thermal printer.
- One job at a time; the agent serialises on the Bluetooth link.
- The printer must be on before the job reaches it, and cannot print while
  charging.
- Tested on macOS 26.6, Apple Silicon.

## Credits

The protocol was reverse-engineered with reference to
[TiMini-Print](https://github.com/Dejniel/TiMini-Print) by Daniel Banecki
(Apache 2.0), which is vendored as a submodule and used only to generate the
golden test vectors. It is not required to build or run this driver.

## Licence

MIT.
