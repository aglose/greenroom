#!/bin/bash
# Generates appcast.xml and Sparkle binary .delta updates from a newly built DMG and previous releases.
#
#   scripts/appcast.sh --dmg PATH --download-url-prefix URL [options]
#
# Options:
#   --dmg PATH                  newly built Greenroom-VERSION.dmg (required)
#   --download-url-prefix URL   base URL where the DMG and .delta files will be hosted (required)
#   --out DIR                   output directory for appcast.xml and *.delta (default: build/appcast)
#   --previous-dir DIR          local directory of previous Greenroom-*.dmg files to diff against
#   --fetch-previous N          download the last N published GitHub releases' DMGs to diff against (default: 0)
#   --repo OWNER/NAME           GitHub repo for --fetch-previous (default: aglose/greenroom)
#   --exclude-tag TAG           release tag to skip when fetching previous releases
#   --max-deltas N              maximum number of delta updates to generate (default: 5)
#   --ed-key-file PATH          EdDSA private key file, or "-" to read from stdin
#   --account NAME              keychain account for the EdDSA private key (local runs)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

DMG=; PREFIX=; OUT="$ROOT/build/appcast"
PREVIOUS_DIR=; FETCH_PREVIOUS=0; REPO="aglose/greenroom"; EXCLUDE_TAG=
MAX_DELTAS=5; ED_KEY_FILE=; ACCOUNT=

while [[ $# -gt 0 ]]; do case "$1" in
  --dmg) DMG=$2; shift 2 ;;
  --download-url-prefix) PREFIX=$2; shift 2 ;;
  --out) OUT=$2; shift 2 ;;
  --previous-dir) PREVIOUS_DIR=$2; shift 2 ;;
  --fetch-previous) FETCH_PREVIOUS=$2; shift 2 ;;
  --repo) REPO=$2; shift 2 ;;
  --exclude-tag) EXCLUDE_TAG=$2; shift 2 ;;
  --max-deltas) MAX_DELTAS=$2; shift 2 ;;
  --ed-key-file) ED_KEY_FILE=$2; shift 2 ;;
  --account) ACCOUNT=$2; shift 2 ;;
  *) echo "unknown option $1" >&2; exit 2 ;;
esac; done

[[ -n "$DMG" && -f "$DMG" ]] || { echo "error: --dmg PATH is required and must exist" >&2; exit 2; }
[[ -n "$PREFIX" ]] || { echo "error: --download-url-prefix URL is required" >&2; exit 2; }
[[ -x "$SPARKLE/generate_appcast" ]] || { echo "error: $SPARKLE/generate_appcast not found (run swift build first)" >&2; exit 1; }
[[ "$PREFIX" == */ ]] || PREFIX="$PREFIX/"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-appcast.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

FEED="$WORK/feed"
mkdir -p "$FEED"

# Capture piped key before any subcommand (such as gh) can touch stdin.
KEY_ARGS=()
if [[ -n "$ED_KEY_FILE" ]]; then
  if [[ "$ED_KEY_FILE" == - ]]; then
    KEY_TMP="$WORK/ed.key"
    (umask 077 && cat > "$KEY_TMP")
    [[ -s "$KEY_TMP" ]] || { echo "error: empty EdDSA key on stdin" >&2; exit 1; }
    KEY_ARGS=(--ed-key-file "$KEY_TMP")
  else
    KEY_ARGS=(--ed-key-file "$ED_KEY_FILE")
  fi
elif [[ -n "$ACCOUNT" ]]; then
  KEY_ARGS=(--account "$ACCOUNT")
fi

copy_dmg() { # SRC DST
  cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"
}

DMG_NAME=$(basename "$DMG")
copy_dmg "$DMG" "$FEED/$DMG_NAME"

shopt -s nullglob
if [[ -n "$PREVIOUS_DIR" && -d "$PREVIOUS_DIR" ]]; then
  for prev in "$PREVIOUS_DIR"/*.dmg; do
    base=$(basename "$prev")
    [[ "$base" == "$DMG_NAME" ]] && continue
    copy_dmg "$prev" "$FEED/$base"
  done
fi

if (( FETCH_PREVIOUS > 0 )); then
  if ! command -v gh >/dev/null 2>&1; then
    echo "warning: gh not installed; skipping previous release fetch for delta updates" >&2
  else
    fetched=0
    tags=$(gh release list --repo "$REPO" --limit $((FETCH_PREVIOUS + 10)) \
      --json tagName,isDraft,isPrerelease \
      -q '.[] | select(.isDraft == false and .isPrerelease == false) | .tagName' </dev/null 2>/dev/null || true)
    while IFS= read -r tag; do
      [[ -z "$tag" || "$tag" == "$EXCLUDE_TAG" ]] && continue
      (( fetched >= FETCH_PREVIOUS )) && break
      echo "fetching previous release $tag for delta generation..." >&2
      if gh release download "$tag" --repo "$REPO" --pattern "Greenroom-*.dmg" --dir "$FEED" --skip-existing </dev/null 2>&1 >&2; then
        fetched=$((fetched + 1))
      else
        echo "warning: could not download DMG for $tag; skipping" >&2
      fi
    done <<< "$tags"
  fi
fi

"$SPARKLE/generate_appcast" \
  "${KEY_ARGS[@]}" \
  --maximum-versions 1 \
  --maximum-deltas "$MAX_DELTAS" \
  --download-url-prefix "$PREFIX" \
  "$FEED"

[[ -f "$FEED/appcast.xml" ]] || { echo "error: generate_appcast did not produce appcast.xml" >&2; exit 1; }
grep -q 'sparkle:edSignature=' "$FEED/appcast.xml" || { echo "error: appcast.xml is missing sparkle:edSignature" >&2; exit 1; }
grep -Fq "$DMG_NAME" "$FEED/appcast.xml" || { echo "error: appcast.xml does not contain $DMG_NAME (is a previous release newer?)" >&2; exit 1; }

# Verify every delta referenced in appcast.xml exists in $FEED.
while IFS= read -r delta_name; do
  [[ -z "$delta_name" ]] && continue
  [[ -f "$FEED/$delta_name" ]] || { echo "error: appcast.xml references missing delta $delta_name" >&2; exit 1; }
done < <(grep -oE '[^/"'\'']+\.delta' "$FEED/appcast.xml" | sort -u || true)

mkdir -p "$OUT"
rm -f "$OUT/appcast.xml" "$OUT"/*.delta
cp "$FEED/appcast.xml" "$OUT/appcast.xml"

full_bytes=$(stat -f%z "$DMG")
printf 'full:  %s (%.1f MB)\n' "$DMG_NAME" "$(awk -v b="$full_bytes" 'BEGIN { print b / 1048576 }')"
for delta in "$FEED"/*.delta; do
  cp "$delta" "$OUT/$(basename "$delta")"
  delta_bytes=$(stat -f%z "$delta")
  pct=$(awk -v f="$full_bytes" -v d="$delta_bytes" 'BEGIN { printf "%.1f", (1 - d / f) * 100 }')
  printf 'delta: %s (%.2f MB, -%s%%)\n' "$(basename "$delta")" "$(awk -v b="$delta_bytes" 'BEGIN { print b / 1048576 }')" "$pct"
done

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  rm -rf "$HOME/Library/Caches/Sparkle_generate_appcast"
fi
