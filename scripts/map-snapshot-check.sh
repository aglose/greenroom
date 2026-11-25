#!/bin/bash
# The CI walk's snapshot (docs/MAP-HISTORY-PLAN.md, package G2): scripts/map-snapshot.py, which runs on Linux in CI,
# must write byte for byte what the app writes (`Greenroom --map-import`, through MapStore.importWalk and MapGit.write):
# the same JSON, the same git commit, the same refs. Built and run against temporary walks and repositories only;
# nothing is fetched or pushed.
#
#   scripts/map-snapshot-check.sh [--no-build]
#
# One `ok|FAIL` line per step and a last PASS or FAIL.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
if [ "${1:-}" != "--no-build" ]; then swift build 2>&1 | tail -3; fi
BIN="$(swift build --show-bin-path 2>/dev/null)/Greenroom"
PY="$ROOT/scripts/map-snapshot.py"
W=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-snapshot-check.XXXXXX")
trap 'rm -rf "$W"' EXIT
FAILED=0
step() { # step "what" command...
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; FAILED=1; fi
}
[ -x "$BIN" ] || { echo "FAIL  no built Greenroom at $BIN"; echo "map-snapshot check: FAIL"; exit 1; }

# --- Fixture walks: the store check's two, and three written here -------------------------------------------------
"$BIN" --map-store-check "$W/store" >"$W/store.log" 2>&1
step "the store check's walks exist" test -f "$W/store/walk-a/crawl.json" -a -f "$W/store/walk-b/crawl.json"
python3 - "$W" <<'PY'
import json, os, sys
w = sys.argv[1]
def walk(name, crawl, files):
    d = os.path.join(w, name)
    os.makedirs(d, exist_ok=True)
    for rel, data in files.items():
        os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
        open(os.path.join(d, rel), "wb").write(data)
    open(os.path.join(d, "crawl.json"), "w", encoding="utf-8").write(json.dumps(crawl, ensure_ascii=False))
png = lambda n: b"\x89PNG\r\n\x1a\n" + bytes([n]) * 40
# unicode titles, quotes, backslashes and control characters in texts, a non-integer seconds, a screen with no captures,
# a capture file that is missing, a path that leads out of the walk, activity names with dots, a flaky screen, a finding
walk("unicode", {
    "combos": ["light", "dark"],
    "screens": [
        {"id": "Ünï-0001", "activity": "com.exämple.日本語Activity", "title": "Réservations — 日本語 \U0001F600", "depth": 0, "parent": None,
         "path": {"start": "app://trips/1?a=b&c=d", "steps": ["tap \"Go\"", "back"]},
         "captures": {"light": "screens/é light.png", "dark": "screens/dark.png"},
         "texts": ["He said \"hi\"", "back\\slash", "a/b", "tab\there", "line\nbreak", "bell\u0001 us\u001f del\u007f", "line sep", "é vs é"], "settled": True},
        {"id": "Bare-0002", "activity": "Bare", "title": "", "depth": 1, "parent": "Ünï-0001", "path": {"steps": []}, "captures": {}, "texts": [], "settled": False, "flaky": "changes on every look"},
        {"id": "NoKeys-0003"},
        {"id": "Gone-0004", "activity": "a.b.", "depth": 1.0, "parent": "Ünï-0001", "path": {"steps": ["x"]}, "captures": {"light": "screens/missing.png"}, "texts": ["z"]},
        {"id": "Out-0005", "activity": "...", "captures": {"light": "../outside.png"}},
        {"id": "Ünï-0000", "captures": {"light": "screens/dark.png"}},
    ],
    "edges": [
        {"from": "Ünï-0001", "action": "Ouvrir \"é\"", "cmd": "tap 1", "to": "Bare-0002", "note": "back\\slash"},
        {"from": "Ünï-0001", "action": "Later", "cmd": "tap 2"},
        {"from": "Ünï-0001", "action": "Quit", "cmd": "back", "to": "EXIT"},
        {"from": "Bare-0002", "action": "x", "cmd": "tap 3", "to": "CRASH"},
        {"action": "no from", "cmd": "tap 4"},
    ],
    "findings": [{"kind": "crash", "detail": "NullPointer\n  at a.b.C \"quoted\"", "path": {"steps": ["tap 1"]}}, {"kind": "x"}],
    "incomplete": ["--max-seconds 120"], "seconds": {"total": 1234.5678}},
    {"screens/é light.png": png(1), "screens/dark.png": png(2), "../outside.png": png(3)})
# nothing found beyond the first screen: an empty edge list and no findings, whole-number seconds
walk("empty", {"screens": [{"id": "Only-0001", "activity": "com.example.Only", "title": "Only", "depth": 0, "path": {"steps": []},
                            "captures": {"light": "a.png"}, "texts": ["x"]}], "edges": [], "findings": [], "incomplete": [], "seconds": {"total": 7}},
     {"a.png": png(9)})
# a walk with no screens at all and no seconds
walk("nothing", {"screens": []}, {})
# --record-deps (package I1), and screen_ids / clock / network: per-screen deps in no order with unicode, an empty deps object, a list that is not all
# strings, deps that is not an object, the app start's deps, why they cannot be trusted, and walked and carried screens
walk("deps", {
    "screens": [
        {"id": "Deps-0001", "activity": "com.example.Main", "title": "Main", "depth": 0, "path": {"steps": []}, "captures": {"light": "a.png"},
         "texts": ["x"], "origin": "walked",
         "deps": {"classes": ["com.example.Zed", "com.example.Ä", "com.example.Main"], "sources": ["com/example/Main.kt", "com/example/Ä.kt", "com/example/Util.kt"],
                  "resources": ["string/title", "layout/main", "drawable/ic_ä"]}},
        {"id": "Deps-0002", "activity": "com.example.Detail", "depth": 1, "parent": "Deps-0001", "path": {"steps": ["tap 1"]}, "captures": {"light": "b.png"},
         "origin": "carried", "deps": {}},
        {"id": "Deps-0003", "activity": "com.example.Odd", "depth": 1, "origin": "carried", "deps": {"classes": ["a", 3], "sources": "nope", "resources": ["r/x"]}},
        {"id": "Deps-0004", "activity": "com.example.NoDeps", "depth": 1, "origin": "walked", "deps": ["not", "an", "object"]},
    ],
    "edges": [{"from": "Deps-0001", "action": "Open", "cmd": "tap 1", "to": "Deps-0002"}],
    "start_deps": {"classes": ["com.example.App"], "sources": ["com/example/App.kt"], "resources": ["style/Theme.App", "mipmap/ic_launcher"]},
    "deps_unreliable": "the probes were reset mid-screen", "seconds": {"total": 3.25},
    # how it read its screens: id rule, clock, and the --freeze-network recording (named by hash, not carried)
    "screen_ids": 2, "clock": "2026-11-25T21:04:00Z", "network": {"recording": "network.har", "entries": 1, "fetched": 1}},
    {"a.png": png(11), "b.png": png(12), "network.har": b'{"log": {"version": "1.2", "entries": []}}'})
# seeded from the deps walk's snapshot: a carried screen the seed walked, one the seed carried, one the seed lacks, and a
# carried screen with no deps of its own (it keeps the seed's)
walk("deps2", {
    "screens": [
        {"id": "Deps-0001", "activity": "com.example.Main", "depth": 0, "origin": "carried", "captures": {"light": "a.png"}},
        {"id": "Deps-0002", "activity": "com.example.Detail", "depth": 1, "origin": "carried"},
        {"id": "Deps-0009", "activity": "com.example.New", "depth": 1, "origin": "carried", "deps": {"sources": ["com/example/New.kt"]}},
        {"id": "Deps-0010", "activity": "com.example.Walked", "depth": 1, "origin": "walked", "replaces": "Deps-0004", "deps": {"resources": ["layout/w"]}},
    ],
    "edges": [], "start_deps": {"classes": [], "sources": [], "resources": []}, "incomplete": ["seed: --max-depth 3: Deps-0002 not explored", "--max-seconds 9"]},
    {"a.png": png(11)})
PY
# the unicode walk's outside.png sits above its folder on purpose; the walk must refuse to read it
step "fixture walks written" test -f "$W/unicode/crawl.json" -a -f "$W/empty/crawl.json" -a -f "$W/nothing/crawl.json" -a -f "$W/deps2/crawl.json"

# --- Two identical repositories: two commits sharing a tree, then four more with trees of their own ----------------
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_AUTHOR_DATE="2020-02-02T00:00:00+0000" GIT_COMMITTER_DATE="2020-02-02T00:00:00+0000"
G() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
export -f G
mkdir "$W/seed" && cd "$W/seed" && G init -q -b main . && echo one >f.txt && G add f.txt && G commit -q -m one
C1=$(G rev-parse HEAD)
G commit -q --allow-empty -m "same tree as one"; C2=$(G rev-parse HEAD)
for n in 3 4 5 6 7 8; do echo "v$n" >f.txt; G commit -q -am "v$n"; eval "C$n=\$(G rev-parse HEAD)"; done
cd "$ROOT"
cp -R "$W/seed" "$W/repo-py"; cp -R "$W/seed" "$W/repo-app"
step "the repository has two commits with one tree" test "$(G -C "$W/seed" rev-parse "$C1^{tree}")" = "$(G -C "$W/seed" rev-parse "$C2^{tree}")" -a "$C1" != "$C2"

snapshot() { # snapshot (py|app) REPO ARGS...   stdout: the JSON, stderr: the commit line
  local who=$1; shift
  if [ "$who" = py ]; then python3 "$PY" "$@"; else "$BIN" --map-import "$@"; fi
}
COMMON=(--engine 0.9.1 --walked 2023-11-14T22:13:20Z --write-refs)
# name | walk | commit | extra options
CASES=(
  "store walk A|$W/store/walk-a|$C1|"
  "store walk B, profile from a file|$W/store/walk-b|$C3|--profile-file $W/profile.json"
  "unicode, quotes, controls, odd seconds, missing captures|$W/unicode|$C4|--combos light,dark --depth 3 --seconds 90 --start app://x --start app://y --offline --sign-in demo"
  "empty edge list, whole seconds|$W/empty|$C5|"
  "no screens|$W/nothing|$C6|--depth 1"
  "deps, start deps, unreliable, walked and carried|$W/deps|$C7|"
  "seeded: carried entries take the seed's commit and deps|$W/deps2|$C8|--seed-snapshot $W/py-6.json"
)
echo '{"depth": 4, "seconds": 60, "combos": ["light", "dark"], "starts": []}' > "$W/profile.json"
n=0
for c in "${CASES[@]}"; do
  n=$((n+1)); IFS='|' read -r name walk commit extra <<<"$c"
  # shellcheck disable=SC2086
  snapshot py "$walk" --repo "$W/repo-py" --commit "$commit" $extra "${COMMON[@]}" >"$W/py-$n.json" 2>"$W/py-$n.err"; pyc=$?
  # shellcheck disable=SC2086
  snapshot app "$walk" --repo "$W/repo-app" --commit "$commit" $extra "${COMMON[@]}" >"$W/app-$n.json" 2>"$W/app-$n.err"; appc=$?
  step "[$name] both succeed" test $pyc -eq 0 -a $appc -eq 0
  step "[$name] the JSON is the same bytes" cmp "$W/py-$n.json" "$W/app-$n.json"
  step "[$name] the snapshot commit id is the same" test -n "$(grep '^snapshot-commit: ' "$W/py-$n.err")" -a "$(grep '^snapshot-commit: ' "$W/py-$n.err")" = "$(grep '^snapshot-commit: ' "$W/app-$n.err")"
  step "[$name] the stored map.json is the printed JSON" bash -c "cmp <(G -C '$W/repo-py' cat-file blob \"\$(sed -n 's/^snapshot-commit: //p' '$W/py-$n.err'):map.json\") '$W/py-$n.json'"
done
[ -s "$W/py-3.json" ] && grep -q 'Réservations' "$W/py-3.json" && grep -q '"seconds" : 1234.5678' "$W/py-3.json" && grep -q '"seconds" : 7' "$W/py-4.json" && grep -q '"edges" : \[' "$W/py-4.json"
step "the fixtures reached the JSON (unicode, fractional seconds, empty lists)" test $? -eq 0
python3 - "$W/py-6.json" "$W/py-7.json" "$C7" <<'PY'
import json, sys
a, b, c7 = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
s = {x["id"]: x for x in a["screens"]}
t = {x["id"]: x for x in b["screens"]}
ok = (s["Deps-0001"]["deps"]["sources"] == sorted(s["Deps-0001"]["deps"]["sources"]) and "carriedFrom" not in s["Deps-0001"]
      and s["Deps-0002"]["carriedFrom"] == "unknown" and s["Deps-0002"]["deps"] == {"classes": [], "resources": [], "sources": []}
      and s["Deps-0003"]["deps"] == {"classes": [], "resources": ["r/x"], "sources": []} and "deps" not in s["Deps-0004"]
      and a["startDeps"]["resources"] == ["mipmap/ic_launcher", "style/Theme.App"] and a["depsUnreliable"].startswith("the probes")
      and t["Deps-0001"]["carriedFrom"] == c7 and t["Deps-0001"]["deps"] == s["Deps-0001"]["deps"]
      and t["Deps-0002"]["carriedFrom"] == "unknown" and t["Deps-0009"]["carriedFrom"] == c7
      and t["Deps-0009"]["deps"]["sources"] == ["com/example/New.kt"] and "carriedFrom" not in t["Deps-0010"] and "depsUnreliable" not in b
      and b["incomplete"] == ["--max-depth 3: Deps-0002 not explored", "--max-seconds 9"])
sys.exit(0 if ok else 1)
PY
step "deps, start deps and carried screens read as the contract says" test $? -eq 0
step "a capture that is missing or leads out of the walk is left out" bash -c "! grep -q 'missing.png\|outside' '$W/py-3.json' && grep -c '\"captures\" : {' '$W/py-3.json' | grep -q ."

refs() { G -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/greenroom; }
refs "$W/repo-py" >"$W/refs-py.txt"; refs "$W/repo-app" >"$W/refs-app.txt"
step "both repositories hold the same refs, pointing at the same commits ($(wc -l <"$W/refs-py.txt" | tr -d ' '))" bash -c "test -s '$W/refs-py.txt' && cmp '$W/refs-py.txt' '$W/refs-app.txt'"
step "the same objects are stored" bash -c "diff <(cd '$W/repo-py/.git/objects' && find . -type f | sort) <(cd '$W/repo-app/.git/objects' && find . -type f | sort)"
step "every one has a tree ref with its own commit's snapshot" bash -c "grep -c '/tree/' '$W/refs-py.txt' | grep -q '^7$'"

# --- Found by commit, or by tree ----------------------------------------------------------------------------------
step "--has: the script finds the commit walked" python3 "$PY" --has "$C1" --repo "$W/repo-py"
step "--has: the script finds the second commit, by its tree" python3 "$PY" --has "$C2" --repo "$W/repo-py"
step "--has: the script does not find a commit nobody walked" bash -c "! python3 '$PY' --has '$C3' --repo '$W/repo-py'"
step "--has: another profile is another history" bash -c "! python3 '$PY' --has '$C1' --repo '$W/repo-py' --depth 9"
step "--has: the app finds the second commit, by its tree" "$BIN" --map-import --has "$C2" --repo "$W/repo-py"
step "--has: the app finds what the script wrote, and the script what the app wrote" bash -c "'$BIN' --map-import --has '$C1' --repo '$W/repo-py' && python3 '$PY' --has '$C1' --repo '$W/repo-app'"
step "--has: the app does not find a commit nobody walked" bash -c "! '$BIN' --map-import --has '$C2' --repo '$W/repo-py' --depth 9"

# --- Twice changes nothing; the checkout is left alone --------------------------------------------------------------
G -C "$W/repo-py" status --porcelain >"$W/status0"; G -C "$W/repo-py" rev-parse HEAD >"$W/head0"
G -C "$W/repo-py" for-each-ref refs/heads refs/tags >"$W/heads0"; G -C "$W/repo-py" for-each-ref >"$W/all0"
(cd "$W/repo-py/.git" && find . -type f -not -name '*.lock' | sort | xargs shasum 2>/dev/null | grep -v 'index\|logs/' ) >"$W/files0" 
for k in 1 2; do python3 "$PY" "$W/store/walk-a" --repo "$W/repo-py" --commit "$C1" --engine 0.9.1 --walked 2023-11-14T22:13:20Z --write-refs >"$W/again-$k.json" 2>/dev/null; done
step "running the script twice prints the same bytes" bash -c "cmp '$W/again-1.json' '$W/again-2.json' && cmp '$W/again-1.json' '$W/py-1.json'"
G -C "$W/repo-py" for-each-ref >"$W/all1"
(cd "$W/repo-py/.git" && find . -type f -not -name '*.lock' | sort | xargs shasum 2>/dev/null | grep -v 'index\|logs/' ) >"$W/files1"
step "running it twice changes no ref and no stored object" bash -c "cmp '$W/all0' '$W/all1' && cmp '$W/files0' '$W/files1'"
step "git status is clean" test ! -s "$W/status0" -a -z "$(G -C "$W/repo-py" status --porcelain)"
step "HEAD, branches and tags are untouched" bash -c "test \"\$(G -C '$W/repo-py' rev-parse HEAD)\" = \"\$(cat '$W/head0')\" -a \"\$(G -C '$W/repo-py' rev-parse HEAD)\" = '$C8' && cmp '$W/heads0' <(G -C '$W/repo-py' for-each-ref refs/heads refs/tags) && cmp '$W/heads0' <(G -C '$W/seed' for-each-ref refs/heads refs/tags)"
step "nothing is written outside refs/greenroom/" bash -c "test -z \"\$(G -C '$W/repo-py' for-each-ref --format='%(refname)' | grep -v '^refs/heads/main\$' | grep -v '^refs/greenroom/maps/')\""
step "the working tree is as it was" bash -c "cmp '$W/seed/f.txt' '$W/repo-py/f.txt'"

if [ $FAILED -eq 0 ]; then echo "map-snapshot check: PASS"; else echo "map-snapshot check: FAIL"; exit 1; fi
