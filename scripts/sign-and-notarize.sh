#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${DEVELOPER_IDENTITY:?Set DEVELOPER_IDENTITY to your Developer ID Application certificate}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an xcrun notarytool keychain profile}"

if [[ "$DEVELOPER_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "DEVELOPER_IDENTITY must be a Developer ID Application certificate" >&2
  exit 2
fi
if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$DEVELOPER_IDENTITY\""; then
  echo "The requested Developer ID certificate is not available in the login keychain" >&2
  exit 2
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "NOTARY_PROFILE is missing or cannot authenticate with notarytool" >&2
  exit 2
fi

./scripts/package-release.sh
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_IDENTITY" "$ROOT/CodeFlight.app"
codesign --verify --deep --strict "$ROOT/CodeFlight.app"

NOTARY_ZIP="$ROOT/release/CodeFlight-macOS-notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/CodeFlight.app" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$ROOT/CodeFlight.app"
xcrun stapler validate "$ROOT/CodeFlight.app"

ditto -c -k --sequesterRsrc --keepParent "$ROOT/CodeFlight.app" "$ROOT/release/CodeFlight-macOS-notarized.zip"
echo "Notarized artifacts are in $ROOT/release"
