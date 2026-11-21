#!/bin/bash
# Builds build/Greenroom.app: the Swift app, the apksim engine inside it, everything signed with the hardened runtime.
#   scripts/bundle.sh [--identity NAME|-] [--engine DIR --testapp APK] [--version X.Y.Z] [--variant release|debug] [--check]
# --variant    debug: build/Greenroom Debug.app, a copy to install beside the release: its own name, bundle id, orange
#              icon and window line, its own state folder (Application Support/Greenroom Debug), and no updates
# --identity   a codesign identity; "-" (default) signs ad hoc, for running on this Mac only
# --engine     an unpacked apksim release to bundle instead of the one engine.lock names (with --testapp)
# GREENROOM_BUILD  the build number (CFBundleVersion, which Sparkle compares); the commit count by default
# --check      afterwards, run the bundled training app headless through the app and verify the signatures
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IDENTITY=-; ENGINE=; TESTAPP=; VERSION=0.1.0; CHECK=; VARIANT=release
while [[ $# -gt 0 ]]; do case "$1" in
  --identity) IDENTITY=$2; shift 2 ;;
  --engine) ENGINE=$2; shift 2 ;;
  --testapp) TESTAPP=$2; shift 2 ;;
  --version) VERSION=$2; shift 2 ;;
  --variant) VARIANT=$2; shift 2 ;;
  --check) CHECK=1; shift ;;
  *) echo "unknown option $1" >&2; exit 2 ;;
esac; done
[[ "$VARIANT" == release || "$VARIANT" == debug ]] || { echo "error: --variant is release or debug" >&2; exit 2; }

if [[ -z "$ENGINE" ]]; then
  CACHE=$("$ROOT/scripts/fetch-engine.sh"); ENGINE="$CACHE/tree"; TESTAPP="$CACHE/testapp.apk"
fi
[[ -x "$ENGINE/apksim" && -f "$ENGINE/work/release" ]] || { echo "error: $ENGINE is not an apksim release" >&2; exit 1; }
[[ -f "$TESTAPP" ]] || { echo "error: --testapp APK is required with --engine" >&2; exit 1; }
ENGINE_VERSION=$(tr -d '[:space:]' < "$ENGINE/work/release")

cd "$ROOT"
swift build -c release --arch arm64
if [[ "$VARIANT" == debug ]]; then APP="$ROOT/build/Greenroom Debug.app"; else APP="$ROOT/build/Greenroom.app"; fi; C="$APP/Contents"
rm -rf "$APP"; mkdir -p "$C/MacOS" "$C/Resources"
BIN_PATH=$(swift build -c release --arch arm64 --show-bin-path)
cp "$BIN_PATH/Greenroom" "$C/MacOS/Greenroom"
# Sparkle (in-app updates). Its XPC services are only for sandboxed apps; without them it installs through Autoupdate.
mkdir -p "$C/Frameworks"
ditto "$BIN_PATH/Sparkle.framework" "$C/Frameworks/Sparkle.framework"
rm -rf "$C/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$C/Frameworks/Sparkle.framework/XPCServices"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/${GREENROOM_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}/" \
    -e "s/@ENGINE@/$ENGINE_VERSION/" Resources/Info.plist > "$C/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$C/Resources/"
if [[ "$VARIANT" == debug ]]; then
  # Its own app to macOS (bundle id: preferences, permissions), to the person (name, icon) and to Greenroom (the
  # variant key: the state folder and the title badge). No feed: Sparkle would offer the release in its place.
  PB=/usr/libexec/PlistBuddy
  $PB -c "Set :CFBundleIdentifier io.github.aglose.greenroom.debug" -c "Set :CFBundleName Greenroom Debug" \
      -c "Set :CFBundleDisplayName Greenroom Debug" -c "Add :GreenroomVariant string debug" \
      -c "Delete :SUFeedURL" -c "Delete :SUPublicEDKey" "$C/Info.plist"
  # Opening an .apk or .apkrec by double-click stays the release's: the debug copy only offers itself.
  i=0; while $PB -c "Print :CFBundleDocumentTypes:$i" "$C/Info.plist" >/dev/null 2>&1; do
    $PB -c "Set :CFBundleDocumentTypes:$i:LSHandlerRank Alternate" "$C/Info.plist"; i=$((i+1))
  done
  cp Resources/AppIcon-debug.icns "$C/Resources/AppIcon.icns"
fi
cp -Rc "$ENGINE" "$C/Resources/engine"
cp "$TESTAPP" "$C/Resources/engine-testapp.apk"
cp -R Resources/recipes "$C/Resources/recipes"
chmod -R u+w "$APP"   # a release's JDK files are read-only; signing rewrites them
xattr -cr "$APP"

# Signing, inner to outer. Every Mach-O gets the hardened runtime; only the engine's java gets entitlements
# (JIT, and executable memory for the Android libraries it loads). Library validation stays on with a real
# identity, so the libraries packed inside jars are signed in place too. An ad hoc signature has no team, so
# there library validation has to be off.
SIGN=(codesign --force --sign "$IDENTITY" --options runtime)
JAVA_ENT=Resources/engine-java.entitlements
if [[ "$IDENTITY" == - ]]; then JAVA_ENT=Resources/engine-java.dev.entitlements; else SIGN+=(--timestamp); fi
n=0
for jar in "$C"/Resources/engine/work/lib/*.jar "$C"/Resources/engine/work/*.jar; do
  for entry in $(unzip -Z1 "$jar" 2>/dev/null | grep -E '\.(dylib|jnilib)$' || true); do
    tmp=$(mktemp -d)
    (cd "$tmp" && unzip -q "$jar" "$entry" && "${SIGN[@]}" "$entry" 2>/dev/null && zip -q "$jar" "$entry")
    rm -rf "$tmp"; n=$((n+1))
  done
done
while IFS= read -r f; do
  file -b "$f" | grep -q Mach-O || continue
  if [[ "$f" == */jre/bin/java ]]; then "${SIGN[@]}" --entitlements "$JAVA_ENT" "$f" 2>/dev/null
  else "${SIGN[@]}" "$f" 2>/dev/null; fi
  n=$((n+1))
done < <(find "$C/Resources/engine" -type f \( -perm +111 -o -name '*.dylib' -o -name '*.jnilib' \))
# Sparkle's nested programs, then the framework (its own order, per Sparkle's documentation).
SP="$C/Frameworks/Sparkle.framework"
for f in "$SP/Versions/B/Autoupdate" "$SP/Versions/B/Updater.app" "$SP"; do "${SIGN[@]}" "$f" 2>/dev/null; n=$((n+1)); done
# The app itself: no entitlements with a real identity. Ad hoc, library validation off (greenroom.dev.entitlements):
# an ad hoc signature has no team, so validation would refuse the app's own Sparkle.framework. (No comments inside
# an entitlements file: AMFI's parser refuses them.) Errors show: a failure here stops the script.
if [[ "$IDENTITY" == - ]]; then "${SIGN[@]}" --entitlements Resources/greenroom.dev.entitlements "$APP"
else "${SIGN[@]}" "$APP"; fi
echo "signed $n binaries and the app as: $IDENTITY"
echo "$APP ($(du -sh "$APP" | cut -f1)), engine $ENGINE_VERSION"

if [[ -n "$CHECK" ]]; then
  codesign --verify --deep --strict "$APP" && echo "signature: ok"
  unsigned=$(find "$APP" -type f \( -perm +111 -o -name '*.dylib' \) -exec sh -c 'file -b "$1" | grep -q Mach-O && ! codesign -dv "$1" 2>&1 | grep -q "flags=.*runtime" && echo "$1"' _ {} \;)
  [[ -z "$unsigned" ]] || { echo "error: not signed with the hardened runtime:"; echo "$unsigned"; exit 1; }
  "$C/MacOS/Greenroom" --smoke "$C/Resources/engine-testapp.apk" | tail -3
  # The workbench's path: the screen streamed to the app as H.264 and decoded, input over the control channel.
  "$C/MacOS/Greenroom" --smoke-stream "$C/Resources/engine-testapp.apk" | tail -3
  # The agent interface, as an agent uses it.
  CONNECT_DIR=; PLAIN_STATE=
  trap 'rm -rf "$CONNECT_DIR" "$PLAIN_STATE"' EXIT   # the temporary folders go on failure too
  # (A state folder of its own: another copy of the app on this Mac must not be met halfway through.)
  PLAIN_STATE=$(mktemp -d /tmp/grplain.XXXXXX)
  GREENROOM_STATE="$PLAIN_STATE" "$ROOT/scripts/mcp-check.py" "$C/MacOS/Greenroom" "$C/Resources/engine-testapp.apk"
  # Connect Claude Code, against a stand-in claude (the real one is never run).
  CONNECT_DIR=$(mktemp -d /tmp/grconnect.XXXXXX)
  "$C/MacOS/Greenroom" --connect-check "$CONNECT_DIR" | tail -3
  # The agent tied to its worktree's session: two worktrees, a state folder of its own.
  "$ROOT/scripts/mcp-check.py" "$C/MacOS/Greenroom" "$C/Resources/engine-testapp.apk" --sessions
  # The Claude Code plugin: its manifests, and its launcher script serving MCP through this app.
  "$ROOT/scripts/plugin-check.py" "$APP"
fi
