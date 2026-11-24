#!/bin/bash
# Build a Release copy and install it to /Applications, replacing any previous one.
#
# Without this, the only Pomodore that exists is Xcode's Debug build inside DerivedData,
# which Xcode deletes on a clean and which means reaching for Xcode after every reboot.
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_ID=com.bisaya.Pomodore
DEST=/Applications/Pomodore.app

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "== build"
xcodebuild -quiet -scheme Pomodore -configuration Release \
  -derivedDataPath "$BUILD" build

APP="$BUILD/Build/Products/Release/Pomodore.app"
[ -d "$APP" ] || { echo "FAIL  no app at $APP"; exit 1; }

# Never rm -rf something in /Applications that is not the app this script builds.
if [ -e "$DEST" ]; then
  existing=$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null || true)
  if [ "$existing" != "$BUNDLE_ID" ]; then
    echo "FAIL  $DEST exists and is not $BUNDLE_ID (found '${existing:-nothing}')"
    exit 1
  fi
fi

echo "== install"
# The running copy holds the status item and the hotkey registration, so it has to go
# before its bundle is replaced underneath it.
pkill -x Pomodore 2>/dev/null || true

rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "== launch"
open "$DEST"

echo
echo "Installed to $DEST"
echo "Being LSUIElement it has no dock icon: look for the timer in the menu bar."
echo "Notifications will prompt again on the first phase transition, because the"
echo "authorization record is tied to this bundle's signature."
