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
# Knobs for slow or fast CI: GREENROOM_CI_GRACE (seconds a commit with no run is waited for before anything is
# started, 10), GREENROOM_CI_APPEAR_SECONDS (how long a started workflow may take to show a run, 180),
# GREENROOM_CI_POLL (seconds between looks, 5).
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

# The commit's runs, one per line: ID, status, conclusion, workflow name (tab separated), newest first. With a
# workflow setting, the runs of that workflow (its name or its file's name, any case) when there are some: a run's
# JSON names the workflow by its display name, which need not be the file's. When none match, every run counts:
# the artifacts decide which one has the APK.
list_runs() {
  local lines
  if ! lines="$(gh run list --commit "$sha" --limit 50 --json databaseId,status,conclusion,workflowName,headSha \
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

started=$SECONDS
dispatched=0
runs=""
while :; do
  runs="$(list_runs)"
  [ -n "$runs" ] && break
  waited=$((SECONDS - started))
  if [ "$dispatched" = 0 ]; then
    if [ "$waited" -lt "$grace" ]; then sleep "$poll"; continue; fi
    [ -n "$workflow" ] || fail "no CI run for $short, and no workflow is set to start one. Wait for CI to start, or set the CI workflow in the workspace's settings (a workflow with workflow_dispatch), or use the local recipe."
    [ -n "$ref" ] || fail "no CI run for $short, and the worktree is on no branch, which gh workflow run needs. Check out a branch, or use the local recipe."
    echo "+ gh workflow run $workflow --ref $ref"
    gh workflow run "$workflow" --ref "$ref" >/dev/null 2>"$tmp/err" || fail "gh could not start the workflow $workflow on $ref: $(tail -n 1 "$tmp/err")"
    dispatched=1
    started=$SECONDS
    continue
  fi
  [ "$waited" -lt "$appear" ] || fail "the workflow $workflow was started on $ref but no run of $short appeared within $appear seconds. Is $short the tip of $ref on GitHub?"
  sleep "$poll"
done

# Wait for every run of the commit that has not finished.
while :; do
  active="$(printf '%s\n' "$runs" | awk -F'\t' '$2 != "completed" { print $1; exit }')"
  [ -n "$active" ] || break
  echo "waiting for CI run $active"
  gh run watch "$active" --exit-status >/dev/null 2>&1 || true   # a failing run is judged below, from its conclusion
  sleep "$poll"
  runs="$(list_runs)"
done

good="$(printf '%s\n' "$runs" | awk -F'\t' '$3 == "success" { print $1 }')"
bad="$(printf '%s\n' "$runs" | awk -F'\t' '$3 != "success" && $3 != "skipped" && $3 != "neutral" { print $1 }' | head -n 1)"

run_url() { gh run view "$1" --json url --jq .url 2>/dev/null || echo "run $1"; }
failed_run() { fail "CI run $1 of $short did not succeed: $(run_url "$1")"; }

[ -n "$good" ] || { [ -n "$bad" ] && failed_run "$bad"; fail "the CI runs of $short finished without a result: $(printf '%s' "$runs" | tr '\t\n' ' ;')"; }

# Look in each successful run (newest first) for the APK.
for id in $good; do
  names="$(gh api "repos/{owner}/{repo}/actions/runs/$id/artifacts" --jq '.artifacts[] | select(.expired | not) | .name' 2>"$tmp/err")" \
    || fail "gh could not list the artifacts of CI run $id: $(tail -n 1 "$tmp/err")"
  found=""        # "artifact<TAB>file" lines
  seen=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    seen="$seen $name"
    if [ -n "$artifact" ] && [ "$name" != "$artifact" ]; then continue; fi
    dir="$tmp/$id/$name"
    mkdir -p "$dir"
    echo "+ gh run download $id -n $name"
    gh run download "$id" -n "$name" -D "$dir" >/dev/null 2>"$tmp/err" || fail "gh could not download the artifact $name of CI run $id: $(tail -n 1 "$tmp/err")"
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
if [ -n "$artifact" ]; then
  fail "no APK matching $pattern in the artifact $artifact of the CI run for $short (artifacts there:${seen:- none}). Check the CI artifact and CI APK pattern in the workspace's settings."
fi
fail "no artifact of the CI run for $short holds an APK matching $pattern (artifacts there:${seen:- none}). Set the CI artifact and CI APK pattern in the workspace's settings."
