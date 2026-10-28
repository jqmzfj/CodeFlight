#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -n "${CODEFLIGHT_EXECUTABLE:-}" ]]; then
  test -x "$CODEFLIGHT_EXECUTABLE"
else
  swift build -c release
  APP_BUILD_DIR="$(swift build -c release --show-bin-path)"
  CODEFLIGHT_EXECUTABLE="$APP_BUILD_DIR/CodeFlight"
fi

APP="$ROOT/CodeFlight.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$CODEFLIGHT_EXECUTABLE" "$APP/Contents/MacOS/CodeFlight"
cp AppResources/Info.plist "$APP/Contents/Info.plist"
cp AppResources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp AppResources/SwiftTerm-LICENSE.txt "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cp AppResources/GitAskpass.sh "$APP/Contents/Resources/GitAskpass.sh"
chmod 755 "$APP/Contents/Resources/GitAskpass.sh"

codesign --force --deep --sign - "$APP" >/dev/null
echo "Created $APP"
