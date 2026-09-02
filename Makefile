# Anko Inkless A4 (MV-B530) macOS CUPS driver.
#
#   make                  build and run the tests
#   make build            build only
#   make test             run the test suite
#   make universal        universal (arm64 + x86_64) binaries for release
#   sudo make install     filter, backend, PPD, queue and the LaunchAgent
#   sudo make uninstall   remove everything this installed
#   make agent-status     is the agent up?
#   make agent-restart    restart it after installing a new build

PREFIX      ?= /usr/local
QUEUE       ?= Anko_Inkless_A4
FILTER_DIR  := /usr/libexec/cups/filter
BACKEND_DIR := /usr/libexec/cups/backend
PPD_DIR     := /Library/Printers/PPDs/Contents/Resources
AGENT_LABEL := org.hmvs.mvb530d
AGENT_PLIST := /Library/LaunchAgents/$(AGENT_LABEL).plist
RELEASE     := .build/release
UNIVERSAL   := .build/universal
# Which build to install from. Override for a universal release build:
#   sudo make install BINDIR=.build/universal
BINDIR      ?= $(RELEASE)
# A LaunchAgent must be bootstrapped into the GUI domain of the logged-in
# user, which is not root even when make is.
CONSOLE_UID := $(shell stat -f %u /dev/console)

.PHONY: all build test install uninstall agent-restart agent-start agent-stop \
        agent-status fixtures universal clean

all: test

build:
	swift build -c release
	@# An ad-hoc signature gives the agent a stable identity, which is what
	@# TCC keys the Bluetooth grant against.
	codesign --force -s - --identifier $(AGENT_LABEL) $(RELEASE)/mvb530d
	@echo "built: rastertomvb530, mvb530-backend, mvb530d"

test: build
	./$(RELEASE)/MVBTests tests/fixtures/line_eight.txt

install:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "run: sudo make install" >&2; exit 1; fi
	@if [ ! -x "$(BINDIR)/rastertomvb530" ]; then \
		echo "run 'make build' first (as your own user, not root)" >&2; exit 1; fi
	install -o root -g wheel -m 0755 $(BINDIR)/rastertomvb530 $(FILTER_DIR)/rastertomvb530
	install -o root -g wheel -m 0755 $(BINDIR)/mvb530-backend $(BACKEND_DIR)/mvb530
	install -d -o root -g wheel -m 0755 $(PREFIX)/libexec
	install -o root -g wheel -m 0755 $(BINDIR)/mvb530d $(PREFIX)/libexec/mvb530d
	@# The PPD directory is not guaranteed to exist: removing another
	@# vendor's driver can take Contents/ with it.
	install -d -o root -g admin -m 0755 $(PPD_DIR)
	install -o root -g admin -m 0644 mvb530.ppd $(PPD_DIR)/mvb530.ppd
	@echo "==> installing the print agent as a LaunchAgent"
	install -o root -g wheel -m 0644 packaging/$(AGENT_LABEL).plist $(AGENT_PLIST)
	@# A LaunchAgent has to be loaded into the logged-in user's GUI domain:
	@# CoreBluetooth needs a GUI session and the TCC grant is the user's.
	-launchctl bootout gui/$(CONSOLE_UID)/$(AGENT_LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$(CONSOLE_UID) $(AGENT_PLIST)
	@echo "==> restarting cupsd so it sees the new filter and backend"
	-launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || killall -HUP cupsd 2>/dev/null || true
	@sleep 2
	@echo "==> creating queue $(QUEUE)"
	@# retry-job keeps the queue enabled when the printer is merely asleep,
	@# which for a battery thermal printer is most of the time.
	lpadmin -p $(QUEUE) -E -v "mvb530:/" -P mvb530.ppd \
		-o printer-is-shared=false \
		-o printer-error-policy=retry-job
	-lpoptions -d $(QUEUE) >/dev/null 2>&1 || true
	-cupsenable $(QUEUE) 2>/dev/null || true
	-cupsaccept $(QUEUE) 2>/dev/null || true
	@echo
	@echo "installed. The agent starts at login from now on; nothing else to do."
	@echo "Print to \"$(QUEUE)\" from any app."

uninstall:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "run: sudo make uninstall" >&2; exit 1; fi
	-launchctl bootout gui/$(CONSOLE_UID)/$(AGENT_LABEL) 2>/dev/null || true
	rm -f $(AGENT_PLIST)
	-lpadmin -x $(QUEUE) 2>/dev/null
	rm -f $(FILTER_DIR)/rastertomvb530 $(BACKEND_DIR)/mvb530
	rm -f $(PREFIX)/libexec/mvb530d $(PPD_DIR)/mvb530.ppd
	-launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true
	@echo "removed."

# Restart the installed agent, e.g. after `sudo make install` of a new build.
agent-restart:
	@if [ ! -f $(AGENT_PLIST) ]; then \
		echo "no LaunchAgent installed - run 'sudo make install'" >&2; exit 1; fi
	launchctl kickstart -k gui/$(CONSOLE_UID)/$(AGENT_LABEL)
	@sleep 3
	@curl -sf -m 5 http://127.0.0.1:9101/health || \
		echo "agent not responding; log stream --predicate 'process == \"mvb530d\"'" >&2

# Development helper: run an uninstalled build. Not needed once installed -
# launchd starts the agent at login.
#
# It must be started by launchd either way. A shell-spawned process inherits
# the terminal's TCC identity and is killed the moment it touches
# CoreBluetooth; under launchd it is its own responsible process, so its
# embedded Info.plist applies.
agent-start:
	@BIN=$$(test -x $(PREFIX)/libexec/mvb530d && echo $(PREFIX)/libexec/mvb530d \
		|| echo $$(pwd)/$(RELEASE)/mvb530d); \
	for label in $$(launchctl list | awk '/org\.hmvs\.mvb530d/ {print $$3}'); do \
		launchctl remove $$label 2>/dev/null; \
	done; \
	pkill -x mvb530d 2>/dev/null; \
	sleep 2; \
	if lsof -nP -iTCP:9101 -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "port 9101 is held by another process:" >&2; \
		lsof -nP -iTCP:9101 -sTCP:LISTEN >&2; \
		exit 1; \
	fi; \
	launchctl submit -l $(AGENT_LABEL) \
		-o /tmp/mvb530d.out -e /tmp/mvb530d.err -- $$BIN --verbose; \
	sleep 3; \
	if curl -sf -m 5 http://127.0.0.1:9101/health >/dev/null; then \
		echo "agent running: $$(pgrep -fl mvb530d | head -1)"; \
		curl -s http://127.0.0.1:9101/health; \
	else \
		echo "agent failed to start; see /tmp/mvb530d.err" >&2; \
		tail -5 /tmp/mvb530d.err 2>/dev/null; exit 1; \
	fi

agent-stop:
	@for label in $$(launchctl list | awk '/org\.hmvs\.mvb530d/ {print $$3}'); do \
		launchctl remove $$label 2>/dev/null; \
	done; \
	pkill -x mvb530d 2>/dev/null; true
	@echo "agent stopped"

agent-status:
	@launchctl list | grep $(AGENT_LABEL) || echo "agent not running"
	@curl -sf -m 5 http://127.0.0.1:9101/health || echo "not responding"

# Regenerating golden vectors needs the vendored reference implementation and
# a Python interpreter. Neither is required to build, test or run the driver.
fixtures:
	git submodule update --init --depth 1 vendor/TiMini-Print
	python3 -m venv /tmp/mvbfix-venv
	/tmp/mvbfix-venv/bin/pip install --quiet -r vendor/TiMini-Print/requirements.txt
	/tmp/mvbfix-venv/bin/python tools/gen_fixtures.py > tests/fixtures/line_eight.txt
	@echo "regenerated tests/fixtures/line_eight.txt"

# Universal binaries for distribution. Built per-architecture and lipo'd
# rather than with `swift build --arch`, which needs a full Xcode install.
universal:
	swift build -c release --triple arm64-apple-macosx12.0
	swift build -c release --triple x86_64-apple-macosx12.0
	@mkdir -p $(UNIVERSAL)
	@for bin in rastertomvb530 mvb530-backend mvb530d; do \
		lipo -create -output $(UNIVERSAL)/$$bin \
			.build/arm64-apple-macosx/release/$$bin \
			.build/x86_64-apple-macosx/release/$$bin || exit 1; \
	done
	codesign --force -s - --identifier $(AGENT_LABEL) $(UNIVERSAL)/mvb530d
	@lipo -info $(UNIVERSAL)/*

clean:
	rm -rf .build
