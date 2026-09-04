#!/bin/zsh
# Build STLTHRecorder.app WITHOUT Xcode.
#
# The whole toolchain we need — SwiftUI, CoreAudio taps, codesign — ships with the
# Command Line Tools. An .app is just a directory layout plus an Info.plist, so we
# assemble it directly instead of depending on xcodebuild (which needs a full Xcode,
# which needs an Apple ID).
#
#   scripts/build-app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="STLTHRecorder"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
CORE_BUILD="RecorderCore/.build/arm64-apple-macosx/$CONFIG"

echo "==> Збираю RecorderCore ($CONFIG)"
if [[ "$CONFIG" == "release" ]]; then
  swift build --package-path RecorderCore -c release
else
  swift build --package-path RecorderCore
fi

echo "==> Збираю виконуваний файл застосунку"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O App/Sources/*.swift "$CORE_BUILD"/RecorderCore.build/*.o \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  -target arm64-apple-macos14.4 \
  -I "$CORE_BUILD/Modules" \
  -framework CoreAudio \
  -framework AVFoundation \
  -framework SwiftUI \
  -framework AppKit \
  -framework ServiceManagement

echo "==> Вкладаю whisper-cli"
# Transcription used to demand Homebrew from the advisor, which is a dependency no
# advisor has. The binary is a couple of megabytes — the half gigabyte README refuses to
# carry is the *models*, and those are still downloaded on demand.
#
# Built from source rather than copied from Homebrew: see scripts/build-whisper.sh for
# why a brewed whisper-cli cannot be bundled at all.
if ./scripts/build-whisper.sh; then
  cp build/whisper/whisper-cli "$APP/Contents/MacOS/whisper-cli"
  chmod +w "$APP/Contents/MacOS/whisper-cli"
  # Nested code is signed before the bundle: editing anything inside it afterwards
  # invalidates the outer signature, and codesign refuses an unsigned executable within
  # a signed bundle outright.
  codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/whisper-cli"

  if otool -L "$APP/Contents/MacOS/whisper-cli" | grep -q "/opt/homebrew"; then
    echo "❌ whisper-cli усе ще посилається на Homebrew"
    exit 1
  fi
else
  # Not fatal: the recorder does not need transcription to work, and a machine without
  # cmake should still be able to build the app.
  echo "    ⚠️  whisper-cli не зібрано — застосунок піде без транскрибації"
fi

echo "==> Складаю bundle"
cp App/Info.plist "$APP/Contents/Info.plist"
# CFBundleExecutable/Identifier are normally injected by Xcode's build system.
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ua.stlth.STLTHRecorder" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ua.stlth.STLTHRecorder" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.4" "$APP/Contents/Info.plist" 2>/dev/null || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Підписую ad-hoc"
codesign --force --sign - \
  --entitlements App/STLTHRecorder.entitlements \
  --options runtime \
  "$APP"
codesign --verify --verbose "$APP"

echo "✅ $APP"
