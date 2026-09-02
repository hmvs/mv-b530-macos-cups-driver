# Anko Inkless A4 (MV-B530) macOS CUPS driver.
#
#   make            build and run the tests
#   make build      build only
#   make test       run the test suite
#   sudo make install     install the filter, backend, PPD and queue
#   make agent-start      run the print agent in this login session
#   make agent-stop       stop it
#   sudo make uninstall   remove everything this installed

PREFIX      ?= /usr/local
QUEUE       ?= Anko_Inkless_A4
FILTER_DIR  := /usr/libexec/cups/filter
BACKEND_DIR := /usr/libexec/cups/backend
PPD_DIR     := /Library/Printers/PPDs/Contents/Resources
AGENT_LABEL := org.hmvs.mvb530d
RELEASE     := .build/release

.PHONY: all build test install uninstall agent-start agent-stop agent-status \
        fixtures clean

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
	@if [ ! -x "$(RELEASE)/rastertomvb530" ]; then \
		echo "run 'make build' first (as your own user, not root)" >&2; exit 1; fi
	install -o root -g wheel -m 0755 $(RELEASE)/rastertomvb530 $(FILTER_DIR)/rastertomvb530
	install -o root -g wheel -m 0755 $(RELEASE)/mvb530-backend $(BACKEND_DIR)/mvb530
	install -d -o root -g wheel -m 0755 $(PREFIX)/libexec
	install -o root -g wheel -m 0755 $(RELEASE)/mvb530d $(PREFIX)/libexec/mvb530d
	@# The PPD directory is not guaranteed to exist: removing another
	@# vendor's driver can take Contents/ with it.
	install -d -o root -g admin -m 0755 $(PPD_DIR)
	install -o root -g admin -m 0644 mvb530.ppd $(PPD_DIR)/mvb530.ppd
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
	@echo "installed. Now start the agent as your own user:"
	@echo "    make agent-start"

uninstall:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "run: sudo make uninstall" >&2; exit 1; fi
	-lpadmin -x $(QUEUE) 2>/dev/null
	rm -f $(FILTER_DIR)/rastertomvb530 $(BACKEND_DIR)/mvb530
	rm -f $(PREFIX)/libexec/mvb530d $(PPD_DIR)/mvb530.ppd
	-launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true
	@echo "removed. Stop the agent with: make agent-stop"

# The agent must be started by launchd, not from a shell. A shell-spawned
# process inherits the terminal's TCC identity and is killed the moment it
# touches CoreBluetooth; under launchd it is its own responsible process and
# its embedded Info.plist applies.
agent-start:
	@BIN=$$(test -x $(PREFIX)/libexec/mvb530d && echo $(PREFIX)/libexec/mvb530d \
		|| echo $$(pwd)/$(RELEASE)/mvb530d); \
	launchctl remove $(AGENT_LABEL) 2>/dev/null; sleep 1; \
	launchctl submit -l $(AGENT_LABEL) \
		-o /tmp/mvb530d.out -e /tmp/mvb530d.err -- $$BIN --verbose; \
	sleep 3; \
	if curl -sf -m 5 http://127.0.0.1:9101/health >/dev/null; then \
		echo "agent running: $$BIN"; \
		curl -s http://127.0.0.1:9101/health; \
	else \
		echo "agent failed to start; see /tmp/mvb530d.err" >&2; \
		tail -5 /tmp/mvb530d.err 2>/dev/null; exit 1; \
	fi

agent-stop:
	-launchctl remove $(AGENT_LABEL) 2>/dev/null
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

clean:
	rm -rf .build
