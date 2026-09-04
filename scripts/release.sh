#!/bin/zsh
# Build a distributable DMG — without Xcode.
#
# The original version called `xcodebuild`, which needs a full Xcode install, which
# needs an Apple ID. That made the whole distribution step hostage to a manual
# account login on the bench. Everything here runs on the Command Line Tools alone:
# `scripts/build-app.sh` assembles and signs the bundle, `create-dmg` wraps it.
#
# The app is signed ad-hoc (no Apple Developer Program), so Gatekeeper demands
# right-click → Open on first launch — that instruction lives in the README.
#
#   scripts/release.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP_NAME="STLTHRecorder"
BUILD_DIR="build"
DIST_DIR="dist"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

if ! command -v create-dmg >/dev/null; then
  echo "❌ Немає create-dmg. Встанови: brew install create-dmg"
  exit 1
fi

echo "==> Тести (у реліз не йде нічого червоного)"
make test >/dev/null

echo "==> Збираю $APP_NAME.app (Release, без Xcode)"
./scripts/build-app.sh release

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ Не знайдено $APP_PATH"
  exit 1
fi

# The version shown in About/Finder comes from the bundle, so stamp it here rather
# than leaving whatever the template carried.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
  "$APP_PATH/Contents/Info.plist"

echo "==> Перепідписую після зміни Info.plist"
# Editing anything inside the bundle invalidates the signature, so it has to be
# re-applied — otherwise Gatekeeper rejects the app outright instead of merely
# warning about an unidentified developer.
codesign --force --sign - \
  --entitlements App/STLTHRecorder.entitlements \
  --options runtime \
  "$APP_PATH"
codesign --verify --strict --verbose "$APP_PATH"

echo "==> Пакую DMG"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# create-dmg arranges the icons by driving Finder through AppleScript. On a machine
# without a responsive desktop — a cloud Mac reached over VNC, or CI — that call
# times out with "AppleEvent timed out (-1712)" and takes the whole build with it.
# The layout is cosmetic, the disk image is not, so fall back rather than fail.
pack_dmg() {
  create-dmg \
    --volname "$APP_NAME $VERSION" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "$APP_NAME.app" 140 190 \
    --app-drop-link 400 190 \
    --no-internet-enable \
    "$@" \
    "$DMG_PATH" \
    "$APP_PATH"
}

if ! pack_dmg; then
  echo "    ⚠️  Finder не відгукнувся — пакую без косметики (--skip-jenkins)"
  rm -f "$DIST_DIR"/*.dmg
  pack_dmg --skip-jenkins
fi

echo "==> Перевіряю, що образ монтується і застосунок усередині цілий"
MOUNT_POINT=$(mktemp -d)
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
if codesign --verify --strict "$MOUNT_POINT/$APP_NAME.app" 2>/dev/null; then
  echo "    ✅ підпис усередині DMG валідний"
else
  echo "    ❌ підпис усередині DMG зламаний"
  hdiutil detach "$MOUNT_POINT" -quiet
  rmdir "$MOUNT_POINT"
  exit 1
fi
hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT"

echo ""
echo "✅ $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo ""
echo "Перевірка на чистій машині: скопіювати DMG, змонтувати, перетягнути в"
echo "Applications, ПКМ → Open (ad-hoc підпис), видати два дозволи, записати сесію."
