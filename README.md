# MV-B530 macOS CUPS driver — Kmart / Anko "Inkless A4 Printer"

A real CUPS print queue for the **Kmart Anko Inkless A4 Printer**, so you can
press ⌘P from any macOS app instead of being stuck with the phone app.

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

The printer ships with a manual that says macOS is supported over USB:

> Currently supported systems include: Windows 11, Windows 10, Windows 8,
> macOS with Intel chips, and macOS with ARM chips.
> Connect the printer to the computer using a USB Type-C cable.
> Select BYP800 to start printing.

**That procedure does not work.** On the unit tested here the USB-C port is
power-only — it presents no USB data interface at all. Verified with:

- `ioreg -p IOUSB` — printer never enumerates, powered on or off
- zero `AppleUSBHost` enumeration events on connect
- a cable proven to carry data (an iPhone enumerated over it seconds earlier)
- connected directly to the Mac, bypassing all hubs

macOS can't reach it over Bluetooth either. The CUPS `bluetooth` backend finds
the device and then gives up, because it only speaks HCRP:

```
[HCRP-CUPS] Found device MV-B530-38AC
[HCRP-CUPS] No SDP record for MV-B530-38AC.
```

So the only route is the printer's proprietary BLE protocol. This project wires
that protocol into CUPS.

## How it works

[TiMini-Print](https://github.com/Dejniel/TiMini-Print) already implements the
protocol. The hard part on macOS is **TCC**: a CUPS backend runs as `_lp` under
`cupsd`, and a daemon in that context can never hold a Bluetooth grant or show a
permission prompt. So the driver is split in two.

```
⌘P → CUPS queue → timini backend (as _lp, no Bluetooth)
                    ↓  HTTP POST to 127.0.0.1:9101
     print agent inside TiMiniRunner.app (user session, has Bluetooth)
                    ↓  timiniprint → BLE GATT → printer
```

The handoff is loopback HTTP rather than a shared directory because **macOS
sandboxes CUPS backends away from arbitrary filesystem paths**. A spool under
`/usr/local/var/spool/timini`, mode `0770` and group `_lp`, is not even
`stat`-able from the backend — it reports the directory as missing despite
correct ownership and no sandbox denial appearing in the log. Networking is
permitted, since the stock `ipp`, `socket` and `lpd` backends depend on it.

| File | Role |
|---|---|
| `timini-backend.sh` | CUPS backend. POSTs the PDF to the agent, maps the reply to a CUPS exit status. |
| `agent.py` | Loopback HTTP server; prints via `timiniprint`, serialised on the Bluetooth link. |
| `timini.ppd` | A4 at 200 dpi, greyscale, PDF passthrough, darkness 1–5. |
| `install-driver.sh` | Installs the backend and the queue (needs `sudo`). |

## Findings worth knowing

**The catalogue's transport is wrong for this unit.** TiMini's profile for
`mv_b530` sets `use_spp: true`, but classic RFCOMM fails:

```
RFCOMM channel 1 failed (status: -536870212)
```

Its automatic fallback then connects over BLE GATT — the ISSC transparent UART
service `49535343-fe7d-4ae5-8fa9-9fafd205e455` — and prints fine.

**TiMini's own macOS build is TCC-broken.** `TiMini-Print-GUI-macOS-arm64.app`
ships with **no Bluetooth keys** in its `Info.plist`, so macOS SIGABRTs it the
moment it touches Bluetooth:

```
namespace: TCC
"This app has crashed because it attempted to access privacy-sensitive data
 without a usage description. The app's Info.plist must contain an
 NSBluetoothAlwaysUsageDescription key..."
```

This project works around that by running the interpreter inside a minimal
ad-hoc-signed bundle (`TiMiniRunner.app`) that declares
`NSBluetoothAlwaysUsageDescription`. The bundle must live outside `/tmp` and be
launched via LaunchServices (`open`), or TCC still refuses it.

**Verified geometry:** profile `x9`, 200 dpi, paper preset
`a4sheet_1600r_1632p_32pl_2460mh` — render width 1600 px, paper width 1632 px,
max height 2460 px. A 1600×2300 page prints full-bleed correctly.

## Install

### 1. Dependencies and the runner bundle

```bash
./setup.sh
```

This clones TiMini-Print, builds a virtualenv, and creates `TiMiniRunner.app`
under `~/Library/Application Support/TiMiniPrint/`.

### 2. CUPS side

```bash
sudo ./install-driver.sh
```

Installs the `timini` backend and adds a queue named `Anko_Inkless_A4`.

### 3. Grant Bluetooth once

```bash
./start-agent.sh
```

Approve the Bluetooth prompt. The agent stays running and prints anything that
lands in the spool.

### 4. Optional — start the agent at login

The agent has to run for jobs to reach the printer. To start it automatically,
create `~/Library/LaunchAgents/local.timini.agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.timini.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOU/Library/Application Support/TiMiniPrint/TiMiniRunner.app/Contents/MacOS/Python</string>
        <string>/Users/YOU/Library/Application Support/TiMiniPrint/agent.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONHOME</key>
        <string>/opt/homebrew/Cellar/python@3.14/3.14.4/Frameworks/Python.framework/Versions/3.14</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
```

Then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.timini.agent.plist`.

Note: launchd starts the executable directly rather than through
LaunchServices, so grant the Bluetooth permission interactively (step 3) first.

## Usage

Power the printer on (hold the power key 3 s; green LED flashes = on, not yet
connected), then print to **Anko Inkless A4** from any app. A page takes about
six seconds to transfer.

## Limitations

- Greyscale only, 200 dpi — it's a thermal printer.
- One job at a time; the agent serialises on the Bluetooth link.
- Printer must be on before you print. There's no wake-on-print.
- Battery: the printer cannot operate while charging.
- Only tested on macOS 26.6 / Apple Silicon / Homebrew Python 3.14.

## Credits

The protocol implementation is all [TiMini-Print](https://github.com/Dejniel/TiMini-Print)
by Dejniel. This repo only adds the CUPS and macOS-TCC plumbing around it.

## Licence

MIT for the code here. TiMini-Print has its own licence — see that project.
