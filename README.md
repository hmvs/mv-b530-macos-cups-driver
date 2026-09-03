# MV-B530 macOS driver — Kmart / Anko "Inkless A4 Printer"

An **IPP Everywhere / AirPrint** printer application for the **Kmart Anko
Inkless A4 Printer**, so you can press ⌘P from any macOS app — and optionally
from a phone on the same Wi-Fi — instead of being limited to the vendor's app.

Swift. Installs by dragging an app to Applications: no root, no PPD and no CUPS
filter, so nothing here depends on the parts CUPS 3.x removes.

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

The manual says macOS is supported over USB. **That procedure does not work.**
On the unit tested here the USB-C port is power-only — it presents no USB data
interface at all:

- `ioreg -p IOUSB` — the printer never enumerates, powered on or off
- zero `AppleUSBHost` enumeration events on connect
- tested with a cable proven to carry data (an iPhone enumerated over it
  seconds earlier), plugged straight into the Mac, bypassing all hubs

macOS cannot reach it over Bluetooth either: the stock CUPS `bluetooth` backend
finds the device and gives up, because it only speaks HCRP. So the only route
is the printer's own BLE protocol, which this project implements and exposes as
a standards-compliant IPP printer.

## Install

Needs macOS 13+, the Command Line Tools, and OpenSSL (`brew install openssl@3`)
— PAPPL requires TLS. No Xcode.

```bash
git clone --recursive https://github.com/hmvs/mv-b530-macos-cups-driver.git
cd mv-b530-macos-cups-driver
make test      # builds PAPPL, then runs the test suite
make app       # builds "Anko Inkless A4.app"
```

Drag `.build/Anko Inkless A4.app` into **Applications** and open it. On first
launch it registers in **System Settings → General → Login Items**, creates the
printer, and creates the CUPS queue **Anko_Inkless_A4** as the default.

It has no window: it lives in the menu bar, and its menu opens the web
interface. Being a menu-bar app it is not in the Dock or ⌘-Tab, but it is in
Finder, Launchpad and Spotlight under **Anko Inkless A4**.

The first print raises a Bluetooth permission prompt. Approve it once.

## Usage

Power the printer on — hold the power key for 3 seconds, a flashing green LED
means it is on and not yet connected — then print to **Anko Inkless A4** from
any app. A page takes about six seconds to transfer.

You can also hit ⌘P first and switch the printer on afterwards: the driver
keeps looking for it for three minutes, and CUPS retries after that rather than
disabling the queue. When the printer is out of range the queue shows as
offline, rechecked at most every 45 seconds.

### Settings

Everything is in the web interface, at <http://localhost:8631/>, reachable from
the menu bar icon:

| Page | |
|---|---|
| **Print quality** | how greys are printed — solid lines or shaded, and how dark a grey has to be to appear |
| **Sharing** | whether other devices on your network can print to it. Off by default |
| Printer settings | darkness, media, and the rest of PAPPL's own controls |

A few things have no page and live in
`~/Library/Application Support/Anko Inkless A4.conf`: `server-port`,
`mvb530-wait` (seconds to wait for a sleeping printer, default 180) and
`mvb530-printer` (pin one unit rather than the first found). Change the port
and the CUPS queue is repointed to match on the next start, so the two cannot
drift.

### Sharing

Sharing turns a Bluetooth-only printer into a network printer any phone can
use, with the Mac relaying over BLE. It is off by default, because **PAPPL's
web interface requires no authentication** — measured, not assumed:

```
$ curl -o /dev/null -w '%{http_code}' http://<mac-ip>:8631/config
200          # editable admin page, no credentials, no WWW-Authenticate header
```

With all interfaces bound, joining any network — a café, a hotel — advertises
the printer there and hands anyone on it the ability to print, change settings
or delete the queue. So it has to be asked for, on the Sharing page. Saving
restarts the service, which takes a few seconds.

### Without the app

`make install` runs the same binary as a user LaunchAgent instead: one binary
in `~/.local/libexec`, a plist in `~/Library/LaunchAgents`, and the same
driverless queue. Use it for a headless machine, or when you want the
command-line subcommands — a bundle cannot run them, for the reason in
[docs/macos.md](docs/macos.md).

```bash
make install                     # no sudo
make install IPP_PORT=9631       # if something else wants 8631
make status                      # is it up?
make uninstall                   # remove the agent and the queue
```

Only one of the two can hold the port, so `make app` removes the LaunchAgent if
it finds one.

### Diagnostics

```bash
log stream --predicate 'subsystem == "org.hmvs.mvb530"' --info
.build/release/mvb530-printer-app devices     # Bluetooth scan
ipptool -t ipp://localhost:8631/ipp/print/anko get-printer-attributes.test
dns-sd -B '_ipp._tcp,_universal' local        # what AirPrint would see
```

## How it works

```
⌘P → cupsd → PWG raster over IPP → the app  (PAPPL, port 8631)
                                      ↓ bluetooth:// device scheme
                                   CoreBluetooth
                                      ↓ BLE GATT
                                   printer
```

One process, started at login. Nothing is installed as root and no PPD is
authored — `lpadmin -m everywhere` builds the queue from the IPP attributes the
printer application advertises, published over DNS-SD as `_ipp._tcp` and
`_ipps._tcp` with the `_universal` subtype, which is what AirPrint looks for.

The details worth writing down are in three files:

- [docs/protocol.md](docs/protocol.md) — the wire protocol, the geometry, and
  the flow control the printer expects
- [docs/quality.md](docs/quality.md) — how grey becomes black or white, and the
  head settings that decide how a page looks
- [docs/macos.md](docs/macos.md) — what macOS and PAPPL impose: CoreBluetooth's
  main queue, TCC, and the arguments PAPPL throws away inside a bundle

## Tests

```bash
make test
```

106 checks, no hardware required. The protocol tests assert **byte-for-byte**
against 13 golden vectors produced by the reference implementation, so the
encoder is checked against a known-good encoder rather than against itself.
Coverage includes CRC-8, packet framing, RLE, bit order, tail-feed arithmetic,
scaling, dithering, the flow-control decoder against fragmented and corrupt
input, and the filter end to end against synthetic CUPS rasters.

Regenerating the golden vectors is the only thing that needs Python, and only
for maintainers:

```bash
make fixtures
```

## Limitations

- Greyscale only, 200 dpi. It is a thermal printer.
- One job at a time: the Bluetooth link is serialised.
- About 60 MB resident, most of it PAPPL, OpenSSL, AppKit and the Swift runtime.
- The printer must be on before the job reaches it, and cannot print while
  charging.
- Rebuilding the app changes its ad-hoc signature, so macOS asks for Bluetooth
  permission again. Installed once and left alone, it asks once.
- IPP's print-quality is ignored: the profile documents one head speed for text
  and one for photographs, and there is nothing to say what a third would do.
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
