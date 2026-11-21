#!/bin/bash
# Builds build/Greenroom.app: the Swift app, the apksim engine inside it, everything signed with the hardened runtime.
#   scripts/bundle.sh [--identity NAME|-] [--engine DIR --testapp APK] [--version X.Y.Z] [--check]
# --identity   a codesign identity; "-" (default) signs ad hoc, for running on this Mac only
# --engine     an unpacked apksim release to bundle instead of the one engine.lock names (with --testapp)
# GREENROOM_BUILD  the build number (CFBundleVersion, which Sparkle compares); the commit count by default
# --check      afterwards, run the bundled training app headless through the app and verify the signatures
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IDENTITY=-; ENGINE=; TESTAPP=; VERSION=0.1.0; CHECK=
while [[ $# -gt 0 ]]; do case "$1" in
  --identity) IDENTITY=$2; shift 2 ;;
  --engine) ENGINE=$2; shift 2 ;;
  --testapp) TESTAPP=$2; shift 2 ;;
  --version) VERSION=$2; shift 2 ;;
  --check) CHECK=1; shift ;;
  *) echo "unknown option $1" >&2; exit 2 ;;
esac; done

if [[ -z "$ENGINE" ]]; then
  CACHE=$("$ROOT/scripts/fetch-engine.sh"); ENGINE="$CACHE/tree"; TESTAPP="$CACHE/testapp.apk"
fi
[[ -x "$ENGINE/apksim" && -f "$ENGINE/work/release" ]] || { echo "error: $ENGINE is not an apksim release" >&2; exit 1; }
[[ -f "$TESTAPP" ]] || { echo "error: --testapp APK is required with --engine" >&2; exit 1; }
ENGINE_VERSION=$(tr -d '[:space:]' < "$ENGINE/work/release")

cd "$ROOT"
swift build -c release --arch arm64
APP="$ROOT/build/Greenroom.app"; C="$APP/Contents"
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
  "$ROOT/scripts/mcp-check.py" "$C/MacOS/Greenroom" "$C/Resources/engine-testapp.apk"
  # The agent tied to its worktree's session: two worktrees, a state folder of its own.
  "$ROOT/scripts/mcp-check.py" "$C/MacOS/Greenroom" "$C/Resources/engine-testapp.apk" --sessions
fi
