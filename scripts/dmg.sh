#!/bin/bash
# Turns build/Greenroom.app (from scripts/bundle.sh) into build/Greenroom-VERSION.dmg.
#   scripts/dmg.sh [--identity NAME] [--notarize]
# --identity  sign the disk image (use the identity the app was signed with)
# --notarize  have Apple notarize the app, staple it, build the image, notarize and staple that too.
#             Needs a Developer ID identity and credentials for notarytool, either
#               NOTARY_PROFILE   a keychain profile (`xcrun notarytool store-credentials NAME ...`), or
#               NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER_ID   an App Store Connect API key file and its ids
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IDENTITY=; NOTARIZE=
while [[ $# -gt 0 ]]; do case "$1" in
  --identity) IDENTITY=$2; shift 2 ;;
  --notarize) NOTARIZE=1; shift ;;
  *) echo "unknown option $1" >&2; exit 2 ;;
esac; done
APP="$ROOT/build/Greenroom.app"
[[ -d "$APP" ]] || { echo "error: run scripts/bundle.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "error: the app's signature does not verify; run scripts/bundle.sh again" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$ROOT/build/Greenroom-$VERSION.dmg"

notary() { # FILE
  local auth
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then auth=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${NOTARY_KEY:-}" ]]; then auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  else echo "error: set NOTARY_PROFILE, or NOTARY_KEY with NOTARY_KEY_ID and NOTARY_ISSUER_ID" >&2; exit 1; fi
  local out; out=$(xcrun notarytool submit "$1" "${auth[@]}" --wait --output-format json)
  echo "$out"
  if ! grep -q '"status" *: *"Accepted"' <<<"$out"; then
    local id; id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<<"$out" | head -1)
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" >&2 || true
    echo "error: notarization of $(basename "$1") was not accepted" >&2; exit 1
  fi
}

if [[ -n "$NOTARIZE" ]]; then
  [[ -n "$IDENTITY" ]] || { echo "error: --notarize needs --identity (a Developer ID Application identity)" >&2; exit 1; }
  codesign -dvv "$APP" 2>&1 | grep -q 'Authority=Developer ID Application' \
    || { echo "error: the app is not signed with a Developer ID identity; Apple will refuse it" >&2; exit 1; }
  ZIP="$ROOT/build/Greenroom-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notary "$ZIP"; rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# The image: the app and a link to /Applications, compressed with LZFSE (macOS 10.11+ reads it).
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp -Rc "$APP" "$STAGE/Greenroom.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Greenroom $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG"

if [[ -n "$IDENTITY" ]]; then
  ts=(); [[ "$IDENTITY" == - ]] || ts=(--timestamp)
  codesign --force --sign "$IDENTITY" "${ts[@]}" "$DMG"
fi
if [[ -n "$NOTARIZE" ]]; then
  notary "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
hdiutil verify -quiet "$DMG"
(cd "$ROOT/build" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG ($(du -h "$DMG" | cut -f1))"
