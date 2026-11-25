#!/usr/bin/env python3
"""Turns an engine walk (crawl.json and its captures) into a Greenroom map snapshot, without Greenroom.

    map-snapshot.py WALK_DIR --repo REPO --commit SHA [--profile-file .greenroom/map.json]
                    [--depth N] [--seconds N] [--start LINK]... [--combos light,dark] [--sign-in NAME] [--offline]
                    --engine VERSION --walked ISO_DATE [--seed-snapshot SEED_JSON] [--write-refs]
    map-snapshot.py --has SHA --repo REPO [profile options]

It must write the very bytes, and the very git objects, that the app writes (MapStore.importWalk, MapSnapshot.data(),
MapGit.write in Sources/Greenroom), so a snapshot made by CI on Linux and one made on a Mac never disagree. Python 3
standard library only; git is used through its plumbing and nothing outside refs/greenroom/ is touched.

--seed-snapshot: for a walk seeded from an earlier one (crawl.py --seed), that walk's snapshot JSON: a screen marked
"origin": "carried" takes its carriedFrom (and, when it has none of its own, its deps) from it, as the app's import does.

stdout: the snapshot JSON (the bytes of map.json). With --write-refs, stderr gets `snapshot-commit: <git commit id>`.
--has exits 0 when SHA, or a commit with its tree, already has a snapshot for the profile; 1 when not.
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import unicodedata

NAMESPACE = "refs/greenroom/maps"
SCHEMA = 1


# ---- JSON exactly as Foundation's JSONEncoder writes it (prettyPrinted, sortedKeys, withoutEscapingSlashes) --------

class Float(float):
    """A Double: written the way Swift prints one."""


def _string(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"': out.append('\\"')
        elif ch == "\\": out.append("\\\\")
        elif ch == "\n": out.append("\\n")
        elif ch == "\r": out.append("\\r")
        elif ch == "\t": out.append("\\t")
        elif ch == "\b": out.append("\\b")
        elif ch == "\f": out.append("\\f")
        elif o < 0x20: out.append("\\u%04x" % o)
        else: out.append(ch)       # "/", DEL, U+2028 and everything non-ASCII stay as they are
    out.append('"')
    return "".join(out)


def _double(x):
    t = repr(float(x))
    return t[:-2] if t.endswith(".0") else t        # Swift prints 12.0 as 12; its exponents read like Python's


def _value(v, indent):
    pad, inner = "  " * indent, "  " * (indent + 1)
    if v is None: return "null"
    if v is True: return "true"
    if v is False: return "false"
    if isinstance(v, Float): return _double(v)
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return _string(v)
    if isinstance(v, (list, tuple)):
        if not v: return "[\n\n" + pad + "]"            # Foundation prints an empty array with a blank line
        return "[\n" + ",\n".join(inner + _value(x, indent + 1) for x in v) + "\n" + pad + "]"
    if isinstance(v, dict):
        if not v: return "{\n\n" + pad + "}"
        keys = sorted(v, key=lambda k: k.encode("utf-8"))
        return "{\n" + ",\n".join(inner + _string(k) + " : " + _value(v[k], indent + 1) for k in keys) + "\n" + pad + "}"
    raise TypeError(type(v))


def encode(v):
    return (_value(v, 0) + "\n").encode("utf-8")


# ---- The profile ---------------------------------------------------------------------------------------------------

def profile_object(a):
    """MapProfile's own encoding: optional signIn is left out when unset, as the synthesized Codable does."""
    p = {"depth": 0, "seconds": 0, "starts": [], "combos": ["light"], "offline": False}
    if a.profile_file:
        with open(a.profile_file, "rb") as f:
            d = json.load(f)
        for k in ("depth", "seconds"):
            if isinstance(d.get(k), int) and not isinstance(d.get(k), bool): p[k] = d[k]
        for k in ("starts", "combos"):
            if isinstance(d.get(k), list) and all(isinstance(x, str) for x in d[k]): p[k] = d[k]
        if isinstance(d.get("signIn"), str) and d["signIn"]: p["signIn"] = d["signIn"]
        if isinstance(d.get("offline"), bool): p["offline"] = d["offline"]
    if a.depth is not None: p["depth"] = a.depth
    if a.seconds is not None: p["seconds"] = a.seconds
    if a.start: p["starts"] = a.start
    if a.combos is not None: p["combos"] = [c for c in a.combos.split(",") if c]
    if a.sign_in: p["signIn"] = a.sign_in
    if a.offline: p["offline"] = True
    return p


def profile_id(p):
    return hashlib.sha256(encode(p)).hexdigest()[:8]


# ---- crawl.json to a snapshot (MapStore.importWalk) ----------------------------------------------------------------

def nfc(s):
    return unicodedata.normalize("NFC", s)      # Swift compares Strings by canonical equivalence


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def str_list(v):
    return list(v) if isinstance(v, list) and all(isinstance(x, str) for x in v) else None


def deps_of(v):
    """crawl.json's deps object (MapStore.deps): each list when it is a list of strings, else empty; None when not an object."""
    if not isinstance(v, dict): return None
    return {k: str_list(v.get(k)) or [] for k in ("classes", "sources", "resources")}


def sorted_deps(d):
    return {k: sorted(d[k], key=nfc) for k in ("classes", "sources", "resources")}


def import_walk(walk, commit, tree, profile, engine, walked, seed=None):
    """Returns (snapshot dict, {capture sha256: file}) or None when there is no readable crawl.json."""
    try:
        with open(os.path.join(walk, "crawl.json"), "rb") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("screens"), list) or not all(isinstance(s, dict) for s in data["screens"]):
        return None

    root = os.path.realpath(walk)
    files, hashes = {}, {}

    def blob(rel):
        if rel in hashes: return hashes[rel]
        path = os.path.realpath(os.path.join(walk, rel))
        if not path.startswith(root.rstrip("/") + "/") or not os.path.isfile(path): return None
        try:
            with open(path, "rb") as f:
                h = hashlib.sha256(f.read()).hexdigest()
        except OSError:
            return None
        files[h] = path
        hashes[rel] = h
        return h

    screens = []
    for s in data["screens"]:
        sid = s.get("id")
        if not isinstance(sid, str): continue
        path = s.get("path") if isinstance(s.get("path"), dict) else {}
        captures = {}
        caps = s.get("captures")
        if isinstance(caps, dict) and all(isinstance(v, str) for v in caps.values()):
            for combo, rel in caps.items():
                h = blob(rel)
                if h: captures[combo] = h
        act = s.get("activity") if isinstance(s.get("activity"), str) else sid
        parts = [p for p in act.split(".") if p]
        depth = s.get("depth")
        if isinstance(depth, float) and depth == int(depth): depth = int(depth)
        screen = {"id": sid, "lineage": "", "activity": parts[-1] if parts else sid, "title": s["title"] if isinstance(s.get("title"), str) else "",
                  "depth": depth if is_int(depth) else 0, "steps": str_list(path.get("steps")) or [], "captures": captures,
                  "texts": str_list(s.get("texts")) or [], "settled": s["settled"] if isinstance(s.get("settled"), bool) else True}
        if isinstance(s.get("parent"), str): screen["parent"] = s["parent"]
        if isinstance(path.get("start"), str): screen["start"] = path["start"]
        if isinstance(s.get("flaky"), str): screen["flaky"] = s["flaky"]
        deps = deps_of(s.get("deps"))
        if s.get("origin") == "carried":
            was = next((x for x in seed["screens"] if x.get("id") == sid), None) if seed else None
            if was is not None: screen["carriedFrom"] = was["carriedFrom"] if isinstance(was.get("carriedFrom"), str) else seed["commit"]
            else: screen["carriedFrom"] = seed["commit"] if seed else "unknown"
            if deps is None and was is not None and isinstance(was.get("deps"), dict): deps = deps_of(was["deps"])
        if deps is not None: screen["deps"] = sorted_deps(deps)
        screens.append(screen)

    nxt, edges = {}, []
    for e in data["edges"] if isinstance(data.get("edges"), list) and all(isinstance(x, dict) for x in data["edges"]) else []:
        frm = e.get("from")
        if not isinstance(frm, str): continue
        order = nxt.get(frm, 0)
        nxt[frm] = order + 1
        edge = {"from": frm, "order": order, "action": e["action"] if isinstance(e.get("action"), str) else "",
                "cmd": e["cmd"] if isinstance(e.get("cmd"), str) else ""}
        if isinstance(e.get("to"), str): edge["to"] = e["to"]
        if isinstance(e.get("note"), str): edge["note"] = e["note"]
        edges.append(edge)

    findings = []
    for f in data["findings"] if isinstance(data.get("findings"), list) and all(isinstance(x, dict) for x in data["findings"]) else []:
        p = f.get("path") if isinstance(f.get("path"), dict) else {}
        findings.append({"kind": f["kind"] if isinstance(f.get("kind"), str) else "", "detail": f["detail"] if isinstance(f.get("detail"), str) else "",
                         "steps": str_list(p.get("steps")) or []})

    total = data["seconds"].get("total") if isinstance(data.get("seconds"), dict) else None
    seconds = float(total) if isinstance(total, (int, float)) and not isinstance(total, bool) else 0.0

    # canonical(): screens by id, edges by (from, order, cmd)
    screens.sort(key=lambda s: nfc(s["id"]))
    edges.sort(key=lambda e: (nfc(e["from"]), e["order"], nfc(e["cmd"])))
    snap = {"schema": SCHEMA, "commit": commit, "tree": tree, "profile": profile, "engine": engine, "walked": walked,
            "screens": screens, "edges": edges, "findings": findings,
            "incomplete": [x[6:] if x.startswith("seed: ") else x for x in str_list(data.get("incomplete")) or []], "seconds": Float(seconds)}
    start = deps_of(data.get("start_deps"))
    if start is not None: snap["startDeps"] = sorted_deps(start)
    if isinstance(data.get("deps_unreliable"), str): snap["depsUnreliable"] = data["deps_unreliable"]
    return snap, files


# ---- git (MapGit) --------------------------------------------------------------------------------------------------

IDENTITY = {"GIT_AUTHOR_NAME": "Greenroom", "GIT_AUTHOR_EMAIL": "greenroom@localhost", "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000",
            "GIT_COMMITTER_NAME": "Greenroom", "GIT_COMMITTER_EMAIL": "greenroom@localhost", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000"}


def git(repo, args, input=None, env=None):
    e = dict(os.environ)
    for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY"): e.pop(k, None)
    e.update({"GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"})
    e.update(env or {})
    r = subprocess.run(["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "gc.auto=0"] + args,
                       cwd=repo, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    return r.returncode, r.stdout, r.stderr.decode("utf-8", "replace").strip()


def fail(msg):
    sys.stderr.write("map-snapshot: %s\n" % msg)
    sys.exit(2)


def safe(s):
    return bool(s) and not s.startswith((".", "-")) and ".." not in s and all(c.isascii() and (c.isalnum() or c in "._-") for c in s)


def enc_name(name):
    out = []
    for i, b in enumerate(name.encode("utf-8")):
        c = chr(b)
        plain = b < 128 and (c.isalnum() or c in "_-@" or (c == "." and i > 0))
        out.append(c if plain else "%%%02X" % b)
    return "".join(out) or "%00"


def tree_of(repo, commit):
    code, out, err = git(repo, ["rev-parse", "--verify", "-q", "--end-of-options", commit + "^{tree}"])
    return out.decode().strip() if code == 0 and out.strip() else None


def write_refs(repo, snap, files):
    profile = profile_id(snap["profile"])
    if not safe(snap["commit"]): fail("the snapshot's commit is not a name git can keep: " + snap["commit"])
    if not safe(snap["tree"]): fail("the snapshot's tree is not a name git can keep: " + snap["tree"])

    def run(args, what, input=None, env=None):
        code, out, err = git(repo, args, input=input, env=env)
        text = out.decode().strip()
        if code != 0 or not text: fail("git %s failed: %s" % (what, err))
        return text

    data = encode(snap)
    mp = run(["hash-object", "-w", "--no-filters", "--stdin"], "hash-object (map.json)", input=data)
    wanted = []
    for s in snap["screens"]:
        for h in sorted(s["captures"].values()):
            if h not in wanted: wanted.append(h)
    git_blob = {}
    if wanted:
        ids = run(["hash-object", "-w", "--no-filters", "--stdin-paths"], "hash-object (captures)",
                  input=("\n".join(files[h] for h in wanted) + "\n").encode("utf-8")).split("\n")
        if len(ids) != len(wanted): fail("git hash-object failed on the captures")
        git_blob = dict(zip(wanted, ids))
    folders = {}
    for s in snap["screens"]:
        for combo, h in s["captures"].items():
            folders.setdefault(enc_name(s["lineage"] or s["id"]), []).append("100644 blob %s\t%s.png" % (git_blob[h], enc_name(combo)))
    root = ["100644 blob %s\tmap.json" % mp]
    if folders:
        names = sorted(folders, key=lambda n: n.encode("utf-8"))
        ids = run(["mktree", "--batch"], "mktree", input="\n".join("\n".join(folders[n]) + "\n" for n in names).encode("utf-8")).split("\n")
        if len(ids) != len(names): fail("git mktree failed")
        sub = run(["mktree"], "mktree", input=("\n".join("040000 tree %s\t%s" % (i, n) for i, n in zip(ids, names)) + "\n").encode("utf-8"))
        root.append("040000 tree %s\tscreens" % sub)
    tree = run(["mktree"], "mktree", input=("\n".join(root) + "\n").encode("utf-8"))
    message = "Map of %s (profile %s)" % (snap["commit"][:7], profile)
    commit = run(["commit-tree", tree, "-m", message], "commit-tree", env=IDENTITY)
    if git(repo, ["update-ref", "%s/%s/%s" % (NAMESPACE, profile, snap["commit"]), commit])[0] != 0: fail("git update-ref failed")
    git(repo, ["update-ref", "%s/%s/tree/%s" % (NAMESPACE, profile, snap["tree"]), commit, "0" * 40])    # the first snapshot of a tree keeps it
    return commit


def has(repo, profile, commit):
    if not safe(profile) or not commit or commit.startswith("-"): return False
    if safe(commit) and git(repo, ["rev-parse", "--verify", "-q", "%s/%s/%s^{commit}" % (NAMESPACE, profile, commit)])[0] == 0: return True
    t = tree_of(repo, commit)
    return bool(t) and git(repo, ["rev-parse", "--verify", "-q", "%s/%s/tree/%s^{commit}" % (NAMESPACE, profile, t)])[0] == 0


# ---- main ----------------------------------------------------------------------------------------------------------

def iso(text):
    """ISO8601DateFormatter's output for the date: UTC, whole seconds, a Z."""
    t = text.strip()
    if t.endswith("Z"): t = t[:-1] + "+00:00"
    try:
        d = datetime.datetime.fromisoformat(t)
    except ValueError:
        fail("--walked is not an ISO 8601 date: " + text)
    if d.tzinfo is None: fail("--walked needs a time zone (Z or +hh:mm): " + text)
    return d.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("walk", nargs="?", help="the walk's folder (crawl.json and its captures)")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--commit")
    ap.add_argument("--has", metavar="SHA")
    ap.add_argument("--profile-file")
    ap.add_argument("--depth", type=int)
    ap.add_argument("--seconds", type=int)
    ap.add_argument("--start", action="append")
    ap.add_argument("--combos")
    ap.add_argument("--sign-in")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--engine")
    ap.add_argument("--walked")
    ap.add_argument("--seed-snapshot")
    ap.add_argument("--write-refs", action="store_true")
    a = ap.parse_args()

    profile = profile_object(a)
    if a.has:
        sys.exit(0 if has(a.repo, profile_id(profile), a.has) else 1)
    if not (a.walk and a.commit and a.engine and a.walked): ap.error("WALK_DIR, --commit, --engine and --walked are required")
    tree = tree_of(a.repo, a.commit)
    if not tree: fail("no such commit in %s: %s" % (a.repo, a.commit))
    seed = None
    if a.seed_snapshot:
        try:
            with open(a.seed_snapshot, "rb") as f:
                seed = json.load(f)
        except (OSError, ValueError):
            fail("--seed-snapshot is not a readable snapshot: " + a.seed_snapshot)
        if not isinstance(seed, dict) or not isinstance(seed.get("commit"), str) or not isinstance(seed.get("screens"), list):
            fail("--seed-snapshot is not a snapshot: " + a.seed_snapshot)
    got = import_walk(a.walk, a.commit, tree, profile, a.engine, iso(a.walked), seed)
    if not got: fail("no readable crawl.json in " + a.walk)
    snap, files = got
    sys.stdout.buffer.write(encode(snap))
    sys.stdout.buffer.flush()
    if a.write_refs:
        sys.stderr.write("snapshot-commit: %s\n" % write_refs(a.repo, snap, files))


if __name__ == "__main__":
    main()
