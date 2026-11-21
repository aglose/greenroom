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
#                             saved by Greenroom into the sandbox setting, so the next build reuses it.
#   GREENROOM_REMOTE_WAIT     seconds the build may take before the script gives up (3600).
# "Prepare remote builder" in Greenroom shows how to make the template (a JDK, the Android SDK).
#
# What is uploaded: `git archive HEAD` (the committed tree: files marked export-ignore in .gitattributes are left
# out), `git diff HEAD --binary` (every uncommitted change to tracked files, deletions too) and the untracked files
# that .gitignore does not ignore. Ignored files (build output, local.properties, secrets in ignored files) stay.
# Untracked files whose names look like secrets (*.jks, *.keystore, *.p12, .env*, keystore.properties,
# local.properties, google-services.json, *.pem, id_rsa*) are NOT uploaded, and the log says which were left out;
# nested repositories and symlinks that leave the tree are skipped too. The names of what is uploaded are printed.
# The sandbox is stopped when the script ends, whether it built, failed or was cancelled (a SIGTERM runs the same
# cleanup). Its id and the temporary folder are written to remote-state beside GREENROOM_OUT as soon as they exist;
# if the script is killed without cleanup, the next run (or the next launch of Greenroom) stops that sandbox.
# The source stays in the stopped sandbox until you delete it.
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

case "$module" in *[!A-Za-z0-9_:./-]*) die "the module '$module' has characters a remote command may not carry. Use letters, digits and _ : . / - in the workspace's module setting." ;; esac
case "$variant" in ''|*[!A-Za-z0-9_:./-]*) die "the variant '$variant' has characters a remote command may not carry. Use letters, digits and _ : . / - in the workspace's variant setting." ;; esac

home=/home/user
wd="$home/greenroom"
state="$(dirname "$out")/remote-state"

# A run that was killed without cleanup left its sandbox running and its temporary folder behind: they are in the
# state file. Stop that sandbox and remove the folder first.
if [ -f "$state" ]; then
  old_sid="$(sed -n 's/^sandbox=//p' "$state" | head -n 1)"
  old_tmp="$(sed -n 's/^tmp=//p' "$state" | head -n 1)"
  case "$old_tmp" in */greenroom-remote.*) rm -rf "$old_tmp" ;; esac
  if [ -n "$old_sid" ]; then
    echo "stopping sandbox $old_sid, which an earlier run left running"
    if boat_stop "$old_sid" >/dev/null 2>&1; then rm -f "$state"; else echo "warning: could not stop sandbox $old_sid. Stop it yourself (boat stop $old_sid): it may still be running and billing."; fi
  else
    rm -f "$state"
  fi
fi

tmp="$(mktemp -d -t greenroom-remote)"
sid=""
stopped=0
stop_ok=1
mkdir -p "$(dirname "$out")"
record_state() { { echo "root=${GREENROOM_REPO:-}"; echo "tmp=$tmp"; echo "sandbox=$sid"; } > "$state.part" && mv "$state.part" "$state"; }
record_state

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
  if [ "$rc" != 0 ]; then
    stop_ok=0
    echo "warning: could not stop sandbox $sid. Stop it yourself (boat stop $sid): it may still be running and billing."
  fi
}
cleanup() {
  stop_sandbox
  rm -rf "$tmp"
  if [ "$stop_ok" = 1 ]; then rm -f "$state" "$state.part"; else { echo "root=${GREENROOM_REPO:-}"; echo "sandbox=$sid"; } > "$state"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 1. The sandbox: resumed, or made from the template.
if [ -n "$sandbox" ]; then
  sid="$sandbox"
  record_state
  echo "resuming sandbox $sid"
  boat_start "$sid" || die "boat could not resume the sandbox $sid. Is boat signed in (boat login, or BOAT_API_KEY), and is the id in the workspace's settings right?"
else
  echo "creating a sandbox from the template $template"
  new="$(boat_new "$template")" || die "boat could not create a sandbox from the template $template. Is boat signed in (boat login, or BOAT_API_KEY), and is the template right?"
  [ -n "$new" ] || die "boat did not say which sandbox it created"
  sid="$new"
  record_state
  echo "greenroom: sandbox-created $sid"
  echo "remote sandbox: $sid (Greenroom keeps this id in the workspace's settings, so the next build reuses it and Gradle's caches stay)"
fi

# 2. The tree: one archive with the committed files, the uncommitted diff, the untracked files and the scripts.
echo "packing HEAD, the uncommitted changes and the untracked files"
pack="$tmp/pack"; mkdir -p "$pack"
export COPYFILE_DISABLE=1        # no AppleDouble files in the archives
git archive --format=tar HEAD > "$pack/src.tar"
git diff HEAD --binary --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/ > "$pack/changes.patch"

# Untracked files, one by one: git lists a nested repository as "dir/" and tar would take everything inside it,
# ignored files and its .git included, so only entries git named as files are uploaded. Secrets are left out.
top="$(pwd -P)"
: > "$tmp/untracked.list"
sent=0; sent_names=""; left=""; skipped=""
while IFS= read -r -d '' f; do
  case "$f" in
    */) skipped="$skipped $f"; continue ;;
  esac
  lower="$(printf '%s' "${f##*/}" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.jks|*.keystore|*.p12|.env|.env.*|.env*|keystore.properties|local.properties|google-services.json|*.pem|id_rsa*) left="$left $f"; continue ;;
  esac
  if [ -L "$f" ]; then
    target="$(perl -MCwd=realpath -e 'my $r = realpath($ARGV[0]); print $r if defined $r' "$f" 2>/dev/null || true)"
    case "$target" in "$top"/*) ;; *) skipped="$skipped $f(symlink out of the tree)"; continue ;; esac
  elif [ ! -f "$f" ]; then
    skipped="$skipped $f"; continue
  fi
  printf '%s\0' "$f" >> "$tmp/untracked.list"
  sent=$((sent + 1))
  if [ "$sent" -le 40 ]; then sent_names="$sent_names $f"; fi
done < <(git ls-files -o --exclude-standard -z)
if [ "$sent" -gt 0 ]; then
  tar --null -T "$tmp/untracked.list" -cf "$pack/untracked.tar"
  more=""; [ "$sent" -le 40 ] || more=" and $((sent - 40)) more"
  echo "uploading $sent untracked file(s):${sent_names}${more}"
else
  echo "no untracked files to upload"
fi
[ -z "$left" ] || echo "left out, their names look like secrets (never uploaded):$left"
[ -z "$skipped" ] || echo "skipped, not plain files of this tree (a nested repository is its own repository):$skipped"

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
  # The ceiling keeps git from finding a repository around src (a home folder kept in git): inside one, git apply
  # takes the patch's paths from that repository's top and silently skips every file.
  (cd src && GIT_CEILING_DIRECTORIES="$(cd .. && pwd -P)" git apply --whitespace=nowarn ../changes.patch)
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
# The same ceiling as unpack.sh's: a build that asks git (a version plugin, a commit hash) must not read the state of
# a repository around src.
GIT_CEILING_DIRECTORIES="$(cd .. && pwd -P)"; export GIT_CEILING_DIRECTORIES
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
limit="${GREENROOM_REMOTE_WAIT:-3600}"
began=$SECONDS
while :; do
  [ $((SECONDS - began)) -lt "$limit" ] || die "the remote build did not finish within $limit seconds, so it was given up on (GREENROOM_REMOTE_WAIT). The sandbox $sid is stopped, and the build with it."
  sleep "$poll"
  if ! resp="$(boat_exec "$sid" "$wd" "sh ./poll.sh $k")"; then
    bad=$((bad + 1))
    [ "$bad" -lt 6 ] || die "lost contact with the sandbox $sid while the build ran: boat exec kept failing, so it may have stopped or been deleted"
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
