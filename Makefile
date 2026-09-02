# Anko Inkless A4 (MV-B530) - IPP Everywhere printer application for macOS.
#
#   make                  build and run the tests
#   make build            build only
#   make test             run the test suite
#   make universal        universal (arm64 + x86_64) binaries for release
#   make install          install, no sudo required
#   make uninstall        remove everything this installed
#   make status           are the services up?
#   make restart          restart them after installing a new build
#
# Nothing here needs root. There is no CUPS filter, no backend and no PPD to
# install into system directories - the driver is an IPP service that macOS
# discovers over DNS-SD.

PREFIX      ?= $(HOME)/.local
QUEUE       ?= Anko_Inkless_A4
IPP_PORT    ?= 8631
AGENTS_DIR  := $(HOME)/Library/LaunchAgents
LOGDIR      := $(HOME)/Library/Logs
APP_LABEL   := org.hmvs.mvb530
AGENT_LABEL := org.hmvs.mvb530d
RELEASE     := .build/release
UNIVERSAL   := .build/universal
# Which build to install from. Override for a universal release build:
#   make install BINDIR=.build/universal
BINDIR      ?= $(RELEASE)
GUI         := gui/$(shell id -u)
PAPPL_LIB   := vendor/pappl/pappl/libpappl.a

# launchctl bootstrap returns EIO if the label is still loaded, and bootout is
# not synchronous, so wait for it to go before loading the new definition. If
# it will not unload, restart it in place instead of failing the install.
define reload
	launchctl bootout $(GUI)/$(1) 2>/dev/null || true; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		launchctl print $(GUI)/$(1) >/dev/null 2>&1 || break; \
		sleep 1; \
	done; \
	if launchctl print $(GUI)/$(1) >/dev/null 2>&1; then \
		launchctl kickstart -k $(GUI)/$(1); \
	else \
		launchctl bootstrap $(GUI) $(AGENTS_DIR)/$(1).plist; \
	fi
endef

.PHONY: all build test install uninstall status restart universal pappl \
        fixtures clean

all: test

# PAPPL is vendored rather than packaged: it is not in Homebrew, and building
# it here lets us compile out the parts we do not use.
pappl: $(PAPPL_LIB)

$(PAPPL_LIB):
	./scripts/build-pappl.sh

build: $(PAPPL_LIB)
	swift build -c release
	@# Ad-hoc signatures give each binary a stable identity, which is what
	@# TCC keys the Bluetooth grant against. They must differ: two binaries
	@# claiming one identity confuses the grant for both.
	codesign --force -s - --identifier $(AGENT_LABEL) $(RELEASE)/mvb530d
	codesign --force -s - --identifier $(APP_LABEL) $(RELEASE)/mvb530-printer-app
	@echo "built: mvb530-printer-app, mvb530d"

test: build
	./$(RELEASE)/MVBTests tests/fixtures/line_eight.txt

install: build
	@if [ "$$(id -u)" -eq 0 ]; then \
		echo "run this as yourself, not with sudo - nothing needs root" >&2; \
		exit 1; fi
	install -d $(PREFIX)/libexec $(AGENTS_DIR) $(LOGDIR)
	install -m 0755 $(BINDIR)/mvb530d $(PREFIX)/libexec/mvb530d
	install -m 0755 $(BINDIR)/mvb530-printer-app $(PREFIX)/libexec/mvb530-printer-app
	@# launchd expands nothing in a plist, so the prefix is substituted here.
	sed -e 's|@PREFIX@|$(PREFIX)|g' -e 's|@LOGDIR@|$(LOGDIR)|g' \
		packaging/$(AGENT_LABEL).plist.in > $(AGENTS_DIR)/$(AGENT_LABEL).plist
	sed -e 's|@PREFIX@|$(PREFIX)|g' -e 's|@LOGDIR@|$(LOGDIR)|g' \
		packaging/$(APP_LABEL).plist.in > $(AGENTS_DIR)/$(APP_LABEL).plist
	@echo "==> starting the transport agent"
	@$(call reload,$(AGENT_LABEL))
	@# CoreBluetooth takes a few seconds to report a state, and the printer
	@# app asks the agent for one as soon as it starts.
	@sleep 8
	@echo "==> starting the printer application"
	@$(call reload,$(APP_LABEL))
	@sleep 6
	@echo "==> adding the printer to the IPP service"
	@# Discovery needs the radio, so name the printer explicitly. Replace
	@# MVB530_PRINTER to pin a particular unit.
	-$(PREFIX)/libexec/mvb530-printer-app add -d anko -m mvb530 \
		-v "bluetooth://$${MVB530_PRINTER:-}/" 2>/dev/null || true
	@echo "==> creating the driverless queue $(QUEUE)"
	@# -m everywhere makes CUPS build the queue from our IPP attributes:
	@# no PPD is authored or installed by this project.
	lpadmin -p $(QUEUE) -E -m everywhere \
		-v "ipp://localhost:$(IPP_PORT)/ipp/print/anko" \
		-o printer-is-shared=false \
		-o printer-error-policy=retry-job
	-lpoptions -d $(QUEUE) >/dev/null 2>&1 || true
	@echo
	@echo "installed. Print to \"$(QUEUE)\" from any app."
	@echo "The first print raises a Bluetooth permission prompt; approve it."

uninstall:
	-lpadmin -x $(QUEUE) 2>/dev/null
	-launchctl bootout $(GUI)/$(APP_LABEL) 2>/dev/null || true
	-launchctl bootout $(GUI)/$(AGENT_LABEL) 2>/dev/null || true
	rm -f $(AGENTS_DIR)/$(APP_LABEL).plist $(AGENTS_DIR)/$(AGENT_LABEL).plist
	rm -f $(PREFIX)/libexec/mvb530d $(PREFIX)/libexec/mvb530-printer-app
	@echo "removed."

status:
	@echo "agent:   $$(curl -sf -m 5 http://127.0.0.1:9101/health | tr '\n' ' ' || echo 'not responding')"
	@echo "logs:    $(LOGDIR)/mvb530.log, $(LOGDIR)/mvb530d.log"
	@code=$$(curl -sf -m 5 -o /dev/null -w '%{http_code}' http://localhost:$(IPP_PORT)/ 2>/dev/null); \
		echo "app:     $${code:-not responding}"
	@launchctl print $(GUI)/$(AGENT_LABEL) >/dev/null 2>&1 \
		&& echo "$(AGENT_LABEL): loaded" || echo "$(AGENT_LABEL): not loaded"
	@launchctl print $(GUI)/$(APP_LABEL) >/dev/null 2>&1 \
		&& echo "$(APP_LABEL): loaded" || echo "$(APP_LABEL): not loaded"

restart:
	launchctl kickstart -k $(GUI)/$(AGENT_LABEL)
	@sleep 8
	launchctl kickstart -k $(GUI)/$(APP_LABEL)
	@sleep 4
	@$(MAKE) --no-print-directory status

# Universal binaries for distribution. Built per-architecture and lipo'd
# rather than with `swift build --arch`, which needs a full Xcode install.
universal: $(PAPPL_LIB)
	swift build -c release --triple arm64-apple-macosx13.0
	swift build -c release --triple x86_64-apple-macosx13.0
	@mkdir -p $(UNIVERSAL)
	@for bin in mvb530-printer-app mvb530d; do \
		lipo -create -output $(UNIVERSAL)/$$bin \
			.build/arm64-apple-macosx/release/$$bin \
			.build/x86_64-apple-macosx/release/$$bin || exit 1; \
	done
	codesign --force -s - --identifier $(AGENT_LABEL) $(UNIVERSAL)/mvb530d
	codesign --force -s - --identifier $(APP_LABEL) $(UNIVERSAL)/mvb530-printer-app
	@lipo -info $(UNIVERSAL)/*

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
	-$(MAKE) -C vendor/pappl clean 2>/dev/null || true
