# Living with macOS and PAPPL

Three constraints shaped this driver more than anything in the protocol did.

## CoreBluetooth has to start on the main queue, after PAPPL

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

## The app bundle, and the argv PAPPL throws away

It has to be an app, or launchd: a shell-spawned process inherits the
terminal's TCC identity and is killed on its first CoreBluetooth call. Started
from Finder or by launchd it is its own responsible process, and the Bluetooth
grant sticks to the bundle's signature.

PAPPL has its own idea of what a bundle wants. `papplMainloop` replaces argc
and argv outright when `argv[0]` contains `.app/Contents/MacOS/`:

```c
if (... strstr(argv[0], ".app/Contents/MacOS/") != NULL) {
  server_argv[] = { argv[0], "server", "-o", "log-file=syslog", ... };
  argc = 6; argv = server_argv;
}
```

So no option passed here survives, and the server would come up on PAPPL's own
default port, bound to every interface. What it does still read is
`~/Library/Application Support/<argv[0] base name>.conf`, so that is where the
port and the listen address go — written at start-up, before the mainloop.
Command-line options still win over it: PAPPL's `load_options` only fills in
what is unset.

The same override means the bundle cannot run its own subcommands — `add`,
`devices`, `jobs` would each start a second server. So the printer is not
created by shelling out, as `make install` did; PAPPL's first-run auto-add
creates it, and the CUPS queue is created in-process with `lpadmin`.

## Status reporting

Presence is cached and refreshed by a background scan, never inline. PAPPL asks
for device status while rendering the web interface, and a Bluetooth scan takes
seconds — blocking there truncates the HTTP response and leaves the page
half-drawn. A job that actually reached the printer updates the cache directly,
which is cheaper and more authoritative than scanning.
