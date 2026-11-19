#!/bin/bash
# Downloads the apksim release named in engine.lock into build/engine-cache and checks both files against the
# hashes there. Prints the folder of the unpacked engine. Nothing is used unless its hash matches.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/engine.lock"
CACHE="$ROOT/build/engine-cache/$VERSION"
BASE="${GREENROOM_ENGINE_URL:-https://github.com/aglose/apksim/releases/download/v$VERSION}"
TAR="apksim-$VERSION-macos-arm64.tar.gz"; APK="apksim-testapp-$VERSION.apk"
mkdir -p "$CACHE"

fetch() { # NAME SHA256
  local f="$CACHE/$1"
  if [[ ! -f "$f" ]] || [[ "$(shasum -a 256 "$f" | cut -d' ' -f1)" != "$2" ]]; then
    echo "fetching $1" >&2
    curl -fL --retry 3 -o "$f.part" "$BASE/$1" >&2
    mv "$f.part" "$f"
  fi
  local got; got=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [[ "$got" == "$2" ]] || { echo "error: $1 has SHA-256 $got, engine.lock says $2" >&2; rm -f "$f"; exit 1; }
}
fetch "$TAR" "$ENGINE_SHA256"
fetch "$APK" "$TESTAPP_SHA256"

if [[ ! -x "$CACHE/tree/apksim" ]]; then
  rm -rf "$CACHE/tree" "$CACHE/unpack"; mkdir -p "$CACHE/unpack"
  tar -xzf "$CACHE/$TAR" -C "$CACHE/unpack"
  mv "$CACHE/unpack"/*/ "$CACHE/tree"; rmdir "$CACHE/unpack"
fi
cp -f "$CACHE/$APK" "$CACHE/testapp.apk"
echo "$CACHE"
