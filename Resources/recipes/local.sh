#!/bin/bash
# Greenroom recipe "local": builds the worktree as it is (uncommitted changes included) with its own Gradle wrapper,
# then copies the variant's APK to $GREENROOM_OUT.
#
# Given in the environment: GREENROOM_WORKTREE, GREENROOM_MODULE (empty: the application module is found),
# GREENROOM_VARIANT (debug), GREENROOM_OUT. Needs the JDK and Android SDK you build with anyway (JAVA_HOME and
# ANDROID_HOME, from your login shell). Copy this file, change it, and choose it with "Custom...".
#
# Which APK: the Android Gradle plugin writes output-metadata.json next to each variant's APKs, naming the variant
# and its files. This recipe reads it: the variant named GREENROOM_VARIANT, and in it the universal APK, else the
# arm64-v8a one, else the only one. Without that file (an older plugin) it falls back to the newest APK of the
# variant's folder that this run wrote. Several candidates are never guessed at: it stops and says which.
set -eu
cd "${GREENROOM_WORKTREE:?GREENROOM_WORKTREE is not set}"
out="${GREENROOM_OUT:?GREENROOM_OUT is not set}"
variant="${GREENROOM_VARIANT:-debug}"
module="${GREENROOM_MODULE:-}"

stamp="$(mktemp -t greenroom-local)"
trap 'rm -f "$stamp"' EXIT

# The application module: a build file that applies the Android application plugin, spelled any of the usual
# ways ('com.android.application', alias(libs.plugins.android.application), libs.plugins.androidApplication).
# Supports standard Gradle modules (":app", ":samples:demo") and composite sub-projects ("consumer/:app").
project_dir="."
if [ -z "$module" ]; then
  found=()
  while IFS= read -r f; do
    if grep -vE 'apply[[:space:]]+false' "$f" | grep -qE 'android[._-]?[Aa]pplication|applicationId[[:space:]]*(=|[[:space:]]+["'"'"'])'; then
      dir=$(dirname "$f")
      found+=("${dir#./}")
    fi
  done < <(find . -maxdepth 4 \( -name build.gradle -o -name build.gradle.kts \) \
             -not -path '*/build/*' -not -path '*/build-logic/*' -not -path '*/buildSrc/*' \
             -not -path '*/node_modules/*' -not -path '*/src/*' \
             -not -path '*/.git/*' -not -path '*/.gradle/*' -not -path '*/Pods/*' 2>/dev/null | sort)
  if [ "${#found[@]}" -eq 0 ]; then
    echo "error: no Android application module found (no build file applies the Android application plugin). Choose an Android app in the repository header or Settings > Build Recipes." >&2
    exit 2
  fi
  if [ "${#found[@]}" -gt 1 ]; then
    echo "error: several application modules found: ${found[*]}. Choose which Android app to build from the repository header or Settings > Build Recipes." >&2
    exit 2
  fi
  module="${found[0]}"
  echo "application module: $module"
fi

# Split composite spec "subproject/:app" into project_dir="subproject" and module=":app".
case "$module" in
  */:*)
    project_dir="${module%%/:*}"
    module=":${module#*/:}"
    ;;
esac

if [ "$project_dir" != "." ]; then
  [ -d "$project_dir" ] || { echo "error: project directory '$project_dir' does not exist in $GREENROOM_WORKTREE" >&2; exit 2; }
  cd "$project_dir"
fi

if [ "$module" = "." ] || [ "$module" = ":" ]; then
  path="."
  gradle_prefix=""
else
  path="$(printf '%s' "$module" | tr ':' '/')"        # ":app" or "app" or ":feature:app" -> folder
  path="${path#/}"
  # If ./gradlew is not at the current directory, walk up from $path to find the nearest composite gradlew.
  if [ ! -x ./gradlew ] && [ -d "$path" ]; then
    probe="$path"
    while [ "$probe" != "." ] && [ -n "$probe" ]; do
      if [ -x "$probe/gradlew" ]; then
        rel="${path#"$probe"}"
        rel="${rel#/}"
        cd "$probe"
        path="${rel:-.}"
        break
      fi
      next="$(dirname "$probe")"
      [ "$next" = "$probe" ] && break
      probe="$next"
    done
  fi
  if [ "$path" = "." ]; then
    gradle_prefix=""
  else
    gradle_prefix=":$(printf '%s' "$path" | tr '/' ':')"
  fi
fi

# assembleDebug, assembleRelease, or assemble<Flavor><Type>: the first letter capitalised.
task="assemble$(printf '%s' "${variant:0:1}" | tr '[:lower:]' '[:upper:]')${variant:1}"
[ -x ./gradlew ] || { echo "error: no executable ./gradlew in $(pwd)" >&2; exit 2; }
echo "+ ./gradlew ${gradle_prefix}:${task}"
touch "$stamp"                  # APKs not newer than this were not written by this run
./gradlew "${gradle_prefix}:${task}" --console=plain

apks="$path/build/outputs/apk"
lower="$(printf '%s' "$variant" | tr '[:upper:]' '[:lower:]')"
choice=""

# 1. output-metadata.json: variantName, and the files of the variant.
exact=(); suffix=()
while IFS= read -r meta; do
  name="$(plutil -extract variantName raw -o - "$meta" 2>/dev/null || true)"
  [ -n "$name" ] || continue
  lname="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  if [ "$lname" = "$lower" ]; then exact+=("$meta"); 
  else case "$lname" in *"$lower") suffix+=("$meta") ;; esac; fi
done < <(find "$apks" -name output-metadata.json 2>/dev/null | sort)

metas=("${exact[@]+"${exact[@]}"}")
[ "${#metas[@]}" -eq 0 ] && metas=("${suffix[@]+"${suffix[@]}"}")
if [ "${#metas[@]}" -gt 1 ]; then
  names=""
  for m in "${metas[@]}"; do names="$names $(plutil -extract variantName raw -o - "$m")"; done
  echo "error: the variant '$variant' matches several builds:$names. Set the variant in the workspace's settings (variant) to one of them." >&2
  exit 3
fi

if [ "${#metas[@]}" -eq 1 ]; then
  meta="${metas[0]}"; dir="$(dirname "$meta")"
  n="$(plutil -extract elements raw -o - "$meta" 2>/dev/null || echo 0)"
  files=(); universal=""; arm=""
  i=0
  while [ "$i" -lt "$n" ]; do
    f="$(plutil -extract "elements.$i.outputFile" raw -o - "$meta" 2>/dev/null || true)"
    t="$(plutil -extract "elements.$i.outputType.type" raw -o - "$meta" 2>/dev/null || true)"
    abi="$(plutil -extract "elements.$i.filters.0.value" raw -o - "$meta" 2>/dev/null || true)"
    if [ -n "$f" ] && [ -f "$dir/$f" ]; then
      files+=("$f")
      [ "$t" = "UNIVERSAL" ] && [ -z "$universal" ] && universal="$f"
      [ "$abi" = "arm64-v8a" ] && [ -z "$arm" ] && arm="$f"
    fi
    i=$((i + 1))
  done
  if [ -n "$universal" ]; then choice="$dir/$universal"
  elif [ -n "$arm" ]; then choice="$dir/$arm"
  elif [ "${#files[@]}" -eq 1 ]; then choice="$dir/${files[0]}"
  elif [ "${#files[@]}" -eq 0 ]; then
    echo "error: $meta lists no APK that exists" >&2; exit 3
  else
    echo "error: the build made several APKs and none is universal or arm64-v8a: ${files[*]}. Build a single one (or write a recipe that picks)." >&2
    exit 3
  fi
else
  # 2. No metadata: the newest APK of the variant's folders written by this run. Several folders match: say which.
  cands=(); folders=""
  while IFS= read -r f; do
    case "$f" in *androidTest*|*unaligned*) continue ;; esac
    p="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
    flat="${p#*/outputs/apk/}"; flat="${flat//\//}"
    case "$flat" in *"$lower"*) ;; *) continue ;; esac
    [ -n "$(find "$f" -newer "$stamp")" ] || continue     # find compares to the nanosecond; bash 3.2's -nt does not
    cands+=("$f")
    d="$(dirname "$f")"; case " $folders " in *" ${d#"$apks"/} "*) ;; *) folders="$folders ${d#"$apks"/}" ;; esac
  done < <(find "$apks" -name '*.apk' 2>/dev/null | sort)
  if [ "${#cands[@]}" -eq 0 ]; then
    echo "error: no APK for variant '$variant' under $apks written by this build" >&2; exit 3
  fi
  if [ "$(printf '%s\n' $folders | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "error: the variant '$variant' made APKs in several folders:$folders. Set the variant in the workspace's settings (variant) to one of them." >&2
    exit 3
  fi
  for f in "${cands[@]}"; do
    if [ -z "$choice" ] || [ -n "$(find "$f" -newer "$choice")" ]; then choice="$f"; fi
  done
fi

mkdir -p "$(dirname "$out")"
cp "$choice" "$out"
echo "built $choice"
