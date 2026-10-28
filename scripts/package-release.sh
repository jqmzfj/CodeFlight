#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift test
swift build -c release --arch arm64
swift build -c release --arch x86_64
RELEASE_ARM_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
RELEASE_INTEL_DIR="$(swift build -c release --arch x86_64 --show-bin-path)"
mkdir -p "$ROOT/.build/universal"
lipo -create \
  "$RELEASE_ARM_DIR/CodeFlight" \
  "$RELEASE_INTEL_DIR/CodeFlight" \
  -output "$ROOT/.build/universal/CodeFlight"
# Always rebuild the app bundle from the binaries produced in this run. This
# prevents a stale checked-in bundle from being copied into a release after
# source changes or an interrupted prior packaging step.
CODEFLIGHT_EXECUTABLE="$ROOT/.build/universal/CodeFlight" ./scripts/package-app.sh
CODEFLIGHT_EXECUTABLE="$ROOT/.build/universal/CodeFlight" ./scripts/runtime-smoke-test.sh
python3 "$ROOT/scripts/verify-release-identity.py" "$ROOT/CodeFlight.app" \
  "$RELEASE_ARM_DIR/CodeFlight" "$RELEASE_INTEL_DIR/CodeFlight" > "$ROOT/.build/release-identity.json"

codesign --verify --deep --strict "$ROOT/CodeFlight.app"
ARCHS="$(lipo -archs "$ROOT/CodeFlight.app/Contents/MacOS/CodeFlight")"
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
  echo "Release app is not Universal 2 (found: $ARCHS)" >&2
  exit 3
fi

RELEASE_DIR="$ROOT/release"
mkdir -p "$RELEASE_DIR"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/CodeFlight.app" "$RELEASE_DIR/CodeFlight-macOS.zip"
unzip -tq "$RELEASE_DIR/CodeFlight-macOS.zip"

if command -v hdiutil >/dev/null 2>&1; then
  # Build a standard drag-to-install layout with an Applications shortcut.
  # A previously opened image may still be held by diskimages-helper. Build a
  # fresh inode, verify it, then atomically replace the distributed image.
  DMG_STAGE="$(mktemp -d "$RELEASE_DIR/.dmg-XXXXXX")"
  trap 'rm -f "$DMG_STAGE/CodeFlight-macOS.dmg"; rm -f "$DMG_STAGE/Applications"; rmdir "$DMG_STAGE/layout" "$DMG_STAGE" 2>/dev/null || true' EXIT
  mkdir -p "$DMG_STAGE/layout"
  ditto "$ROOT/CodeFlight.app" "$DMG_STAGE/layout/CodeFlight.app"
  ln -s /Applications "$DMG_STAGE/layout/Applications"
  hdiutil create -volname "CodeFlight" -srcfolder "$DMG_STAGE/layout" -format UDZO "$DMG_STAGE/CodeFlight-macOS.dmg" >/dev/null
  hdiutil verify "$DMG_STAGE/CodeFlight-macOS.dmg" >/dev/null
  mv -f "$DMG_STAGE/CodeFlight-macOS.dmg" "$RELEASE_DIR/CodeFlight-macOS.dmg"
fi
echo "Release artifacts are in $RELEASE_DIR"
