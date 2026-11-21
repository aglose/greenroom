#!/bin/bash
# Greenroom recipe "local": builds the worktree as it is (uncommitted changes included) with its own Gradle wrapper,
# then copies the newest APK of the module's outputs for the variant to $GREENROOM_OUT.
#
# Given in the environment: GREENROOM_WORKTREE, GREENROOM_MODULE (empty: the application module is found),
# GREENROOM_VARIANT (debug), GREENROOM_OUT. Needs the JDK and Android SDK you build with anyway (JAVA_HOME and
# ANDROID_HOME, from your login shell). Copy this file, change it, and choose it with "Custom...".
set -eu
cd "${GREENROOM_WORKTREE:?GREENROOM_WORKTREE is not set}"
out="${GREENROOM_OUT:?GREENROOM_OUT is not set}"
variant="${GREENROOM_VARIANT:-debug}"
module="${GREENROOM_MODULE:-}"

# The application module: a folder whose build file applies com.android.application (module names are the folder
# names; nested modules are found one or two levels down).
if [ -z "$module" ]; then
  found=()
  while IFS= read -r f; do
    dir=$(dirname "$f")
    [ "$dir" = "." ] && continue
    found+=("${dir#./}")
  done < <(find . -maxdepth 3 \( -name build.gradle -o -name build.gradle.kts \) -not -path '*/build/*' -not -path '*/node_modules/*' \
             -exec grep -lE 'com\.android\.application|android\.application' {} + 2>/dev/null | sort)
  if [ "${#found[@]}" -eq 0 ]; then
    echo "error: no Android application module found (no build.gradle applies com.android.application). Set the module in the workspace's settings." >&2
    exit 2
  fi
  if [ "${#found[@]}" -gt 1 ]; then
    echo "error: several application modules found: ${found[*]}. Set the module in the workspace's settings." >&2
    exit 2
  fi
  module="${found[0]}"
  echo "application module: $module"
fi
path="${module//:/\/}"        # ":app" or "app" or ":feature:app" -> folder
path="${path#/}"
gradle_path=":${module#:}"
gradle_path="${gradle_path//\//:}"

# assembleDebug, assembleRelease, or assemble<Flavor><Type>: the first letter capitalised.
task="assemble$(printf '%s' "${variant:0:1}" | tr '[:lower:]' '[:upper:]')${variant:1}"
[ -x ./gradlew ] || { echo "error: no executable ./gradlew in $GREENROOM_WORKTREE" >&2; exit 2; }
echo "+ ./gradlew ${gradle_path}:${task}"
./gradlew "${gradle_path}:${task}" --console=plain

# Gradle's outputs: <module>/build/outputs/apk/<flavor>/<type>/*.apk (or apk/<type>/ without flavors). The newest
# file of the variant's folders wins; test and unaligned APKs do not count.
lower="$(printf '%s' "$variant" | tr '[:upper:]' '[:lower:]')"
newest=""
while IFS= read -r f; do
  case "$f" in *androidTest*|*unaligned*) continue ;; esac
  # The variant's words appear in the path under outputs/apk (debug, or free/debug for freeDebug).
  p="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  flat="${p#*/outputs/apk/}"
  flat="${flat//\//}"
  case "$flat" in *"$lower"*) ;; *) continue ;; esac
  if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
done < <(find "$path/build/outputs/apk" -name '*.apk' 2>/dev/null)

if [ -z "$newest" ]; then
  echo "error: no APK for variant '$variant' under $path/build/outputs/apk after the build" >&2
  exit 3
fi
mkdir -p "$(dirname "$out")"
cp "$newest" "$out"
echo "built $newest"
