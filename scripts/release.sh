#!/usr/bin/env bash
# The mechanical steps of a Greenroom release, so the release skill spends tokens on judgment, not on gh plumbing.
#   scripts/release.sh survey                 last tag, open PRs with their check state, what is on main since the tag
#   scripts/release.sh merge N [N...]         wait for each PR's checks, squash-merge it (oldest first), print the result
#   scripts/release.sh version patch|minor|X.Y.Z   print the next version
#   scripts/release.sh notes VERSION          draft release notes (one bullet per merged PR) on stdout
#   scripts/release.sh tag VERSION            tag origin/main once its CI is green, push the tag, wait for the release run
#   scripts/release.sh wait VERSION           keep waiting for the release run (tag exits 75 when it outlasts one call)
#   scripts/release.sh publish VERSION FILE   check the draft's assets, publish it with FILE as notes, check the feed
# Needs gh (logged in) and git. Never changes the checkout: it only fetches, tags origin/main and calls gh.
set -euo pipefail

REPO=aglose/greenroom
EMAIL=7216340+aglose@users.noreply.github.com
WAIT_CAP=540   # seconds one call may wait: a Bash call is limited to 10 minutes

die() { echo "error: $*" >&2; exit 1; }
last_tag() { git tag --list 'v[0-9]*' --sort=-v:refname | head -1; }

survey() {
  git fetch -q origin --tags --prune
  local last; last=$(last_tag)
  echo "last tag: ${last:-none}   main: $(git rev-parse --short origin/main)"
  echo "== open pull requests"
  gh pr list --repo "$REPO" --state open --limit 100 \
    --json number,title,headRefName,isDraft,mergeable,statusCheckRollup \
    --jq '.[] | "#\(.number) \(.title) [\(.headRefName)] \(if .isDraft then "DRAFT " else "" end)mergeable=\(.mergeable) checks=\([.statusCheckRollup[]? | (.conclusion // .status)] | unique | join(","))"' \
    | sort -t'#' -k2 -n
  echo "== on main since ${last:-the start}"
  git log --first-parent --format='%h %s' "${last:+$last..}origin/main"
  echo "== files changed"
  git diff --stat "${last:-$(git rev-list --max-parents=0 origin/main)}..origin/main" | tail -25
  echo "== drafts"; gh release list --repo "$REPO" --limit 5
}

merge() {
  [[ $# -gt 0 ]] || die "merge needs PR numbers"
  for n in "$@"; do
    echo "== #$n"
    gh pr view "$n" --repo "$REPO" --json isDraft,state -q '"\(.state) draft=\(.isDraft)"'
    # --watch returns non-zero when a check fails, which stops the run: the PR stays open for a human decision
    gh pr checks "$n" --repo "$REPO" --watch --interval 20 >/dev/null \
      || { gh pr checks "$n" --repo "$REPO" || true; die "#$n: checks did not pass; left open"; }
    gh pr merge "$n" --repo "$REPO" --squash --author-email "$EMAIL"
    echo "merged #$n"
  done
  git fetch -q origin
}

version() {
  local last cur; last=$(last_tag); cur=${last#v}; cur=${cur:-0.0.0}
  local ma mi pa; IFS=. read -r ma mi pa <<<"$cur"
  case "${1:-}" in
    patch) echo "$ma.$mi.$((pa+1))" ;;
    minor) echo "$ma.$((mi+1)).0" ;;
    [0-9]*.[0-9]*.[0-9]*) echo "$1" ;;
    *) die "version wants patch, minor or X.Y.Z" ;;
  esac
}

notes() {
  local last; last=$(last_tag)
  echo "TODO: one headline paragraph on what this release is for."
  echo
  git log --first-parent --format='%s' "${last:+$last..}origin/main" | while read -r s; do
    if [[ $s =~ \(#([0-9]+)\)$ ]]; then
      echo "- ${s% (#*} ([$REPO#${BASH_REMATCH[1]}](https://github.com/$REPO/pull/${BASH_REMATCH[1]}))"
    else echo "- $s"; fi
  done
  echo; echo "Group these under Added / Changed / Fixed by hand."
}

wait_run() {
  local tag=$1 id="" start=$SECONDS
  while [[ -z $id ]]; do
    id=$(gh run list --repo "$REPO" --workflow release.yml --branch "$tag" --limit 1 --json databaseId -q '.[0].databaseId // empty')
    [[ -n $id ]] || { (( SECONDS - start < 120 )) || die "no release run for $tag after 2 minutes"; sleep 10; }
  done
  echo "release run $id: https://github.com/$REPO/actions/runs/$id"
  while :; do
    read -r st con < <(gh run view "$id" --repo "$REPO" --json status,conclusion -q '"\(.status) \(.conclusion)"')
    if [[ $st == completed ]]; then
      if [[ $con == success ]]; then echo "release run succeeded"; return 0; fi
      gh run view "$id" --repo "$REPO" --log-failed | tail -60
      die "release run $con (see log tail above)"
    fi
    if (( SECONDS - start > WAIT_CAP )); then echo "still running; call: scripts/release.sh wait $tag"; exit 75; fi
    sleep 30
  done
}

tag_release() {
  local v=${1:?VERSION}; [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION is X.Y.Z, no leading v"
  git fetch -q origin --tags
  git rev-parse -q --verify "refs/tags/v$v" >/dev/null && die "v$v exists already"
  local sha; sha=$(git rev-parse origin/main)
  echo "== waiting for CI on main ($(git rev-parse --short "$sha"))"
  local id; id=$(gh run list --repo "$REPO" --workflow ci.yml --commit "$sha" --limit 1 --json databaseId -q '.[0].databaseId // empty')
  [[ -n $id ]] || die "no ci run for main's head yet; try again in a minute"
  gh run watch "$id" --repo "$REPO" --exit-status --interval 30 >/dev/null || die "CI on main failed: gh run view $id --log-failed"
  git tag -a "v$v" "$sha" -m "Greenroom $v"
  git push origin "v$v"
  wait_run "v$v"
}

publish() {
  local v=${1:?VERSION} file=${2:?notes file} tag="v$1"
  grep -q TODO "$file" && die "$file still has a TODO: finish the notes"
  [[ $(gh release view "$tag" --repo "$REPO" --json isDraft -q .isDraft) == true ]] || die "$tag is not a draft"
  local assets; assets=$(gh release view "$tag" --repo "$REPO" --json assets -q '.assets[].name')
  for pat in "^Greenroom-$v\.dmg$" "^Greenroom-$v\.dmg\.sha256$" "dSYM\.zip$" "^appcast\.xml$"; do
    grep -Eq "$pat" <<<"$assets" || die "draft lacks an asset matching $pat (has: $(tr '\n' ' ' <<<"$assets"))"
  done
  local dir; dir=$(mktemp -d); gh release download "$tag" --repo "$REPO" --pattern appcast.xml --dir "$dir"
  grep -q "sparkle:edSignature=" "$dir/appcast.xml" && grep -q "$v" "$dir/appcast.xml" || die "appcast does not carry $v with a signature"
  gh release edit "$tag" --repo "$REPO" --notes-file "$file" --draft=false
  sleep 5
  local feed; feed=$(curl -sL "https://github.com/$REPO/releases/latest/download/appcast.xml")
  grep -q "<sparkle:shortVersionString>$v<" <<<"$feed" || grep -q "shortVersionString=\"$v\"" <<<"$feed" \
    && echo "published: https://github.com/$REPO/releases/tag/$tag (update feed serves $v)" \
    || echo "published: https://github.com/$REPO/releases/tag/$tag (WARNING: the live feed does not show $v yet; recheck shortly)"
}

cmd=${1:-}; shift || true
case $cmd in
  survey) survey ;;
  merge) merge "$@" ;;
  version) version "$@" ;;
  notes) notes ;;
  tag) tag_release "$@" ;;
  wait) wait_run "v${1#v}" ;;
  publish) publish "${1#v}" "${2:-}" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
