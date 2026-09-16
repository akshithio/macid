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

.PHONY: all swift app icons install uninstall dist clean

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
# SwiftPM emits a bare executable. MacID.app wraps it with its Info.plist and
# icon, and carries the command-line tool and PAM module in Contents/Helpers so
# the app can install face unlock without the repo or the curl installer.
#
# Nested code is signed inside-out, each piece before the bundle that seals it.
# The app itself gets the hardened runtime, which is why it needs the camera
# entitlement.

app: $(BUILD)/pam_macid.so swift app/Resources/MacID.icns | $(BUILD)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Helpers
	@cp $(SWIFTBIN)/MacIDApp $(APP)/Contents/MacOS/MacIDApp
	@cp app/Resources/Info.plist $(APP)/Contents/Info.plist
	@cp app/Resources/MacID.icns $(APP)/Contents/Resources/MacID.icns
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@cp $(SWIFTBIN)/macid $(APP)/Contents/Helpers/macid
	@cp $(BUILD)/pam_macid.so $(APP)/Contents/Helpers/pam_macid.so
	@codesign --force --sign - --identifier io.akshith.macid $(APP)/Contents/Helpers/macid
	@codesign --force --sign - $(APP)/Contents/Helpers/pam_macid.so
	@codesign --force --sign - --options runtime \
		--entitlements app/Resources/MacID.entitlements \
		--identifier io.akshith.macid.app $(APP)
	@echo "built $(APP)"

# The icon is generated from the mark and committed, so a build does not need
# to render it. Run `make icons` after changing tools/make-icons.swift.
icons:
	@swift tools/make-icons.swift $(BUILD)/MacID.iconset > /dev/null
	@iconutil -c icns $(BUILD)/MacID.iconset -o app/Resources/MacID.icns
	@echo "app/Resources/MacID.icns regenerated"

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
	     Package.swift Makefile README.md LICENSE install.sh core agent app pam scripts tools
	@cp web/public/macid-$(VERSION).tar.gz web/public/macid-latest.tar.gz
	@cp install.sh web/public/install.sh
	@echo "web/public/macid-$(VERSION).tar.gz ($$(du -h web/public/macid-$(VERSION).tar.gz | cut -f1))"

clean:
	rm -rf $(BUILD)
	swift package clean 2>/dev/null || true
