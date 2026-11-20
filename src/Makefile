# The Gibson - Makefile (SceneKit/Metal screensaver)
#
# 'make'                build dist/TheGibson.app (host app + screensaver appex)
# 'make install-saver'  install to /Applications, register, restart WallpaperAgent
# 'make enable-saver'   also set it as the idle / hot-corner screensaver
# 'make scn'            build and launch the SceneKit preview window
# 'make run-app'        open dist/TheGibson.app
# 'make legacy-saver'   build the classic .saver plug-in (macOS 11+)
# 'make clean'          remove objects, executables, and dist bundles

CXX ?= c++
CXXFLAGS ?= -g -Wall -std=c++17 -Wno-deprecated-declarations
SAVER_MIN_OS ?= 14.0
LEGACY_SAVER_MIN_OS ?= 11.0
# Objects linked into both the appex (14.0) and the legacy saver (11.0).
SHARED_MIN_OS ?= $(LEGACY_SAVER_MIN_OS)

SAVER_MM = saver/GibsonSaverView.mm saver/GibsonMusic.mm
APPEX_MM = \
	saver/GibsonScreenSaverExtension.mm \
	saver/GibsonScreenSaverViewController.mm
HOST_MM = app/GibsonApp.mm
SCN_MM = \
	scenekit/GibsonSCNScene.mm \
	scenekit/GibsonSCNCamera.mm
PREVIEW_MM = scenekit/scn_preview.mm

SCN_OBJS = $(SCN_MM:.mm=.o) gibson_settings.o
SAVER_OBJS = $(SAVER_MM:.mm=.o)
APPEX_OBJS = $(APPEX_MM:.mm=.o)
HOST_OBJ = $(HOST_MM:.mm=.o)
PREVIEW_OBJ = $(PREVIEW_MM:.mm=.o)
PREVIEW = scn_preview

SCN_INCLUDES = -I. -Iscenekit -Isaver
SCN_FRAMEWORKS = SceneKit ModelIO QuartzCore Metal Cocoa Foundation AppKit CoreGraphics
SAVER_SCN_LIBS = \
	-Wl,-ObjC \
	$(foreach n,$(SCN_FRAMEWORKS) ScreenSaver Foundation AVFoundation,-framework $n)
APPEX_LIBS = $(SAVER_SCN_LIBS) -framework ExtensionFoundation
PREVIEW_LIBS = \
	$(foreach n,$(SCN_FRAMEWORKS),-framework $n)

ROOT := $(abspath ..)
DIST := $(ROOT)/dist
APP_DIR := $(DIST)/TheGibson.app
APP_BIN := $(APP_DIR)/Contents/MacOS/TheGibson
APPEX_DIR := $(APP_DIR)/Contents/PlugIns/TheGibson.appex
APPEX_BIN := $(APPEX_DIR)/Contents/MacOS/TheGibson
LEGACY_SAVER_DIR := $(DIST)/Gibson.saver
LEGACY_SAVER_BIN := $(LEGACY_SAVER_DIR)/Contents/MacOS/Gibson
INSTALL_APP := /Applications/TheGibson.app
INSTALL_APPEX := $(INSTALL_APP)/Contents/PlugIns/TheGibson.appex
LEGACY_INSTALL_DIR := $(HOME)/Library/Screen Savers

# Developer ID Application, then Apple Development, then ad-hoc.
ifeq ($(origin CODESIGN_IDENTITY),undefined)
  CODESIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
endif
ifeq ($(CODESIGN_IDENTITY),)
  CODESIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
endif
ifeq ($(CODESIGN_IDENTITY),)
  CODESIGN_IDENTITY := -
endif

ifeq ($(CODESIGN_IDENTITY),-)
  CODESIGN_OPTS :=
else
  CODESIGN_OPTS := --options runtime --timestamp
endif

.PHONY: all clean saver install-saver uninstall-saver enable-saver scn \
	legacy-saver notarize run-app

all: saver
	@echo "It's time to hack the gibson."

scenekit/%.o: scenekit/%.mm
	$(CXX) $(CXXFLAGS) -fobjc-arc -mmacosx-version-min=$(SHARED_MIN_OS) $(SCN_INCLUDES) -c $< -o $@

gibson_settings.o: gibson_settings.cpp gibson_settings.h
	$(CXX) $(CXXFLAGS) -mmacosx-version-min=$(SHARED_MIN_OS) -I. -c $< -o $@

saver/%.o: saver/%.mm
	$(CXX) $(CXXFLAGS) -fobjc-arc -mmacosx-version-min=$(SAVER_MIN_OS) $(SCN_INCLUDES) -c $< -o $@

app/%.o: app/%.mm
	$(CXX) $(CXXFLAGS) -fobjc-arc -mmacosx-version-min=$(SAVER_MIN_OS) $(SCN_INCLUDES) -c $< -o $@

$(PREVIEW): $(SCN_OBJS) $(PREVIEW_OBJ)
	$(CXX) $(CXXFLAGS) -fobjc-arc $(SCN_INCLUDES) -o $(PREVIEW) $(SCN_OBJS) $(PREVIEW_OBJ) $(PREVIEW_LIBS)

scn: $(PREVIEW)
	./$(PREVIEW)

saver: $(APP_BIN)

# Media is copied into the bundle, so a regenerated texture must trigger a rebuild.
MEDIA_FILES := $(wildcard $(ROOT)/media/*)

$(APPEX_BIN): $(SCN_OBJS) $(SAVER_OBJS) $(APPEX_OBJS) saver/TheGibson.appex.plist saver/TheGibson.appex.entitlements $(ROOT)/config.txt $(MEDIA_FILES)
	rm -rf "$(APPEX_DIR)"
	mkdir -p "$(APPEX_DIR)/Contents/MacOS" "$(APPEX_DIR)/Contents/Resources/media"
	cp saver/TheGibson.appex.plist "$(APPEX_DIR)/Contents/Info.plist"
	printf 'XPC!????' > "$(APPEX_DIR)/Contents/PkgInfo"
	rsync -a --exclude '*.xcf' --exclude 'screenshot*' --exclude '*_src.png' --exclude '*_traces.png' "$(ROOT)/media/" "$(APPEX_DIR)/Contents/Resources/media/"
	cp "$(ROOT)/config.txt" "$(APPEX_DIR)/Contents/Resources/config.txt"
	sips -z 65 107 "$(ROOT)/media/screenshot1.png" --out "$(APPEX_DIR)/Contents/Resources/thumbnail.png" >/dev/null
	sips -z 130 214 "$(ROOT)/media/screenshot1.png" --out "$(APPEX_DIR)/Contents/Resources/thumbnail@2x.png" >/dev/null
	$(CXX) $(CXXFLAGS) -fobjc-arc -fapplication-extension \
		-mmacosx-version-min=$(SAVER_MIN_OS) \
		-Wl,-e,_NSExtensionMain \
		-o "$(APPEX_BIN)" $(SCN_OBJS) $(SAVER_OBJS) $(APPEX_OBJS) $(APPEX_LIBS)
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) \
		--entitlements saver/TheGibson.appex.entitlements \
		"$(APPEX_DIR)"
	@echo "Built $(APPEX_DIR) (signed with $(CODESIGN_IDENTITY))"

$(APP_BIN): $(APPEX_BIN) $(SCN_OBJS) $(HOST_OBJ) app/Info.plist
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources" "$(APP_DIR)/Contents/PlugIns"
	cp app/Info.plist "$(APP_DIR)/Contents/Info.plist"
	printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	$(CXX) $(CXXFLAGS) -fobjc-arc -mmacosx-version-min=$(SAVER_MIN_OS) \
		-o "$(APP_BIN)" $(SCN_OBJS) $(HOST_OBJ) $(PREVIEW_LIBS)
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) "$(APP_DIR)"
	@echo "Built $(APP_DIR) (signed with $(CODESIGN_IDENTITY))"
	@echo "Install with: make install-saver"

run-app: saver
	open "$(APP_DIR)"

install-saver: saver
	@if [ -d "$(INSTALL_APP)" ]; then rm -rf "$(INSTALL_APP)"; fi
	cp -R "$(APP_DIR)" "$(INSTALL_APP)"
	rm -rf "$(LEGACY_INSTALL_DIR)/Gibson.saver"
	mkdir -p "$(HOME)/Library/Application Support/TheGibson"
	@if [ ! -f "$(HOME)/Library/Application Support/TheGibson/config.txt" ]; then \
		cp "$(ROOT)/config.txt" "$(HOME)/Library/Application Support/TheGibson/config.txt"; \
		echo "Wrote $(HOME)/Library/Application Support/TheGibson/config.txt"; \
	fi
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) \
		--entitlements saver/TheGibson.appex.entitlements \
		"$(INSTALL_APPEX)"
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) "$(INSTALL_APP)"
	pluginkit -a "$(INSTALL_APPEX)" || true
	"$(INSTALL_APP)/Contents/MacOS/TheGibson" --register || true
	@# Re-registering gives the extension a new plugin UUID; a running
	@# WallpaperAgent keeps the stale one and the saver comes up black.
	@pkill -x TheGibson 2>/dev/null || true
	@killall WallpaperAgent 2>/dev/null || true
	@echo "Installed $(INSTALL_APP)"
	@echo "Open System Settings → Screen Saver and choose The Gibson."
	@echo "Activity Monitor should show TheGibson, not legacyScreenSaver."

enable-saver: install-saver
	python3 saver/enable_idle.py

uninstall-saver:
	-pluginkit -r "$(INSTALL_APPEX)"
	rm -rf "$(INSTALL_APP)"
	rm -rf "$(LEGACY_INSTALL_DIR)/Gibson.saver"
	@echo "Removed $(INSTALL_APP)"

legacy-saver: $(LEGACY_SAVER_BIN)

$(LEGACY_SAVER_BIN): $(SCN_OBJS) $(SAVER_OBJS) saver/Info.plist $(ROOT)/config.txt
	rm -rf "$(LEGACY_SAVER_DIR)"
	mkdir -p "$(LEGACY_SAVER_DIR)/Contents/MacOS" "$(LEGACY_SAVER_DIR)/Contents/Resources/media"
	cp saver/Info.plist "$(LEGACY_SAVER_DIR)/Contents/Info.plist"
	printf 'BNDL????' > "$(LEGACY_SAVER_DIR)/Contents/PkgInfo"
	rsync -a --exclude '*.xcf' --exclude 'screenshot*' --exclude '*_src.png' --exclude '*_traces.png' "$(ROOT)/media/" "$(LEGACY_SAVER_DIR)/Contents/Resources/media/"
	cp "$(ROOT)/config.txt" "$(LEGACY_SAVER_DIR)/Contents/Resources/config.txt"
	$(CXX) $(CXXFLAGS) -fobjc-arc -mmacosx-version-min=$(LEGACY_SAVER_MIN_OS) -bundle \
		-o "$(LEGACY_SAVER_BIN)" $(SCN_OBJS) $(SAVER_OBJS) $(SAVER_SCN_LIBS)
	codesign --force --deep --sign - "$(LEGACY_SAVER_DIR)"
	@echo "Built $(LEGACY_SAVER_DIR) (legacy .saver for older macOS)"

notarize: saver
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "No Developer ID identity in the keychain."; \
		echo "Create a Developer ID Application certificate, then:"; \
		echo "  make saver CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'"; \
		echo "  make notarize NOTARY_PROFILE=AC_PASSWORD"; \
		exit 1; \
	fi
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "Set NOTARY_PROFILE to a notarytool keychain profile:"; \
		echo "  xcrun notarytool store-credentials AC_PASSWORD --apple-id you@email.com --team-id TEAMID"; \
		echo "  make notarize NOTARY_PROFILE=AC_PASSWORD"; \
		exit 1; \
	fi
	ditto -c -k --keepParent "$(APP_DIR)" "$(DIST)/TheGibson.zip"
	xcrun notarytool submit "$(DIST)/TheGibson.zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_DIR)"
	@echo "Notarized $(APP_DIR)"

clean:
	rm -f $(SAVER_OBJS) $(APPEX_OBJS) $(SCN_OBJS) $(HOST_OBJ) $(PREVIEW_OBJ) $(PREVIEW)
	rm -rf "$(DIST)"
