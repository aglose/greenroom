#!/bin/bash
# Greenroom recipe "remote": builds the worktree as it is (uncommitted changes included) in a boat.dev sandbox of
# YOUR account, with the boat CLI and its own sign-in (the CLI's key, or BOAT_API_KEY). It UPLOADS THIS
# REPOSITORY'S SOURCE CODE to that sandbox: Greenroom asks you once per repository before this ever runs, and the
# script refuses to run without that yes (GREENROOM_REMOTE_CONSENT=1, set by Greenroom from your answer).
#
# Given in the environment: GREENROOM_WORKTREE, GREENROOM_MODULE (empty: the application module is found),
# GREENROOM_VARIANT, GREENROOM_OUT, and the workspace's settings:
#   GREENROOM_REMOTE_SANDBOX  an existing sandbox's id: resumed for each build and stopped (not deleted) after it,
#                             so Gradle's caches stay and the next build is incremental.
#   GREENROOM_REMOTE_TEMPLATE a snapshot to create a sandbox from when there is no sandbox id. The new id is
#                             printed: put it in the sandbox setting to keep it.
# "Prepare remote builder" in Greenroom shows how to make the template (a JDK, the Android SDK).
#
# What is uploaded: `git archive HEAD` (the committed tree: files marked export-ignore in .gitattributes are left
# out), `git diff HEAD --binary` (every uncommitted change to tracked files, deletions too) and the untracked files
# that .gitignore does not ignore. Ignored files (build output, local.properties, secrets in ignored files) stay.
# The sandbox is stopped when the script ends, whether it built, failed or was cancelled.
set -eu

# ---------------------------------------------------------------------------------------------------------------
# The boat CLI. Every call to it is in these functions. They were written from the CLI's documentation and have NOT
# been run against the real service: if its syntax differs, correct them here and nowhere else.
#   boat new, boat exec ID --cwd DIR "cmd" (30 s timeout unless --detach), boat scp SRC ID:/home/user/..., boat stop
#   are as documented; `--snapshot`, `boat start`, the id printed by `boat new` and `ID:PATH` for scp are guesses.
boat_new()           { boat new --snapshot "$1" | tail -n 1 | awk '{ print $NF }'; }   # prints the new sandbox's id
boat_start()         { boat start "$1"; }                                               # resume a stopped sandbox
boat_stop()          { boat stop "$1"; }
boat_exec()          { local id="$1" cwd="$2"; shift 2; boat exec "$id" --cwd "$cwd" "$@"; }
boat_exec_detached() { local id="$1" cwd="$2"; shift 2; boat exec "$id" --detach --cwd "$cwd" "$@"; }
boat_put()           { boat scp "$1" "$2:$3"; }                                         # LOCAL ID REMOTE_PATH
boat_get()           { boat scp "$1:$2" "$3"; }                                         # ID REMOTE_PATH LOCAL
# ---------------------------------------------------------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }

[ "${GREENROOM_REMOTE_CONSENT:-0}" = 1 ] || die "the remote recipe uploads this repository's source code to your own boat.dev account, and you have not allowed that for this repository. Choose Build with > remote in Greenroom, read what it uploads, and say yes."
command -v boat >/dev/null 2>&1 || die "the remote recipe needs the boat CLI and it is not installed (or not on the PATH Greenroom takes from your login shell). Install it and sign in, or use another recipe."
cd "${GREENROOM_WORKTREE:?GREENROOM_WORKTREE is not set}"
out="${GREENROOM_OUT:?GREENROOM_OUT is not set}"
module="${GREENROOM_MODULE:-}"
variant="${GREENROOM_VARIANT:-debug}"
sandbox="${GREENROOM_REMOTE_SANDBOX:-}"
template="${GREENROOM_REMOTE_TEMPLATE:-}"
poll="${GREENROOM_REMOTE_POLL:-5}"
[ -n "$sandbox$template" ] || die "no sandbox is set. Put a sandbox id (or a template snapshot to create one from) in the workspace's settings; Prepare remote builder in Greenroom shows how to make one."
git rev-parse --verify HEAD >/dev/null 2>&1 || die "this worktree has no commit yet: the remote recipe uploads HEAD and your changes on top of it"

home=/home/user
wd="$home/greenroom"
tmp="$(mktemp -d -t greenroom-remote)"
sid=""
stopped=0

# The sandbox is stopped on every way out. The stop runs in a session of its own: a cancel signals this whole
# process group and kills it two seconds later, and a stop that is still talking to boat must survive that.
stop_sandbox() {
  [ -n "$sid" ] && [ "$stopped" = 0 ] || return 0
  stopped=1
  echo "stopping sandbox $sid"
  local rc=0
  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash -c "$(declare -f boat_stop); boat_stop \"\$1\"" _ "$sid" >/dev/null 2>&1 &
    wait $! || rc=$?
  else
    boat_stop "$sid" >/dev/null 2>&1 || rc=$?
  fi
  [ "$rc" = 0 ] || echo "warning: could not stop sandbox $sid. Stop it yourself (boat stop $sid): it may still be running and billing."
}
cleanup() { stop_sandbox; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 1. The sandbox: resumed, or made from the template.
if [ -n "$sandbox" ]; then
  sid="$sandbox"
  echo "resuming sandbox $sid"
  boat_start "$sid" || die "boat could not resume the sandbox $sid. Is boat signed in (boat login, or BOAT_API_KEY), and is the id in the workspace's settings right?"
else
  echo "creating a sandbox from the template $template"
  new="$(boat_new "$template")" || die "boat could not create a sandbox from the template $template. Is boat signed in (boat login, or BOAT_API_KEY), and is the template right?"
  [ -n "$new" ] || die "boat did not say which sandbox it created"
  sid="$new"
  echo "remote sandbox: $sid  (put this id in the workspace's remote sandbox setting to reuse it, so Gradle's caches stay)"
fi

# 2. The tree: one archive with the committed files, the uncommitted diff, the untracked files and the scripts.
echo "packing HEAD, the uncommitted changes and the untracked files"
pack="$tmp/pack"; mkdir -p "$pack"
export COPYFILE_DISABLE=1        # no AppleDouble files in the archives
git archive --format=tar HEAD > "$pack/src.tar"
git diff HEAD --binary > "$pack/changes.patch"
git ls-files -o --exclude-standard -z > "$tmp/untracked.list"
if [ -s "$tmp/untracked.list" ]; then tar --null -T "$tmp/untracked.list" -cf "$pack/untracked.tar"; fi

cat > "$pack/run.sh" <<'RUN'
#!/bin/sh
# Remote side, detached: unpack the tree, build, leave the log in build.log and the exit status in build.status.
rm -f build.status build.status.tmp apk.rel
( sh ./unpack.sh && sh ./build.sh "$@" ) > build.log 2>&1
echo $? > build.status.tmp
mv build.status.tmp build.status
RUN
cat > "$pack/unpack.sh" <<'UNPACK'
#!/bin/sh
set -e
rm -rf src
mkdir src
tar -xf src.tar -C src
if [ -s changes.patch ]; then
  (cd src && git apply --whitespace=nowarn ../changes.patch)
  echo "applied the uncommitted changes"
fi
if [ -f untracked.tar ]; then
  tar -xf untracked.tar -C src
  echo "unpacked the untracked files"
fi
echo "source ready: $(find src -type f | wc -l | tr -d ' ') files"
UNPACK
cat > "$pack/build.sh" <<'BUILD'
#!/bin/sh
# $1: the application module (empty: found), $2: the variant.
module="$1"; variant="$2"
cd src
if [ -z "$module" ]; then
  found=""
  for f in $(find . -maxdepth 3 \( -name build.gradle -o -name build.gradle.kts \) -not -path '*/build/*' | sort); do
    d=$(dirname "$f"); [ "$d" = "." ] && continue
    if grep -qE 'android[._-]?[Aa]pplication' "$f" 2>/dev/null; then found="$found ${d#./}"; fi
  done
  set -- $found
  [ "$#" -ge 1 ] || { echo "error: no Android application module found. Set the module in the workspace's settings (module)." >&2; exit 2; }
  [ "$#" -eq 1 ] || { echo "error: several application modules found:$found. Set the module in the workspace's settings (module) to one of them." >&2; exit 2; }
  module="$1"
  echo "application module: $module"
fi
path="$(printf '%s' "$module" | sed 's|:|/|g; s|^/||')"
gradle_path=":$(printf '%s' "$path" | sed 's|/|:|g')"
task="assemble$(printf '%s' "$variant" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$variant" | cut -c2-)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
[ -f ./gradlew ] || { echo "error: no gradlew in the uploaded source" >&2; exit 2; }
chmod +x ./gradlew
touch ../gradle.stamp
echo "+ ./gradlew ${gradle_path}:${task}"
./gradlew "${gradle_path}:${task}" --console=plain || exit $?
lower="$(printf '%s' "$variant" | tr '[:upper:]' '[:lower:]')"
apk=""
for f in $(find "$path/build/outputs/apk" -name '*.apk' -newer ../gradle.stamp 2>/dev/null | sort); do
  case "$f" in *androidTest*|*unaligned*) continue ;; esac
  case "$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')" in *"$lower"*) apk="$f" ;; esac
done
[ -n "$apk" ] || { echo "error: no APK for variant '$variant' under $path/build/outputs/apk written by this build" >&2; exit 3; }
echo "$apk" > ../apk.rel
echo "built $apk"
BUILD
cat > "$pack/poll.sh" <<'POLL'
#!/bin/sh
# $1: the first log line wanted. Prints S:<exit status or empty>, N:<complete lines so far>, then the new lines.
k="$1"; s=""
[ -f build.status ] && s="$(cat build.status)"
n=0; [ -f build.log ] && n="$(wc -l < build.log | tr -d ' ')"
echo "S:$s"
echo "N:$n"
if [ -n "$s" ]; then sed -n "$k,\$p" build.log 2>/dev/null; else sed -n "$k,${n}p" build.log 2>/dev/null; fi
exit 0
POLL
tar -C "$pack" -cf "$tmp/upload.tar" .

# 3. Upload and start, detached (a command that is not detached ends after 30 s).
echo "uploading $(( $(wc -c < "$tmp/upload.tar") / 1024 )) KB to sandbox $sid"
boat_exec "$sid" "$home" "mkdir -p greenroom" || die "boat could not run a command in the sandbox $sid"
boat_put "$tmp/upload.tar" "$sid" "$wd/upload.tar" || die "boat could not upload the source to the sandbox $sid"
boat_exec "$sid" "$wd" "tar -xf upload.tar && rm upload.tar" || die "the sandbox $sid could not unpack the upload"
boat_exec_detached "$sid" "$wd" "sh ./run.sh '$module' '$variant'" || die "boat could not start the build in the sandbox $sid"
echo "build started in sandbox $sid"

# 4. Follow the log until the exit status appears.
k=1; status=""; bad=0
while :; do
  sleep "$poll"
  if ! resp="$(boat_exec "$sid" "$wd" "sh ./poll.sh $k")"; then
    bad=$((bad + 1))
    [ "$bad" -lt 6 ] || die "lost contact with the sandbox $sid while the build ran: boat exec kept failing"
    continue
  fi
  bad=0
  status="$(printf '%s\n' "$resp" | sed -n 1p | sed 's/^S://')"
  n="$(printf '%s\n' "$resp" | sed -n 2p | sed 's/^N://')"
  body="$(printf '%s\n' "$resp" | tail -n +3)"
  if [ -n "$body" ]; then printf '%s\n' "$body"; fi
  if [ -n "$status" ]; then break; fi
  case "$n" in ''|*[!0-9]*) ;; *) k=$((n + 1)) ;; esac
done
[ "$status" = 0 ] || die "the remote build failed (exit status $status). Its log is above."

# 5. The APK.
rel="$(boat_exec "$sid" "$wd" "cat apk.rel" | tail -n 1 | tr -d '\r')"
[ -n "$rel" ] || die "the remote build did not say where its APK is"
mkdir -p "$(dirname "$out")"
boat_get "$sid" "$wd/src/$rel" "$out" || die "boat could not fetch the APK $rel from the sandbox $sid"
echo "fetched $(basename "$rel")"
