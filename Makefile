.PHONY: gen app build run test typecheck recorder-cli drift-selftest clean

APP_NAME := STLTHRecorder
SCHEME := STLTHRecorder
BUILD_DIR := build
PYTHON := .venv/bin/python

# XCTest/swift-testing runtime ships inside Xcode. On a machine that has only the
# Command Line Tools the swift-testing framework is present but not on the default
# search/rpath, so add it explicitly. With a full Xcode selected these stay empty.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIBS := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
HAS_XCODE := $(shell test -d "$$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform" && echo yes || echo no)

ifeq ($(HAS_XCODE),no)
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
              -Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
              -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
              -Xlinker -rpath -Xlinker $(CLT_LIBS)
else
TEST_FLAGS :=
endif

## Generate the Xcode project from project.yml (requires xcodegen)
gen:
	xcodegen generate

## Type-check the SwiftUI layer without Xcode — catches everything but the link step.
typecheck:
	swift build --package-path RecorderCore
	swiftc -typecheck App/Sources/*.swift \
	  -I RecorderCore/.build/arm64-apple-macosx/debug/Modules \
	  -target arm64-apple-macos14.4
	@echo "✅ App sources type-check"

## Build STLTHRecorder.app WITHOUT Xcode (Command Line Tools are enough)
app:
	./scripts/build-app.sh release

## Build via xcodebuild — only works with a full Xcode installed
build:
	xcodebuild -scheme $(SCHEME) -configuration Release -derivedDataPath $(BUILD_DIR) build

## Launch the built app
run:
	open $(BUILD_DIR)/$(APP_NAME).app

## Unit tests of the headless core — runs without Xcode
test:
	swift test --package-path RecorderCore $(TEST_FLAGS)

## Verify the drift toolchain against synthetic audio (no hardware needed)
drift-selftest:
	$(PYTHON) Tools/selftest_drift.py

## Headless capture bench. Built with swiftc (not SPM) so the Info.plist carrying
## NSAudioCaptureUsageDescription can be embedded straight into the binary — without
## it macOS never shows the system-audio TCC prompt. Works without Xcode.
recorder-cli:
	@mkdir -p $(BUILD_DIR)
	swiftc -O RecorderCore/Sources/RecorderCore/*.swift Tools/recorder-cli/main.swift \
	  -o $(BUILD_DIR)/recorder-cli \
	  -framework CoreAudio -framework AVFoundation \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tools/recorder-cli/Info.plist
	codesign -s - --force --timestamp=none $(BUILD_DIR)/recorder-cli
	@echo "✅ $(BUILD_DIR)/recorder-cli"

clean:
	rm -rf $(BUILD_DIR) RecorderCore/.build *.xcodeproj
