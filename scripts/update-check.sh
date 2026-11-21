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
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
W=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-update.XXXXXX")
mkdir -p "$W/installed" "$W/feed"
SERVER=; APP_PID=
trap '[[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null; [[ -n "$SERVER" ]] && kill "$SERVER" 2>/dev/null; true' EXIT

echo "== build $OLD and install it"
"$ROOT/scripts/bundle.sh" --identity "$IDENTITY" --version "$OLD" | tail -1
ditto "$ROOT/build/Greenroom.app" "$W/installed/Greenroom.app"
echo "== build $NEW as a disk image, and an appcast for it"
"$ROOT/scripts/bundle.sh" --identity "$IDENTITY" --version "$NEW" | tail -1
"$ROOT/scripts/dmg.sh" --identity "$IDENTITY" | tail -1
cp "$ROOT/build/Greenroom-$NEW.dmg" "$W/feed/"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$SPARKLE/generate_appcast" --account greenroom --download-url-prefix "http://127.0.0.1:$PORT/" "$W/feed" >/dev/null
grep -o 'sparkle:version="[^"]*"\|sparkle:shortVersionString>[^<]*\|sparkle:edSignature="[^"]\{8\}' "$W/feed/appcast.xml" | head -3
(cd "$W/feed" && exec python3 -m http.server --bind 127.0.0.1 "$PORT") > "$W/server.log" 2>&1 &
SERVER=$!
sleep 1

echo "== run $OLD with automatic checks and installs on"
GREENROOM_UPDATE_FEED="http://127.0.0.1:$PORT/appcast.xml" "$W/installed/Greenroom.app/Contents/MacOS/Greenroom" --background \
  -SUHasLaunchedBefore YES -SUEnableAutomaticChecks YES -SUAutomaticallyUpdate YES > "$W/app.log" 2>&1 &
APP_PID=$!
for _ in $(seq 120); do grep -q "GET /Greenroom-$NEW.dmg" "$W/server.log" && break; sleep 1; done
grep -q "GET /appcast.xml" "$W/server.log" || { echo "FAIL: the app never asked for the appcast"; cat "$W/app.log" | tail -20; exit 1; }
grep -q "GET /Greenroom-$NEW.dmg" "$W/server.log" || { echo "FAIL: the app did not download the update"; tail -20 "$W/app.log"; exit 1; }
echo "downloaded; waiting for Sparkle to verify and stage it"
sleep 20
echo "== quit $OLD: the update installs"
kill -TERM "$APP_PID"; wait "$APP_PID" 2>/dev/null || true; APP_PID=
for _ in $(seq 120); do
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/installed/Greenroom.app/Contents/Info.plist" 2>/dev/null || true)
  [[ "$v" == "$NEW" ]] && break; sleep 1
done
pkill -f "$W/installed/Greenroom.app/Contents/MacOS/Greenroom" 2>/dev/null || true   # a relaunched copy, if any
if [[ "$v" != "$NEW" ]]; then echo "FAIL: the installed app is still $v"; tail -20 "$W/app.log"; exit 1; fi
codesign --verify --deep --strict "$W/installed/Greenroom.app" && echo "PASS: $OLD updated itself to $NEW, signature intact"
rm -rf "$W"
