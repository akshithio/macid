# MacID — face unlock for the macOS lock screen.

CC      ?= clang
CFLAGS  += -Wall -Wextra -O2 -fPIC -arch arm64
LDFLAGS += -shared -lpam

# A real signing identity keeps the camera grant across rebuilds; falls back to ad-hoc.
SIGN_ID  ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
              awk '/Apple Development|Developer ID Application/ { print $$2; exit }')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID  := -
endif

# Releases pass --timestamp for notarization.
CSFLAGS  ?=

BUILD    := build
SWIFTBIN := .build/release
PAMDIR   := /opt/macid/lib
APPDIR   := /Applications
VERSION  := 0.1.0

MODULES := $(BUILD)/pam_macid.so
SPARKLE := .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_BIN := .build/artifacts/sparkle/Sparkle/bin
APP     := $(BUILD)/MacID.app

.PHONY: all swift app run icons install uninstall dmg clean

all: $(MODULES) swift app

# Stamps each module with its source hash so the app can detect an outdated install.
$(BUILD)/%.so: pam/%.c | $(BUILD)
	$(CC) $(CFLAGS) -DMACID_MODULE_ID=\"$$(shasum $< | cut -c1-40)\" $(LDFLAGS) -o $@ $<
	codesign --force $(CSFLAGS) --sign $(SIGN_ID) $@

$(BUILD):
	@mkdir -p $(BUILD)

swift:
	swift build -c release

# Nested code is signed inside-out, each piece before the bundle that seals it.
app: $(BUILD)/pam_macid.so swift app/Resources/MacID.icns model/FaceEmbedding.mlpackage | $(BUILD)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Helpers
	@cp $(SWIFTBIN)/MacIDApp $(APP)/Contents/MacOS/MacIDApp
	@cp app/Resources/Info.plist $(APP)/Contents/Info.plist
	@cp app/Resources/MacID.icns $(APP)/Contents/Resources/MacID.icns
	@xcrun coremlcompiler compile model/FaceEmbedding.mlpackage $(APP)/Contents/Resources >/dev/null
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@mkdir -p $(APP)/Contents/Frameworks
	@ditto $(SPARKLE) $(APP)/Contents/Frameworks/Sparkle.framework
	@codesign --force $(CSFLAGS) --sign $(SIGN_ID) --options runtime $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	@codesign --force $(CSFLAGS) --sign $(SIGN_ID) --options runtime --preserve-metadata=entitlements $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	@codesign --force $(CSFLAGS) --sign $(SIGN_ID) --options runtime $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	@codesign --force $(CSFLAGS) --sign $(SIGN_ID) --options runtime $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	@codesign --force $(CSFLAGS) --sign $(SIGN_ID) --options runtime $(APP)/Contents/Frameworks/Sparkle.framework
	@cp $(SWIFTBIN)/macid-helper $(APP)/Contents/Helpers/macid-helper
	@cp $(BUILD)/pam_macid.so $(APP)/Contents/Helpers/pam_macid.so
	@codesign --force $(CSFLAGS) --sign $(SIGN_ID) --identifier io.akshith.macid.helper $(APP)/Contents/Helpers/macid-helper
	@codesign --force $(CSFLAGS) --sign $(SIGN_ID) $(APP)/Contents/Helpers/pam_macid.so
	@codesign --force $(CSFLAGS) --sign $(SIGN_ID) --options runtime \
		--entitlements app/Resources/MacID.entitlements \
		--identifier io.akshith.macid.app $(APP)
	@echo "built $(APP)"

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Puts the fresh build in /Applications, the only copy macOS should know about, and opens it.
run: all
	@pkill -x MacIDApp || true
	@rsync -a --delete $(APP)/ $(APPDIR)/MacID.app/
	@$(LSREGISTER) -u $(APP) 2>/dev/null || true
	@$(LSREGISTER) -f $(APPDIR)/MacID.app
	@mdimport $(APPDIR)/MacID.app 2>/dev/null || true
	@open $(APPDIR)/MacID.app
	@echo "running $(APPDIR)/MacID.app"

# Run after changing scripts/make-icons.swift; the .icns is committed.
icons:
	@swift scripts/make-icons.swift $(BUILD)/MacID.iconset > /dev/null
	@iconutil -c icns $(BUILD)/MacID.iconset -o app/Resources/MacID.icns
	@echo "app/Resources/MacID.icns regenerated"

install:
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make install" >&2; exit 1; }
	@[ -d "$(APP)" ] || { echo "not built yet — run 'make' first (as yourself, not root)" >&2; exit 1; }
	@rm -rf $(APPDIR)/MacID.app
	@cp -R $(APP) $(APPDIR)/MacID.app
	@echo "installed $(APPDIR)/MacID.app"
	install -d -o root -g wheel -m 755 /opt/macid $(PAMDIR)
	install -o root -g wheel -m 644 $(BUILD)/pam_macid.so $(PAMDIR)/pam_macid.so
	@$(APPDIR)/MacID.app/Contents/Helpers/macid-helper install
	@echo ""
	@echo "Now open MacID to enroll your face:  open -a MacID"

uninstall:
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make uninstall" >&2; exit 1; }
	-@$(APPDIR)/MacID.app/Contents/Helpers/macid-helper uninstall
	@rm -rf $(APPDIR)/MacID.app
	@echo "uninstalled"

# Unsigned local disk image; signed releases come from scripts/release.sh.
dmg: all
	@rm -rf $(BUILD)/dmg $(BUILD)/MacID.dmg
	@mkdir -p $(BUILD)/dmg web/public
	@cp -R $(APP) $(BUILD)/dmg/MacID.app
	@ln -s /Applications $(BUILD)/dmg/Applications
	@hdiutil create -volname MacID -srcfolder $(BUILD)/dmg \
	     -ov -quiet -format UDZO $(BUILD)/MacID.dmg
	@cp $(BUILD)/MacID.dmg web/public/MacID.dmg
	@echo "web/public/MacID.dmg ($$(du -h web/public/MacID.dmg | cut -f1))"

clean:
	rm -rf $(BUILD)
	swift package clean 2>/dev/null || true
