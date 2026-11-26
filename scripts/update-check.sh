#!/bin/bash
# In-app updates end to end: an installed old build finds a newer one in a local appcast, downloads it, checks its EdDSA
# signature and code signature, and is replaced by it when it quits.
#
#   scripts/update-check.sh IDENTITY [OLD NEW]     (versions default to 0.0.1 and 0.0.2)
#
# IDENTITY is a codesign identity with a team (an Apple Development one is enough): Sparkle accepts an update only when
# it meets the installed app's designated requirement, which an ad hoc signature never does across builds. The appcast
# is signed with the EdDSA key generate_keys keeps in the login keychain under the account "greenroom" (the key whose
# public half is SUPublicEDKey in Resources/Info.plist). Nothing is sent outside this Mac but the signing timestamps.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IDENTITY=${1:?usage: scripts/update-check.sh IDENTITY [OLD NEW]}
OLD=${2:-0.0.1}; NEW=${3:-0.0.2}
# The test copy has Greenroom's bundle id and state folder: beside a running Greenroom it would take over its agent
# endpoint and preferences.
pgrep -x Greenroom >/dev/null && { echo "error: quit Greenroom first" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-update.XXXXXX")
mkdir -p "$W/installed" "$W/feed"
SERVER=; APP_PID=
# The installed copy has Greenroom's bundle id, so Sparkle keeps its state (last check, and so on) in Greenroom's own
# preferences: they are saved here and put back at the end.
DOMAIN=io.github.aglose.greenroom
defaults export "$DOMAIN" "$W/prefs.plist" 2>/dev/null || true
restore() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
  [[ -n "$SERVER" ]] && kill "$SERVER" 2>/dev/null
  pkill -f "$W/installed/Greenroom.app/Contents/MacOS/Greenroom" 2>/dev/null && sleep 2   # a relaunched copy writes on quit
  defaults delete "$DOMAIN" 2>/dev/null || true
  [[ -f "$W/prefs.plist" ]] && defaults import "$DOMAIN" "$W/prefs.plist"
  rm -rf "$W"   # two builds and a disk image: ~1 GB
  true
}
trap restore EXIT

echo "== build $OLD, install it, and pack its disk image for delta generation"
BUILD=$(git -C "$ROOT" rev-list --count HEAD)
GREENROOM_BUILD=$BUILD "$ROOT/scripts/bundle.sh" --identity "$IDENTITY" --version "$OLD" | tail -1
ditto "$ROOT/build/Greenroom.app" "$W/installed/Greenroom.app"
"$ROOT/scripts/dmg.sh" --identity "$IDENTITY" | tail -1
mkdir -p "$W/prev"
mv "$ROOT/build/Greenroom-$OLD.dmg" "$W/prev/"
rm -f "$ROOT/build/Greenroom-$OLD.dmg.sha256"

echo "== build $NEW as a disk image, and an appcast + binary delta for it"
GREENROOM_BUILD=$((BUILD + 1)) "$ROOT/scripts/bundle.sh" --identity "$IDENTITY" --version "$NEW" | tail -1
"$ROOT/scripts/dmg.sh" --identity "$IDENTITY" | tail -1
cp "$ROOT/build/Greenroom-$NEW.dmg" "$W/feed/"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$ROOT/scripts/appcast.sh" \
  --dmg "$ROOT/build/Greenroom-$NEW.dmg" \
  --previous-dir "$W/prev" \
  --account greenroom \
  --download-url-prefix "http://127.0.0.1:$PORT/" \
  --out "$W/feed"
grep -o '<sparkle:version>[^<]*\|<sparkle:shortVersionString>[^<]*\|sparkle:edSignature="[^"]\{8\}' "$W/feed/appcast.xml" | head -3
DELTA_FILE=$(find "$W/feed" -maxdepth 1 -name '*.delta' | head -1)
[[ -n "$DELTA_FILE" ]] || { echo "FAIL: no .delta file generated"; exit 1; }
DELTA_NAME=$(basename "$DELTA_FILE")
FULL_BYTES=$(stat -f%z "$W/feed/Greenroom-$NEW.dmg")
DELTA_BYTES=$(stat -f%z "$DELTA_FILE")
(( DELTA_BYTES * 100 < FULL_BYTES * 30 )) || { echo "FAIL: delta $DELTA_BYTES is not at least 70% smaller than full DMG $FULL_BYTES"; exit 1; }
(cd "$W/feed" && exec python3 -m http.server --bind 127.0.0.1 "$PORT") > "$W/server.log" 2>&1 &
disown
SERVER=$!
sleep 1

echo "== run $OLD with automatic checks and installs on"
GREENROOM_UPDATE_FEED="http://127.0.0.1:$PORT/appcast.xml" "$W/installed/Greenroom.app/Contents/MacOS/Greenroom" --background \
  -SUHasLaunchedBefore YES -SUEnableAutomaticChecks YES -SUAutomaticallyUpdate YES \
  -SULastCheckTime '<date>2001-01-01T00:00:00Z</date>' > "$W/app.log" 2>&1 &
APP_PID=$!
for _ in $(seq 120); do grep -q "GET /$DELTA_NAME" "$W/server.log" && break; sleep 1; done
grep -q "GET /appcast.xml" "$W/server.log" || { echo "FAIL: the app never asked for the appcast"; cat "$W/app.log" | tail -20; exit 1; }
grep -q "GET /$DELTA_NAME" "$W/server.log" || { echo "FAIL: the app did not download the delta ($DELTA_NAME)"; cat "$W/server.log"; tail -20 "$W/app.log"; exit 1; }
if grep -q "GET /Greenroom-$NEW.dmg" "$W/server.log"; then
  echo "FAIL: the app fell back to downloading the full DMG instead of using the delta"
  cat "$W/server.log"; tail -20 "$W/app.log"; exit 1
fi
echo "downloaded delta ($DELTA_NAME); waiting for Sparkle to verify and stage it"
sleep 20
echo "== quit $OLD: the update installs"
kill -TERM "$APP_PID"; wait "$APP_PID" 2>/dev/null || true; APP_PID=
for _ in $(seq 120); do
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/installed/Greenroom.app/Contents/Info.plist" 2>/dev/null || true)
  [[ "$v" == "$NEW" ]] && break; sleep 1
done
pkill -f "$W/installed/Greenroom.app/Contents/MacOS/Greenroom" 2>/dev/null || true   # a relaunched copy, if any
if [[ "$v" != "$NEW" ]]; then echo "FAIL: the installed app is still $v"; tail -20 "$W/app.log"; exit 1; fi
codesign --verify --deep --strict "$W/installed/Greenroom.app" && echo "PASS: $OLD updated itself to $NEW via delta ($DELTA_NAME), signature intact"
