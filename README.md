# MV-B530 macOS CUPS driver — Kmart / Anko "Inkless A4 Printer"

An **IPP Everywhere / AirPrint** printer application for the **Kmart Anko
Inkless A4 Printer**, so you can press ⌘P from any macOS app — and optionally
from a phone on the same Wi-Fi — instead of being limited to the vendor's app.

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
⌘P → cupsd → PWG raster over IPP → mvb530-printer-app  (PAPPL, port 8631)
                                        ↓ bluetooth:// device scheme
                                     CoreBluetooth
                                        ↓ BLE GATT
                                     printer
```

One process, running as a user LaunchAgent. Nothing is installed as root, and
no PPD is authored here — `lpadmin -m everywhere` builds the queue from the IPP
attributes the printer application advertises.

### Discovery

```
_ipp._tcp,_universal     IPP Everywhere
_ipps._tcp,_universal    AirPrint
URF=V1.5,W8,PQ3-4-5,FN3,IS0-1,MT1-5,OB10,RS200
pdl=image/pwg-raster,image/urf
```

By default the service is **private**: it binds loopback only, so the records
above are visible to this Mac and nothing else.

### Sharing

Sharing turns a Bluetooth-only printer into a network printer any phone or
tablet can use, with the Mac relaying over BLE. It is off by default, because
**PAPPL's web interface requires no authentication** — measured, not assumed:

```
$ curl -o /dev/null -w '%{http_code}' http://<mac-ip>:8631/config
200          # editable admin page, no credentials, no WWW-Authenticate header
```

With all interfaces bound, joining any network — a café, a hotel, a coworking
space — advertises the printer there and hands anyone on it the ability to
print, change the darkness and paper settings, or delete the queue.

So exposure has to be asked for. The switch is in the web interface, under
**Sharing**:

```
http://localhost:8631/sharing
```

Pick "Share with the network" or "This Mac only" and save. The setting is
remembered, and the service restarts to apply it — which addresses are bound
is fixed when PAPPL starts and there is no API to drop a listener later, so a
restart is the only honest way to change it. launchd brings it straight back;
it takes a few seconds.

For running the server by hand there are also `--share` and `MVB530_SHARE=1`,
and an explicit `-o listen-hostname=...` overrides everything.

Verify which way it is bound:

```bash
lsof -nP -iTCP:8631 -sTCP:LISTEN
#   127.0.0.1:8631    private
#   *:8631            shared
```



### CoreBluetooth has to start on the main queue, after PAPPL

This is the one non-obvious constraint in the whole project.

PAPPL owns the main thread on macOS — it creates an `NSStatusItem`, and AppKit
throws *"NSWindow should only be instantiated on the main thread"* otherwise.
That `NSApplication` also runs the main run loop, which services the main
dispatch queue.

A `CBCentralManager` created **before** `papplMainloop`, or on a worker thread,
never leaves `.unknown` and delivers no state callback — no prompt, no error,
no crash. Created on the main queue *after* PAPPL is running, it reaches
`.poweredOn` normally. So start-up queues the work and lets the run loop pick
it up:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: startTransport)
```

### Why it is not an .app

The binary embeds its own `Info.plist` in a `__TEXT,__info_plist` section, so
it declares `NSBluetoothAlwaysUsageDescription` without a bundle. It must be
started **by launchd**: a shell-spawned process inherits the terminal's TCC
identity and is killed on the first CoreBluetooth call, whereas under launchd
it is its own responsible process.

### Status reporting

Presence is cached and refreshed by a background scan, never inline. PAPPL asks
for device status while rendering the web interface, and a Bluetooth scan takes
seconds — blocking there truncates the HTTP response and leaves the page
half-drawn. A job that actually reached the printer updates the cache directly,
which is cheaper and more authoritative than scanning.

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

`make install` puts one binary in `~/.local/libexec`, registers it as a user
LaunchAgent so it starts at login, and creates the driverless queue. To pin a
particular printer rather than the first one found:

```bash
MVB530_PRINTER=MV-B530-38AC make install
```

The first print raises a Bluetooth permission prompt. Approve it once.

```bash
make status     # is it up?
make restart    # after installing a new build
make uninstall  # remove everything, including the queue
```

Logs are at `~/Library/Logs/mvb530.log`, and in the unified log:

```bash
log stream --predicate 'subsystem == "org.hmvs.mvb530"' --info
```

## Usage

Power the printer on — hold the power key for 3 seconds, a flashing green LED
means it is on and not yet connected — then print to **Anko Inkless A4** from
any app. A page takes about six seconds to transfer.

### Printing while the printer is off

You can hit ⌘P first and switch the printer on afterwards. The job waits.

- The driver keeps scanning for up to `MVB530_WAIT` seconds (default **180**),
  restarting the scan every 15 s because a long CoreBluetooth scan goes quiet.
- If the printer still has not appeared the job fails, and the local queue is
  created `printer-error-policy=retry-job`, so CUPS retries rather than
  disabling it.
- CUPS retries on its own schedule: `JobRetryInterval` (default **30 s**) and
  `JobRetryLimit` (default **5**).

To wait longer, set `MVB530_WAIT` in
`~/Library/LaunchAgents/org.hmvs.mvb530.plist` — `900` gives roughly 77
minutes of tolerance.

### Does macOS show it as offline?

Yes. When the printer is not in range the driver publishes
`printer-state-reasons = offline`, which is what Printers & Scanners and the
print dialog render:

```bash
$ ipptool -tv ipp://localhost:8631/ipp/print/anko get-printer-attributes.test \
    | grep printer-state-reasons
    printer-state-reasons (keyword) = offline    # printer switched off
    printer-state-reasons (keyword) = none       # printer in range
```

Presence is re-checked at most every 45 seconds, so switching the printer on
takes up to that long to show. It is immediate after any job.

If you want a live answer at any moment, ask the agent instead:

```bash
curl localhost:9101/scan
```

### Diagnostics

```bash
make status
~/.local/libexec/mvb530-printer-app devices   # Bluetooth scan
~/.local/libexec/mvb530-printer-app jobs
ipptool -t ipp://localhost:8631/ipp/print/anko get-printer-attributes.test
dns-sd -B '_ipp._tcp,_universal' local        # what AirPrint would see
open http://localhost:8631/                   # PAPPL web interface
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
- One job at a time: the Bluetooth link is serialised.
- About 60 MB resident. Most of that is PAPPL plus OpenSSL, AppKit and the
  Swift runtime, not this code.
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
