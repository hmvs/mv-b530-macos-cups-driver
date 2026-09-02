# MV-B530 macOS CUPS driver — Kmart / Anko "Inkless A4 Printer"

An **IPP Everywhere / AirPrint** printer application for the **Kmart Anko
Inkless A4 Printer**, so you can press ⌘P from any macOS app — or from a phone
on the same Wi-Fi — instead of being limited to the vendor's phone app.

Swift. Installs without root, and without a PPD or a CUPS filter, so nothing
here depends on the parts CUPS 3.x removes.

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
[HCRP-CUPS] Found device MV-B530-XXXX
[HCRP-CUPS] No SDP record for MV-B530-XXXX.
```

So the only route is the printer's own BLE protocol. This project implements
that protocol and exposes it as a standards-compliant IPP printer.

## How it works

```
⌘P → cupsd → PWG raster over IPP → mvb530-printer-app   (PAPPL, port 8631)
                                        ↓ bluetooth:// device scheme
                                   mvb530d              (CoreBluetooth)
                                        ↓ BLE GATT
                                     printer
```

| Component | Role |
|---|---|
| `mvb530-printer-app` | PAPPL IPP service. Raster callbacks → dither → protocol stream, and a `bluetooth://` device scheme. |
| `mvb530d` | Transport agent. Owns the Bluetooth link. |

Both run as user LaunchAgents. Nothing is installed as root, and no PPD is
authored here — `lpadmin -m everywhere` builds the queue from the IPP
attributes the printer application advertises.

### Discovery

```
_ipp._tcp,_universal     IPP Everywhere
_ipps._tcp,_universal    AirPrint
URF=V1.5,W8,PQ3-4-5,FN3,IS0-1,MT1-5,OB10,RS200
pdl=image/pwg-raster,image/urf
```

Because the service binds all interfaces, a phone or tablet on the same
network can print to it, with the Mac relaying over Bluetooth — a
Bluetooth-only printer becomes a shared network printer. The flip side is that
anyone on your LAN can print to it and reach PAPPL's web interface. If that
matters, bind it to loopback with `-o server-hostname=localhost`.

### Why there are two processes

The intent was one. It cannot be done on macOS.

PAPPL must own the main thread: it creates an `NSStatusItem`, and AppKit throws
*"NSWindow should only be instantiated on the main thread"* otherwise. It never
pumps a CFRunLoop there. A `CBCentralManager` created in that process stays in
`.unknown` and delivers no state callback — on the main thread or a worker,
with or without an explicit dispatch queue, eagerly pre-warmed or lazy, under
any code-signing identity. All of those were tried.

So the radio lives in `mvb530d`, whose main thread does run a run loop, and the
device scheme hands each job to it over loopback. That is still a large
simplification: the previous design had a CUPS filter and backend installed as
root under `/usr/libexec/cups`, plus a PPD.

### Why neither binary is an .app

Each embeds its own `Info.plist` in a `__TEXT,__info_plist` section, so it
declares `NSBluetoothAlwaysUsageDescription` as a plain signed binary. They
must be started **by launchd**: a shell-spawned process inherits the terminal's
TCC identity and is killed on the first CoreBluetooth call, whereas under
launchd each is its own responsible process. The two also need *different*
ad-hoc signing identities — two binaries claiming one identity confuses the
Bluetooth grant for both.

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

Needs macOS 13+, the Command Line Tools, and OpenSSL (`brew install openssl@3`)
— PAPPL requires TLS. No Xcode.

```bash
git clone --recursive https://github.com/hmvs/mv-b530-macos-cups-driver.git
cd mv-b530-macos-cups-driver
make test      # builds PAPPL, then runs the test suite
make install   # no sudo
```

`make install` puts two binaries in `~/.local/libexec`, registers both as user
LaunchAgents so they start at login, and creates the driverless queue. To pin a
particular printer rather than the first one found:

```bash
MVB530_PRINTER=MV-B530-38AC make install
```

The first print raises a Bluetooth permission prompt. Approve it once.

```bash
make status     # are both services up?
make restart    # after installing a new build
make uninstall  # remove everything, including the queue
```

Logs are at `~/Library/Logs/mvb530.log` and `~/Library/Logs/mvb530d.log`.

## Usage

Power the printer on — hold the power key for 3 seconds, a flashing green LED
means it is on and not yet connected — then print to **Anko Inkless A4** from
any app. A page takes about six seconds to transfer.

### Printing while the printer is off

You can hit ⌘P first and switch the printer on afterwards. The job waits.

- The **agent** keeps scanning for up to `--wait` seconds (default **180**),
  restarting the scan every 15 s because a long CoreBluetooth scan goes quiet.
- If the printer still has not appeared it reports the job failed, and the
  local queue is created `printer-error-policy=retry-job`, so CUPS retries
  rather than disabling it.
- CUPS retries on its own schedule: `JobRetryInterval` (default **30 s**) and
  `JobRetryLimit` (default **5**).

To wait longer, raise the agent's window in
`~/Library/LaunchAgents/org.hmvs.mvb530d.plist` — add `--wait 900` to its
`ProgramArguments` for roughly 77 minutes of tolerance.

### Does macOS show it as offline?

The device scheme reports `PAPPL_PREASON_OFFLINE` when the agent cannot be
reached, which PAPPL turns into an IPP `printer-state-reasons` value and CUPS
surfaces in Printers & Scanners.

The caveat is the same as before: state is only refreshed **when a job runs or
PAPPL polls**, so switching the printer on does not instantly flip the UI. For
a live answer, ask the agent.

If you want a live answer at any moment, ask the agent instead:

```bash
curl localhost:9101/scan
```

### Diagnostics

```bash
curl localhost:9101/health              # agent and Bluetooth state
curl localhost:9101/scan                # nearby supported printers
curl -X POST localhost:9101/testpage    # test pattern, no CUPS or IPP involved
ipptool -t ipp://localhost:8631/ipp/print/anko get-printer-attributes.test
dns-sd -B '_ipp._tcp,_universal' local  # what AirPrint would see
~/.local/libexec/mvb530-printer-app status
```

## Tests

```bash
make test
```

78 checks, no hardware required. The protocol tests assert **byte-for-byte**
against 13 golden vectors produced by the reference implementation
([TiMini-Print](https://github.com/Dejniel/TiMini-Print)), so the encoder is
checked against a known-good encoder rather than against itself. Coverage
includes CRC-8, packet framing, RLE (including runs over 127 and the raw
fallback), bit order, tail-feed arithmetic, nearest-neighbour scaling, Atkinson
dithering, and the filter end to end against synthetic CUPS rasters in four
colour spaces — plus short-row cases that must come back white rather than
read past the end of the buffer.

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
- Tested on macOS 26.6, Apple Silicon. AirPrint discovery is verified from the
  DNS-SD records; printing from iOS and Android is untested.
- PAPPL is vendored and built from source: it is not packaged for Homebrew.

## Credits

[PAPPL](https://github.com/michaelrsweet/pappl) by Michael R Sweet (Apache 2.0)
provides the IPP service; it is vendored as a submodule pinned to v1.4.12.

The protocol was reverse-engineered with reference to
[TiMini-Print](https://github.com/Dejniel/TiMini-Print) by Daniel Banecki
(Apache 2.0), also vendored, and used only to generate the golden test
vectors. It is not required to build or run this driver.

## Licence

MIT.
