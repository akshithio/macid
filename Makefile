# MacID — face unlock for the macOS lock screen.

CC      ?= clang
CFLAGS  += -Wall -Wextra -O2 -fPIC -arch arm64
LDFLAGS += -shared -lpam

BUILD    := build
SWIFTBIN := .build/release
# Root-only all the way up. See Install.moduleDir for why not /usr/local/lib.
PAMDIR   := /opt/macid/lib
BINDIR   := /usr/local/bin
APPDIR   := /Applications
VERSION  := 0.1.0

MODULES := $(BUILD)/pam_macid.so $(BUILD)/pam_macidprobe.so
APP     := $(BUILD)/MacID.app

.PHONY: all swift app install uninstall dist clean

all: $(MODULES) swift app

# --- PAM modules -------------------------------------------------------------

$(BUILD)/%.so: pam/%.c | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
	codesign --force --sign - $@

$(BUILD):
	@mkdir -p $(BUILD)

# --- Swift -------------------------------------------------------------------

swift:
	swift build -c release

# --- App bundle --------------------------------------------------------------
# SwiftPM emits a bare executable; a menu bar app needs a real bundle around it
# so that LSUIElement and the camera usage string are read from disk.

app: swift | $(BUILD)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(SWIFTBIN)/MacIDApp $(APP)/Contents/MacOS/MacIDApp
	@cp app/Resources/Info.plist $(APP)/Contents/Info.plist
	@codesign --force --deep --sign - --identifier io.akshith.macid.app $(APP)
	@echo "built $(APP)"

# --- Install -----------------------------------------------------------------

install:
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make install" >&2; exit 1; }
	@[ -f "$(BUILD)/pam_macid.so" ] && [ -x "$(SWIFTBIN)/macid" ] || { \
		echo "not built yet — run 'make' first (as yourself, not root)" >&2; exit 1; }
	install -d -o root -g wheel -m 755 /opt/macid $(PAMDIR)
	install -o root -g wheel -m 644 $(BUILD)/pam_macid.so $(PAMDIR)/pam_macid.so
	install -o root -g wheel -m 755 $(SWIFTBIN)/macid $(BINDIR)/macid
	@# A stable signing identifier gives TCC something constant to key the
	@# camera grant on. Without it the ad-hoc cdhash changes on every rebuild
	@# and macOS re-prompts for the camera each time.
	@codesign --force --sign - --identifier io.akshith.macid $(BINDIR)/macid
	@rm -rf $(APPDIR)/MacID.app
	@cp -R $(APP) $(APPDIR)/MacID.app
	@echo "installed binaries; wiring system..."
	@$(BINDIR)/macid install

uninstall:
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make uninstall" >&2; exit 1; }
	-@$(BINDIR)/macid uninstall
	@rm -rf $(APPDIR)/MacID.app $(BINDIR)/macid
	@echo "uninstalled"

# --- Distribution ------------------------------------------------------------
# A source tarball served from macid.akshith.io. Source rather than binaries:
# this installs a PAM module, and asking people to trust an unsigned binary for
# that is a worse trade than asking them to have Xcode tools.

dist: clean
	@mkdir -p web/public
	@tar --exclude='.git' --exclude='node_modules' --exclude='.build' \
	     --exclude='build' --exclude='web' --exclude='.next' \
	     -czf web/public/macid-$(VERSION).tar.gz \
	     Package.swift Makefile README.md LICENSE install.sh core agent app pam scripts
	@cp web/public/macid-$(VERSION).tar.gz web/public/macid-latest.tar.gz
	@cp install.sh web/public/install.sh
	@echo "web/public/macid-$(VERSION).tar.gz ($$(du -h web/public/macid-$(VERSION).tar.gz | cut -f1))"

clean:
	rm -rf $(BUILD)
	swift package clean 2>/dev/null || true
