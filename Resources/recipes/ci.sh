#!/bin/bash
# Greenroom recipe "ci": fetches the APK your GitHub Actions already built for this commit, with the GitHub CLI (gh)
# and your own sign-in. Nothing is built on this Mac.
#
# Given in the environment: GREENROOM_WORKTREE (gh finds the repository from it), GREENROOM_SHA, GREENROOM_REF (the
# branch), GREENROOM_DIRTY, GREENROOM_OUT, and the workspace's settings:
#   GREENROOM_CI_ARTIFACT  the artifact's name. Empty: the only artifact holding an APK that matches the pattern.
#   GREENROOM_CI_APK       a glob for the APK's file name inside the artifact (default *.apk).
#   GREENROOM_CI_WORKFLOW  a workflow that has workflow_dispatch: started with `gh workflow run` when the commit
#                          has no run yet. Empty: a commit with no run fails.
#   GREENROOM_REPO_SLUG    owner/repo on GitHub, from the remote the worktree's upstream uses: every gh call names it
#                          with -R, so the repository never depends on which remote gh would guess.
#   GREENROOM_CI_DISPATCH  0: never start a workflow (base resolution and pull-request rows set it). Otherwise only
#                          an explicit Build starts one, and only when the branch on GitHub is at GREENROOM_SHA.
# Knobs for slow or fast CI: GREENROOM_CI_WAIT (the longest this script waits for runs, seconds, 1200), GREENROOM_CI_GRACE (seconds a commit with no run is waited for before anything is
# started, 10), GREENROOM_CI_APPEAR_SECONDS (how long a started workflow may take to show a run, 180),
# GREENROOM_CI_POLL (seconds between looks, 5).
#
# How far it has got is said in lines of the form "greenroom: progress DONE/TOTAL UNIT", which Greenroom draws as the
# job's bar and keeps out of the log: the steps of a run that is waited for, the bytes of an artifact as it arrives.
#
# Only pushed commits have a run: the script says so for one that is not. Uncommitted changes are never in it.
# Copy this file, change it, and choose it with "Custom..." for another CI.
set -eu
cd "${GREENROOM_WORKTREE:?GREENROOM_WORKTREE is not set}"
out="${GREENROOM_OUT:?GREENROOM_OUT is not set}"
sha="${GREENROOM_SHA:?GREENROOM_SHA is not set}"
ref="${GREENROOM_REF:-}"
artifact="${GREENROOM_CI_ARTIFACT:-}"
pattern="${GREENROOM_CI_APK:-*.apk}"
workflow="${GREENROOM_CI_WORKFLOW:-}"
poll="${GREENROOM_CI_POLL:-5}"
wait_limit="${GREENROOM_CI_WAIT:-1200}"
dispatch="${GREENROOM_CI_DISPATCH:-1}"
slug="${GREENROOM_REPO_SLUG:-}"
R=(); [ -z "$slug" ] || R=(-R "$slug")
api_repo="repos/{owner}/{repo}"; [ -z "$slug" ] || api_repo="repos/$slug"
overall=$SECONDS
grace="${GREENROOM_CI_GRACE:-10}"
appear="${GREENROOM_CI_APPEAR_SECONDS:-180}"
short="$(printf '%s' "$sha" | cut -c1-7)"

fail() { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || fail "the ci recipe needs the GitHub CLI (gh) and it is not installed. Install it (brew install gh) and sign in with gh auth login, or use the local recipe."
gh auth status >/dev/null 2>&1 || fail "gh is not signed in to GitHub. Run gh auth login in a terminal, or use the local recipe."

# A commit this checkout knows but no remote branch contains was never pushed. One it does not know (a pull
# request's head, not fetched) is taken as pushed: GitHub is asked.
if git cat-file -e "$sha^{commit}" 2>/dev/null; then
  if [ -z "$(git for-each-ref --count=1 --contains "$sha" refs/remotes 2>/dev/null)" ]; then
    fail "CI can only build pushed commits: push, or use the local recipe. ($short is on no remote branch.)"
  fi
fi
if [ "${GREENROOM_DIRTY:-0}" = 1 ]; then
  echo "note: uncommitted changes are not in what CI built"
fi

tmp="$(mktemp -d -t greenroom-ci)"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# The commit's runs, one per line: ID, status, conclusion, workflow name (tab separated), newest first. With a
# workflow setting, the runs of that workflow (its name or its file's name, any case) when there are some: a run's
# JSON names the workflow by its display name, which need not be the file's. When none match, every run counts:
# the artifacts decide which one has the APK.
list_runs() {
  local lines
  if ! lines="$(gh run list ${R[@]+"${R[@]}"} --commit "$sha" --limit 50 --json databaseId,status,conclusion,workflowName,headSha \
        --jq '.[] | select(.headSha == "'"$sha"'") | [.databaseId, .status, .conclusion, .workflowName] | @tsv' 2>"$tmp/err")"; then
    fail "gh could not list the runs of $short: $(tail -n 1 "$tmp/err")"
  fi
  lines="$(printf '%s\n' "$lines" | sed '/^$/d')"
  if [ -z "$workflow" ] || [ -z "$lines" ]; then printf '%s\n' "$lines" | sed '/^$/d'; return 0; fi
  local stem="${workflow##*/}"; stem="${stem%.yml}"; stem="${stem%.yaml}"
  local mine
  mine="$(printf '%s\n' "$lines" | awk -F'\t' -v w="$workflow" -v s="$stem" 'BEGIN { w = tolower(w); s = tolower(s) } NF && (tolower($4) == w || tolower($4) == s)')"
  if [ -n "$mine" ]; then printf '%s\n' "$mine"; else printf '%s\n' "$lines"; fi
}

# How far a run that is waited for has got: the steps of its jobs that are over, of those GitHub has listed so far (a
# job that has not begun lists none yet, so the total is "about"), and the step it is on when that changed. Says
# nothing when GitHub does not answer: the run is waited for all the same.
on_step=""
run_steps() {
  local said counts now
  said="$(gh api "$api_repo/actions/runs/$1/jobs?per_page=100" --jq '[.jobs[] | .name as $j | (.steps // [])[] | {j: $j, n: .name, s: .status}] | [(map(select(.s == "completed")) | length), length, (map(select(.s == "in_progress")) | first | if . then "\(.j): \(.n)" else "" end)] | @tsv' 2>/dev/null)" || return 0
  counts="$(printf '%s\n' "$said" | awk -F'\t' '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 > 0 { print $1 "/~" $2; exit }')"
  [ -n "$counts" ] || return 0
  now="$(printf '%s\n' "$said" | awk -F'\t' 'NR == 1 { print $3 }')"
  if [ -n "$now" ] && [ "$now" != "$on_step" ]; then on_step="$now"; echo "CI run $1: $now"; fi
  echo "greenroom: progress $counts steps"
}

# Downloads one artifact (its id, its size in bytes, the folder to unpack it in), saying how many bytes have arrived
# as they do. Not zero when it could not: the artifact is then fetched with gh run download, which is silent.
fetch_artifact() {
  local aid="$1" size="$2" dir="$3" zip="$tmp/artifact-$1.zip" pid got
  command -v unzip >/dev/null 2>&1 || return 1
  gh api "$api_repo/actions/artifacts/$aid/zip" > "$zip" 2>"$tmp/err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    got="$(wc -c < "$zip" 2>/dev/null | tr -d ' ')"
    # More than GitHub said there would be: the total was wrong, and only the count is said.
    if [ "${got:-0}" -le "$size" ]; then echo "greenroom: progress ${got:-0}/$size bytes"; else echo "greenroom: progress $got/? bytes"; fi
    sleep 1
  done
  if wait "$pid" && unzip -q -o "$zip" -d "$dir" 2>"$tmp/err"; then
    rm -f "$zip"
    echo "greenroom: progress -"
    return 0
  fi
  rm -rf "$zip" "$dir"; mkdir -p "$dir"
  echo "greenroom: progress -"
  return 1
}

started=$SECONDS
dispatched=0
runs=""
while :; do
  runs="$(list_runs)"
  [ -n "$runs" ] && break
  waited=$((SECONDS - started))
  if [ "$dispatched" = 0 ]; then
    if [ "$waited" -lt "$grace" ]; then sleep "$poll"; continue; fi
    if [ "$dispatch" != 1 ] && [ -n "$workflow" ]; then
      fail "no CI run for $short. It was not started here: a workflow is started only by pressing Build on a session. Wait for CI, or build that session."
    fi
    [ -n "$workflow" ] || fail "no CI run for $short, and no workflow is set to start one. Wait for CI to start, or set the CI workflow in the workspace's settings (a workflow with workflow_dispatch), or use the local recipe."
    [ -n "$ref" ] || fail "no CI run for $short, and the worktree is on no branch, which gh workflow run needs. Check out a branch, or use the local recipe."
    tip="$(gh api "$api_repo/git/ref/heads/$ref" --jq .object.sha 2>"$tmp/err" || true)"
    [ "$tip" = "$sha" ] || fail "CI can only build pushed commits: push, or use the local recipe. (On GitHub $ref is at ${tip:-an unknown commit}, not $short, so a workflow started there would build something else.)"
    echo "+ gh workflow run $workflow --ref $ref"
    gh workflow run ${R[@]+"${R[@]}"} "$workflow" --ref "$ref" >/dev/null 2>"$tmp/err" || fail "gh could not start the workflow $workflow on $ref: $(tail -n 1 "$tmp/err")"
    dispatched=1
    started=$SECONDS
    continue
  fi
  [ "$waited" -lt "$appear" ] || fail "the workflow $workflow was started on $ref but no run of $short appeared within $appear seconds. Is $short the tip of $ref on GitHub?"
  sleep "$poll"
done

# Wait for every run of the commit that has not finished (at most GREENROOM_CI_WAIT seconds in all).
while :; do
  active="$(printf '%s\n' "$runs" | awk -F'\t' '$2 != "completed" { print $1 "\t" $2; exit }')"
  [ -n "$active" ] || break
  aid="${active%%	*}"; astatus="${active#*	}"
  [ $((SECONDS - overall)) -lt "$wait_limit" ] || {
    if [ "$astatus" = waiting ]; then fail "CI run $aid of $short is waiting for approval (a reviewer or an environment must approve it on GitHub), and $wait_limit seconds passed."; fi
    fail "CI run $aid of $short is still $astatus after $wait_limit seconds, so it was given up on (GREENROOM_CI_WAIT)."
  }
  if [ "$astatus" = waiting ]; then
    echo "CI run $aid is waiting for approval (a reviewer or an environment must approve it on GitHub)"
    sleep "$poll"
  else
    echo "waiting for CI run $aid"
    gh run watch ${R[@]+"${R[@]}"} "$aid" --exit-status >/dev/null 2>"$tmp/err" &
    watch=$!
    asked=$SECONDS
    run_steps "$aid"
    while kill -0 "$watch" 2>/dev/null; do
      if [ $((SECONDS - asked)) -ge 10 ]; then asked=$SECONDS; run_steps "$aid"; fi
      sleep 1
    done
    echo "greenroom: progress -"
    if ! wait "$watch"; then
      # A run that failed makes watch exit non-zero too: only a run still not finished means watch itself failed.
      werr="$(tail -n 1 "$tmp/err")"
      now="$(list_runs | awk -F'\t' -v id="$aid" '$1 == id { print $2 }')"
      if [ "$now" != completed ]; then fail "gh run watch could not follow CI run $aid: $werr"; fi
    fi
    sleep "$poll"
  fi
  runs="$(list_runs)"
done

good="$(printf '%s\n' "$runs" | awk -F'\t' '$3 == "success" { print $1 }')"
bad="$(printf '%s\n' "$runs" | awk -F'\t' '$3 != "success" && $3 != "skipped" && $3 != "neutral" { print $1 }' | head -n 1)"

run_url() { gh run view ${R[@]+"${R[@]}"} "$1" --json url --jq .url 2>/dev/null || echo "run $1"; }
failed_run() { fail "CI run $1 of $short did not succeed: $(run_url "$1")"; }

[ -n "$good" ] || { [ -n "$bad" ] && failed_run "$bad"; fail "the CI runs of $short finished without a result: $(printf '%s' "$runs" | tr '\t\n' ' ;')"; }

# Look in each successful run (newest first) for the APK.
for id in $good; do
  listing="$(gh api --paginate "$api_repo/actions/runs/$id/artifacts?per_page=100" --jq '.artifacts[] | [.name, (.expired | tostring), (.id | tostring), (.size_in_bytes | tostring)] | @tsv' 2>"$tmp/err")" \
    || fail "gh could not list the artifacts of CI run $id: $(tail -n 1 "$tmp/err")"
  # "name<TAB>id<TAB>bytes" lines: what has not expired.
  names="$(printf '%s\n' "$listing" | awk -F'\t' '$2 != "true" { print $1 "\t" $3 "\t" $4 }')"
  expired="$(printf '%s\n' "$listing" | awk -F'\t' '$2 == "true" { print $1 }' | tr '\n' ' ')"
  if [ -n "$artifact" ] && printf '%s\n' "$listing" | awk -F'\t' -v a="$artifact" '$1 == a && $2 == "true" { f = 1 } END { exit !f }'; then
    fail "artifact $artifact of run $id expired: re-run the workflow so GitHub keeps a new one."
  fi
  found=""        # "artifact<TAB>file" lines
  seen=""
  while IFS='	' read -r name aid size; do
    [ -n "$name" ] || continue
    seen="$seen $name"
    if [ -n "$artifact" ] && [ "$name" != "$artifact" ]; then continue; fi
    dir="$tmp/$id/$name"
    mkdir -p "$dir"
    got=0
    case "$aid/$size" in
      *[!0-9/]*|/*|*/|*/0) ;;   # GitHub did not say which artifact or how big
      *) echo "downloading the artifact $name of CI run $id"
         if fetch_artifact "$aid" "$size" "$dir"; then got=1; fi ;;
    esac
    if [ "$got" = 0 ]; then
      echo "+ gh run download $id -n $name"
      gh run download ${R[@]+"${R[@]}"} "$id" -n "$name" -D "$dir" >/dev/null 2>"$tmp/err" || fail "gh could not download the artifact $name of CI run $id: $(tail -n 1 "$tmp/err")"
    fi
    case "$pattern" in
      */*) files="$(find "$dir" -type f -path "*/$pattern" | sort)" ;;
      *)   files="$(find "$dir" -type f -name "$pattern" | sort)" ;;
    esac
    while IFS= read -r f; do
      if [ -n "$f" ]; then found="$found$name	$f
"; fi
    done <<EOF2
$files
EOF2
  done <<EOF2
$names
EOF2
  [ -n "$found" ] || continue
  arts="$(printf '%s' "$found" | cut -f1 | sort -u)"
  if [ "$(printf '%s\n' "$arts" | wc -l | tr -d ' ')" -gt 1 ]; then
    list="$(printf '%s\n' "$arts" | tr '\n' ' ')"
    fail "CI run $id has several artifacts with an APK matching $pattern: ${list% }. Set the CI artifact in the workspace's settings to one of them."
  fi
  count="$(printf '%s' "$found" | grep -c .)"
  if [ "$count" -gt 1 ]; then
    list="$(printf '%s' "$found" | cut -f2 | while IFS= read -r f; do printf '%s ' "${f#"$tmp/$id/"}"; done)"
    fail "the artifact $arts of CI run $id holds several APKs matching $pattern: ${list% }. Set the CI APK pattern in the workspace's settings to match one."
  fi
  apk="$(printf '%s' "$found" | cut -f2)"
  mkdir -p "$(dirname "$out")"
  cp "$apk" "$out"
  echo "got $(basename "$apk") from CI run $id, artifact $arts"
  exit 0
done

[ -z "$bad" ] || failed_run "$bad"
if [ -n "${expired:-}" ] && [ -z "${seen:-}" ]; then
  fail "artifact ${expired% } of run $id expired: re-run the workflow so GitHub keeps a new one."
fi
if [ -n "$artifact" ]; then
  fail "no APK matching $pattern in the artifact $artifact of the CI run for $short (artifacts there:${seen:- none}). Check the CI artifact and CI APK pattern in the workspace's settings."
fi
fail "no artifact of the CI run for $short holds an APK matching $pattern (artifacts there:${seen:- none}). Set the CI artifact and CI APK pattern in the workspace's settings."
