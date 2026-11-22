#!/bin/bash
# Symbolicates crash frame offsets (e.g. 0x1a2b3) from a Greenroom crash report using a matching .dSYM.
#
#   scripts/symbolicate.sh PATH_TO_DSYM_OR_ZIP 0x1a2b3 [0x4c5d6 ...]
#   scripts/symbolicate.sh --release v0.2.0 0x1a2b3 [0x4c5d6 ...]
#
# Greenroom's crash handler records each frame as (return_address - image_header), i.e. an offset
# from the Mach-O __TEXT segment's vmaddr (0x100000000 on arm64). Passing `-l 0x0` to `atos`
# resolves offsets directly against the DWARF symbols in the .dSYM.
set -euo pipefail

usage() {
  echo "usage: scripts/symbolicate.sh (PATH.dSYM | PATH.dSYM.zip | --release vX.Y.Z) 0xOFFSET ..." >&2
  exit 2
}

[[ $# -ge 2 ]] || usage

TMP=
cleanup() { [[ -n "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

if [[ "$1" == "--release" ]]; then
  [[ $# -ge 3 ]] || usage
  TAG=$2; shift 2
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-dsym.XXXXXX")
  gh release download "$TAG" --pattern '*.dSYM.zip' --dir "$TMP" >/dev/null
  ZIP=$(find "$TMP" -name '*.dSYM.zip' -print -quit)
  [[ -n "$ZIP" ]] || { echo "error: no .dSYM.zip asset found on release $TAG" >&2; exit 1; }
  TARGET="$ZIP"
else
  TARGET=$1; shift
fi

if [[ "$TARGET" == *.zip ]]; then
  [[ -n "$TMP" ]] || TMP=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-dsym.XXXXXX")
  unzip -q "$TARGET" -d "$TMP/unpacked"
  DSYM=$(find "$TMP/unpacked" -not -path '*/__MACOSX/*' -name '*.dSYM' -type d -print -quit)
  [[ -n "$DSYM" ]] || { echo "error: no .dSYM bundle inside $TARGET" >&2; exit 1; }
else
  DSYM="$TARGET"
fi

if [[ -d "$DSYM/Contents/Resources/DWARF" ]]; then
  DWARF=$(find "$DSYM/Contents/Resources/DWARF" -maxdepth 1 -type f -not -name '._*' -print -quit)
else
  DWARF="$DSYM"
fi
[[ -f "$DWARF" ]] || { echo "error: DWARF binary not found under $DSYM" >&2; exit 1; }

# Determine the Mach-O __TEXT vmaddr (0x100000000 for arm64 executables) and add each offset.
BASE_HEX=$(otool -l "$DWARF" | awk '/segname __TEXT/{f=1} f && /vmaddr/{print $2; exit}')
[[ -n "$BASE_HEX" ]] || BASE_HEX=0x100000000

ADDRS=()
for off in "$@"; do
  clean=${off#+}
  [[ "$clean" =~ ^0x[0-9a-fA-F]+$ ]] || { echo "error: expected hex offset like 0x1a2b3, got: $off" >&2; exit 2; }
  ADDRS+=("$(printf '0x%x' "$(( BASE_HEX + clean ))")")
done

xcrun atos -arch arm64 -o "$DWARF" -l "$BASE_HEX" "${ADDRS[@]}"
