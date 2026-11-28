#!/usr/bin/env python3
"""Checks the agent interface as an agent uses it: `Greenroom --mcp` on stdin/stdout, against the bundled test app.
Usage: scripts/mcp-check.py GREENROOM_EXECUTABLE APK [--sessions | --tools | --history]
--tools: the --sessions setup, then only the tools for the rest of Greenroom (more_tools), not the session tools.
--history: `changes` and `history` from stored maps, with no walk and no simulator (a temporary repository whose store is seeded
from MapFixtures' golden pair `mixed` by GREENROOM_CHECK_HISTORY_SEED; APK is not used).
--sessions: the agent tied to its worktree's session (a temporary git repository with two worktrees, a state folder
of its own), and the session tools: session, build (a stand-in recipe), changes (against the same build and against
a base that differs through crawl.py's --base-option), screenshot's screen, and the recording of the agent's session;
without it, the interface itself against the person's own state folder.
Starts Greenroom (its executable, in the background) if it is not running, and quits the copy it started."""
import glob, hashlib, json, os, re, shutil, signal, subprocess, sys, tempfile, threading, time, urllib.parse, urllib.request, zipfile

exe, apk = sys.argv[1], sys.argv[2]


def remove(folder):
    """The engine's children can still be writing their cache for a moment after the app quit."""
    for _ in range(10):
        if subprocess.run(["rm", "-rf", folder], stderr=subprocess.DEVNULL).returncode == 0:
            return
        time.sleep(0.5)
    subprocess.run(["rm", "-rf", folder])

def sessions_mode():
    """Two worktrees of a temporary repository, each with the test app as its build; the repository is added to a
    fresh state folder (GREENROOM_STATE, GREENROOM_ADD_REPOSITORY); a shim is run from inside each worktree."""
    root = os.path.realpath(tempfile.mkdtemp(prefix="grmcp-", dir="/tmp"))   # short: the engine's sockets live under it
    repo, state_dir, other = root + "/repo", root + "/state", root + "/elsewhere"
    def git(*a, cwd=repo):
        subprocess.run(["/usr/bin/git", "-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false", *a],
                       cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.makedirs(repo); os.makedirs(other); os.makedirs(state_dir)
    open(repo + "/README.md", "w").write("hello\n")
    open(repo + "/.gitignore", "w").write("build/\n")
    git("init", "-q", "-b", "main"); git("add", "."); git("commit", "-q", "-m", "first")
    trees = {}
    for name in ("a", "b"):
        wt = f"{root}/wt-{name}"
        git("worktree", "add", "-q", "-b", "feat-" + name, wt)
        out = wt + "/app/build/outputs/apk/debug"
        os.makedirs(out)
        subprocess.run(["cp", apk, out + "/app-debug.apk"], check=True)
        os.makedirs(wt + "/app/src/deeper")
        trees[name] = wt
    # A second repository whose workspace has the recording switch off.
    repo2 = root + "/repo2"
    os.makedirs(repo2)
    open(repo2 + "/README.md", "w").write("hello\n")
    open(repo2 + "/.gitignore", "w").write("build/\n")
    git("init", "-q", "-b", "main", cwd=repo2); git("add", ".", cwd=repo2); git("commit", "-q", "-m", "first", cwd=repo2)
    os.makedirs(repo2 + "/app/build/outputs/apk/debug")
    subprocess.run(["cp", apk, repo2 + "/app/build/outputs/apk/debug/app-debug.apk"], check=True)
    # Two repositories nobody added: one with an app in it, one with none. An agent's call adds the first only.
    repo3, repo4 = root + "/repo3", root + "/repo4"
    for r in (repo3, repo4):
        os.makedirs(r)
        open(r + "/README.md", "w").write("hello\n")
        open(r + "/.gitignore", "w").write("build/\n")
        git("init", "-q", "-b", "main", cwd=r); git("add", ".", cwd=r); git("commit", "-q", "-m", "first", cwd=r)
    os.makedirs(repo3 + "/app/build/outputs/apk/debug")
    subprocess.run(["cp", apk, repo3 + "/app/build/outputs/apk/debug/app-debug.apk"], check=True)
    def variant(name):
        """The test APK with one more file in it: another build (another key) that runs the same."""
        dst = f"{root}/{name}.apk"
        shutil.copy(apk, dst)
        with zipfile.ZipFile(dst, "a") as z:
            z.writestr(f"assets/greenroom-check-{name}.txt", name)
        return dst
    built_apk, base_apk = variant("built"), variant("base")
    def key_of(path):
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]
    # The stand-in recipe, the workspace's `local` one: records its environment, copies a build, or fails on request.
    recipe = root + "/recipe.sh"
    open(recipe, "w").write(f"""#!/bin/sh
env | grep '^GREENROOM_' | sort > "{root}/recipe-env.txt"
if [ -f "{root}/recipe-fail" ]; then echo "> Task :app:compileDebugKotlin FAILED"; echo "e: Foo.kt: error: unresolved reference: boom"; exit 1; fi
if [ -f "{root}/recipe-sleep" ]; then sleep 8; fi
cp "{built_apk}" "$GREENROOM_OUT"
""")
    os.chmod(recipe, 0o755)
    env = dict(os.environ, GREENROOM_STATE=state_dir, GREENROOM_ADD_REPOSITORY=repo + "\n" + repo2, GREENROOM_CHECK_FEEDS="1",
               GREENROOM_CHECK_RECIPE=recipe, GREENROOM_CHECK_AUTO="off", GREENROOM_CHECK_ADOPT="1", GREENROOM_CHECK_AGENT_IDLE="3", GREENROOM_CHECK_RECORD_OFF=repo2,
               GREENROOM_CHECK_CRAWL_START="apksim://slot", GREENROOM_CHECK_CRAWL_DEPTH="1", GREENROOM_CHECK_CRAWL_SECONDS="40",
               GREENROOM_CHECK_BASE_OPTION="--setting global:apksim_slot_seed=base")
    app_log = open(root + "/app.log", "w")
    app = subprocess.Popen([exe, "--background", "--agent-check"], stdout=app_log, stderr=subprocess.STDOUT, env=env)
    failures, shims = [], []
    def expect(what, ok, got=""):
        verbose = os.environ.get("MCP_CHECK_VERBOSE") and got   # every answer, to read what an agent reads
        print(("ok   " if ok else "FAIL ") + what + ("" if ok and not verbose else "\n     got: " + str(got)[:1500 if verbose else 400].replace("\n", "\n          ")))
        if not ok:
            failures.append(what)
    class Shim:
        def __init__(self, cwd):
            self.p = subprocess.Popen([exe, "--mcp", "--agent-check"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1, cwd=cwd, env=env)
            self.n = 0
            shims.append(self)
            self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp-check", "version": "1"}})
        def rpc(self, method, params=None):
            self.n += 1
            self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
            self.p.stdin.flush()
            line = self.p.stdout.readline()
            if not line:
                raise SystemExit("mcp-check: the shim closed its output")
            return json.loads(line)
        def call(self, tool, **args):
            r = self.rpc("tools/call", {"name": tool, "arguments": args}).get("result", {})
            return "\n".join(c["text"] for c in r.get("content", []) if c["type"] == "text"), bool(r.get("isError"))
    def slot(path):
        path = path[len("/private"):] if path.startswith(("/private/tmp", "/private/var", "/private/etc")) else path   # as Foundation resolves it
        return "gr" + hashlib.sha256(path.encode()).hexdigest()[:8]
    def feeds():
        try:
            return json.load(open(state_dir + "/agent-feeds-check.json"))
        except Exception:
            return {}
    def wait(cond, seconds=30):
        end = time.time() + seconds
        while time.time() < end:
            v = cond()
            if v:
                return v
            time.sleep(0.2)
        return None
    try:
        agent = state_dir + "/agent.json"
        def up():
            try:
                os.kill(json.load(open(agent))["pid"], 0); return True
            except Exception:
                return False
        if not wait(up, 60):
            sys.exit("mcp-check: Greenroom did not start its agent endpoint within 60 s\n" + open(root + "/app.log", errors="replace").read()[-2000:])
        a, b, sub, away = Shim(trees["a"]), Shim(trees["b"]), Shim(trees["a"] + "/app/src/deeper"), Shim(other)
        # The repository is added by the app at launch, and its rows are read from git a moment later.
        t, err = "", True
        end = time.time() + 60
        while time.time() < end:
            t, err = a.call("launch")
            if not err or "not a worktree" not in t:
                break
            time.sleep(0.5)
        expect("launch without apk in a worktree starts that worktree's simulator", not err and "launched app-debug.apk for feat-a" in t, t)
        sims, _ = a.call("simulators")
        expect("simulators lists it with its session's branch and data slot",
               "(session feat-a)" in sims and f"--data-slots {slot(trees['a'])}" in sims, sims)
        t, err = b.call("launch")
        expect("the other worktree gets a simulator of its own", not err and "for feat-b" in t, t)
        sims, _ = b.call("simulators")
        expect("with its own data slot", f"--data-slots {slot(trees['b'])}" in sims and slot(trees["a"]) != slot(trees["b"]), sims)
        t, err = a.call("tap", sim=next((l.split()[0] for l in sims.split("\n") if "feat-a" in l), "s1"), text="Add")
        expect("an action reaches the simulator that was named", not err and "FAB clicks" in t, t)
        t, err = sub.call("launch")
        expect("a subfolder of a worktree is tied to that worktree (its simulator is selected, not started twice)",
               not err and "for feat-a" in t or "the session's running simulator" in t, t)
        expect("... and says it was already running", "already running" in t, t)
        t, err = away.call("launch")
        expect("a folder outside every added worktree gets the clear failure",
               err and t == "this folder is not a worktree of a repository added to Greenroom: pass apk", t)
        t, err = away.call("launch", apk=apk, fresh=True)
        expect("... and still works with an apk", not err and "launched" in t and "for feat" not in t, t)
        sims, _ = away.call("simulators")
        expect("its simulator belongs to no session", any("(session" not in l and "s3" in l.split()[0:1] for l in sims.split("\n") if l.startswith("s")) , sims)
        # Data: a marker in a session's slot folder must survive a fresh launch and a replacement.
        marker = "mcp-check-marker"
        def slot_dirs(sl):
            return [d for d in glob.glob(state_dir + f"/engine/cache/data/*/{sl}-*") if not d.endswith(".device") and os.path.isdir(d)]
        def has_marker(sl):
            return any(os.path.exists(d + "/" + marker) for d in slot_dirs(sl))
        for who in "ab":
            wait(lambda: slot_dirs(slot(trees[who])), 30)
            for d in slot_dirs(slot(trees[who])):
                open(d + "/" + marker, "w").write("kept")
        expect("a marker is written in each session's data", has_marker(slot(trees["a"])) and has_marker(slot(trees["b"])), str(glob.glob(state_dir + "/engine/cache/data/*/*")))
        t, err = a.call("launch", fresh=True)
        expect("fresh inside a session runs beside it on a separate slot, and says so", not err and "separate slot" in t and "untouched" in t, t)
        sims, _ = a.call("simulators")
        expect("... marked as the session's, the session's own simulator still on its slot",
               sims.count("(session feat-a)") == 2 and sims.count(f"--data-slots {slot(trees['a'])} ") == 1 and "--fresh" in sims, sims)
        expect("... and the session's data is still there", has_marker(slot(trees["a"])))
        own = trees["b"] + "/app/build/outputs/apk/debug/app-debug.apk"
        before = len(slot_dirs(slot(trees["b"])))
        t, err = b.call("launch", apk=own)
        expect("the session's own build given as apk replaces its simulator", not err and "replaced the session's running simulator" in t, t)
        sims, _ = b.call("simulators")
        expect("... on the session's slot, once", sims.count(f"--data-slots {slot(trees['b'])} ") == 1 and sims.count("(session feat-b)") == 1, sims)
        expect("... with its data kept, in the same slot folder (no empty second slot)", has_marker(slot(trees["b"])) and len(slot_dirs(slot(trees["b"]))) == before,
               f"{before} folders before, {len(slot_dirs(slot(trees['b'])))} after")
        t, err = b.call("launch", apk=apk)
        sims, _ = b.call("simulators")
        expect("another APK from the worktree starts a separate simulator and leaves the session's alone",
               not err and "replaced" not in t and sims.count(f"--data-slots {slot(trees['b'])} ") == 1 and has_marker(slot(trees["b"])), t + "\n" + sims)
        # A request with no headers: what an older shim sends.
        info = json.load(open(agent))
        def raw(name, **args):
            req = urllib.request.Request(f"http://127.0.0.1:{info['port']}/mcp", method="POST",
                data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}).encode(),
                headers={"Authorization": "Bearer " + info["token"], "Content-Type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=200))["result"]
            return "\n".join(c["text"] for c in r["content"] if c["type"] == "text"), bool(r.get("isError"))
        t, err = raw("simulators")
        expect("a request with no headers works as before", not err and "app-debug.apk" in t, t)
        t, err = raw("launch")
        expect("... and has no session to launch for", err and "pass apk" in t, t)
        t, err = raw("launch", apk=apk, fresh=True)
        expect("... and launches an apk", not err and "launched" in t and "for feat" not in t, t)
        # The feeds, one per session.
        feeds_seen = wait(lambda: (lambda f: f if sum(len(v) for v in f.values()) >= 12 else None)(feeds()), 10) or feeds()
        by = {}
        for key, entries in feeds_seen.items():
            by[key] = entries
        feed_a = [e for k, v in by.items() for e in v if e["label"] == "feat-a"]
        feed_b = [e for k, v in by.items() for e in v if e["label"] == "feat-b"]
        none = by.get("", [])
        expect("each session has its own feed, and entries say which", len(by) == 3 and len(feed_a) >= 3 and len(feed_b) >= 3 and {e["label"] for e in feed_a} == {"feat-a"}, json.dumps(by)[:600])
        expect("feat-a's feed has its subfolder shim's call, feat-b's has none of a's",
               sum(e["tool"] == "launch" for e in feed_a) == 3 and sum(e["tool"] == "launch" for e in feed_b) == 3 and not any(e["tool"] == "tap" for e in feed_b), json.dumps(by)[:600])
        expect("calls from no session are a feed of their own", len(none) >= 4 and all(e["label"] == "" for e in none), json.dumps(none)[:400])
        if "--tools" not in sys.argv:
            session_tools(a, b, away, trees, repo2, state_dir, root, recipe, built_apk, base_apk, key_of, apk, slot, wait, expect, Shim, up)
        more_tools(a, away, trees, state_dir, apk, expect)
        command_line(exe, env, a, trees, other, root, state_dir, apk, expect, wait)
        adoption(repo3, repo4, state_dir, Shim, expect)
    finally:
        for s in shims:
            try:
                s.p.stdin.close(); s.p.wait(timeout=10)
            except Exception:
                s.p.kill()
        app.terminate()
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()
        if failures:
            print("the app's output:\n" + open(root + "/app.log", errors="replace").read()[-3000:])
        remove(root)
    print(f"mcp-check --sessions: {len(failures)} failed" if failures else "mcp-check --sessions: all passed")
    sys.exit(1 if failures else 0)

def adoption(repo3, repo4, state_dir, Shim, expect):
    """A repository adds itself (docs/AGENT-FIRST-SPEC.md): the first call from a worktree with an Android app in it adds
    its repository, so the agent brings the work. Not while agents are paused, and not a repository with no app in it."""
    stranger, plain = Shim(repo3), Shim(repo4)
    open(state_dir + "/agent-paused-check", "w").write("1")
    try:
        t, err = stranger.call("session")
        expect("paused: a call from a repository nobody added does not add it, and says why",
               err and "agents are paused, so repo3 was not added" in t, t)
    finally:
        os.remove(state_dir + "/agent-paused-check")
    t, err = stranger.call("session")
    expect("a call from a repository with an app in it adds the repository: the agent brings the work", not err and "main" in t, t)
    t, _ = stranger.call("sessions")
    expect("... and its session is listed", "repo3" in t, t)
    t, _ = stranger.call("workspace")
    expect("... its base branch is not fetched and built by itself", "keep_main = off" in t, t)
    t, err = stranger.call("launch")
    expect("... and launch without apk starts the worktree's build", not err and "launched app-debug.apk" in t, t)
    stranger.call("close")
    t, err = plain.call("session")
    expect("a repository with no Android app in it is not added, and the answer says why",
           err and "no Android app was found in repo4" in t, t)
    t, err = plain.call("launch")
    expect("... launch says the same, and still takes an apk",
           err and "no Android app was found in repo4" in t and t.endswith(": pass apk"), t)
    t, _ = plain.call("sessions")
    expect("... and it is not among the repositories", "repo4" not in t, t)


def command_line(exe, env, a, trees, other, root, state_dir, apk, expect, wait):
    """The `greenroom` command (Greenroom --cli ..., what bin/greenroom runs): the same tools from a shell, with an exit
    status a script can branch on; `greenroom hook`, which tells the app four words and nothing else; `greenroom open`
    and the links, which only navigate."""
    def cli(*args, cwd=trees["a"], stdin=None, state=None, seconds=120):
        e = dict(env, GREENROOM_STATE=state) if state else env
        started = time.time()
        p = subprocess.run([exe, "--agent-check", "--cli", *args], cwd=cwd, env=e, input=stdin if stdin is not None else "",
                           capture_output=True, text=True, timeout=seconds)
        return p.returncode, p.stdout.strip(), p.stderr.strip(), time.time() - started
    listed = [t["name"] for t in a.rpc("tools/list")["result"]["tools"]]
    code, out, err, _ = cli("tools")
    expect("greenroom tools lists every tool the MCP server has, one a line", code == 0 and [l.split()[0] for l in out.split("\n")] == listed, out[:300])
    code, out, err, _ = cli("help")
    expect("greenroom help says how it is used", code == 0 and "greenroom TOOL [ARGUMENTS]" in out and "greenroom hook EVENT" in out and "Exit status" in out, out[:300])
    code, out, err, _ = cli()
    expect("... and so does greenroom alone", code == 0 and "greenroom TOOL [ARGUMENTS]" in out, out[:200])
    code, out, err, _ = cli("help", "tap")
    expect("greenroom help TOOL gives one tool's arguments as flags", code == 0 and out.startswith("usage: greenroom tap") and "--text" in out and "--ref" in out, out[:400])
    code, out, err, _ = cli("help", "check")
    expect("... a list is shown as one", code == 0 and "[VISIBLE...]" in out.split("\n")[0] and "--absent  list (repeat the flag)" in out, out[:300])
    code, out, err, _ = cli("version")
    expect("greenroom version names the copy", code == 0 and out.startswith("Greenroom"), out)
    scheme = "greenroom-debug" if out.startswith("Greenroom Debug") else "greenroom"
    # A tool, with the same answer an agent gets.
    want, _ = a.call("session")
    code, out, err, _ = cli("session")
    expect("greenroom session, run in a worktree, is that worktree's session with the tool's own answer", code == 0 and out == want.strip() and err == "", out + "\n" + err)
    code, out, err, _ = cli("session", "-C", trees["b"], cwd=other)
    expect("-C DIR is the folder it acts in", code == 0 and "feat-b" in out and "feat-a" not in out, out + "\n" + err)
    code, out, err, _ = cli("session", cwd=other)
    expect("a tool that fails exits 1 and says why on stderr", code == 1 and out == "" and "not a worktree" in err, f"{code} {out!r} {err!r}")
    code, out, err, _ = cli("launch")
    sim = re.match(r"(s\d+)", out).group(1) if code == 0 and re.match(r"s\d+", out) else None
    expect("greenroom launch selects the session's running simulator", sim is not None and "already running" in out, out + "\n" + err)
    sim = sim or "s1"
    code, out, err, _ = cli("tap", "--text", "Add", "--sim", sim)
    expect("greenroom tap --text Add drives it and prints what changed", code == 0 and "FAB clicks" in out, out + "\n" + err)
    code, out, err, _ = cli("tap", "Add", f"--sim={sim}")
    expect("... the text given bare, a flag with =", code == 0 and "FAB clicks" in out, out + "\n" + err)
    code, out, err, _ = cli("tap", "--json", json.dumps({"text": "Add", "sim": sim}))
    expect("... and as JSON", code == 0 and "FAB clicks" in out, out + "\n" + err)
    code, out, err, _ = cli("check", "FAB clicks", "--sim", sim)
    expect("greenroom check answers PASS and exits 0", code == 0 and out.startswith("PASS"), f"{code} {out} {err}")
    code, out, err, _ = cli("check", "--visible", "FAB clicks", "--visible", "No such text here", "--absent", "Add", "--sim", sim)
    expect("... FAIL exits 1 with the answer on stdout, a list repeating its flag",
           code == 1 and out.startswith("FAIL") and "No such text here" in out and "Add" in out, f"{code} {out} {err}")
    shot = root + "/cli shots/one.png"
    code, out, err, _ = cli("screenshot", "--sim", sim, "--out", shot, "--max-size", "400")
    png = os.path.exists(shot) and open(shot, "rb").read(8) == b"\x89PNG\r\n\x1a\n"
    expect("greenroom screenshot --out FILE writes the picture there and prints its path", code == 0 and png and f"picture: {shot}" in out, f"{code} {out} {err}")
    code, out, err, _ = cli("screenshot", "--sim", sim, "--max-size", "200")
    at = next((l[len("picture: "):] for l in out.split("\n") if l.startswith("picture: ")), "")
    expect("... without --out, in the temporary folder", code == 0 and "/greenroom/screenshot-" in at and os.path.exists(at), f"{code} {out} {err}")
    if at and os.path.exists(at) and "/greenroom/screenshot-" in at:
        os.remove(at)
    # A wrong command line exits 2 and reaches nothing.
    for args, word in [(("nope",), "there is no nope"), (("tap", "--nope", "x"), "tap has no --nope"), (("wait_for",), "wait_for needs text"),
                       (("tap", "--x-pos",), "tap has no --x-pos"), (("perf", "--sample-ms", "soon"), "whole number"),
                       (("session", "extra"), "one argument too many"), (("session", "-C", root + "/nowhere"), "is not a folder"),
                       (("help", "nope"), "there is no tool nope")]:
        code, out, err, _ = cli(*args)
        expect(f"greenroom {' '.join(args)[:30]} exits 2 and says what is wrong", code == 2 and word in err and out == "", f"{code} {out!r} {err!r}")
    # Paused: the command is refused what an agent is.
    open(state_dir + "/agent-paused-check", "w").write("1")
    try:
        code, out, err, _ = cli("tap", "--text", "Add", "--sim", sim)
        expect("paused: the command is an agent like any other, refused with exit 1", code == 1 and "paused" in err, f"{code} {out} {err}")
        code, out, err, _ = cli("screen", "--sim", sim)
        expect("paused: reading still works", code == 0 and "FAB clicks" in out, f"{code} {out} {err}")
    finally:
        os.remove(state_dir + "/agent-paused-check")
    # No app: a tool call from an empty state folder would start one, so only what must not start one is tried.
    nobody = root + "/nobody-state"
    os.makedirs(nobody)
    code, out, err, took = cli("hook", "Stop", "--harness", "codex", state=nobody, stdin='{"session_id": "s", "cwd": "/"}')
    expect("greenroom hook with no app running does nothing: exit 0, no word, no app started",
           code == 0 and out == "" and err == "" and took < 3 and not os.path.exists(nobody + "/agent.json"), f"{code} {out!r} {err!r} {took:.1f} s {os.listdir(nobody)}")
    # A hook tells the app the harness, its session id, the folder and the event. Never what else the harness wrote.
    payload = json.dumps({"session_id": "sess-42", "cwd": trees["b"], "hook_event_name": "UserPromptSubmit", "prompt": "HOOKSECRET the prompt",
                          "transcript_path": "/tmp/HOOKSECRET.jsonl", "tool_input": {"command": "HOOKSECRET"}})
    code, out, err, took = cli("hook", "--harness", "claude-code", stdin=payload, cwd=other)
    expect("greenroom hook prints nothing and exits 0", code == 0 and out == "" and err == "" and took < 5, f"{code} {out!r} {err!r} {took:.1f} s")
    code, out, err, _ = cli("hook", "Stop", "--harness", "codex", "--session", "abc-1", "--cwd", trees["a"], cwd=other)
    cli("hook", "bad event; rm -rf", "--harness", "codex", "--cwd", trees["a"])
    cli("hook", "Stop", "--harness", "codex", "--cwd", root + "/nowhere")
    act = wait(lambda: (lambda t: t if "hook codex Stop" in t else None)(a.call("agent_activity", all=True)[0]), 10) or a.call("agent_activity", all=True)[0]
    b_name, a_name = os.path.basename(trees["b"]), os.path.basename(trees["a"])
    expect("the app heard both: harness, event and folder, the event and folder read from the hook's JSON or given as flags",
           f"hook claude-code UserPromptSubmit | {b_name}" in act and f"hook codex Stop | {a_name}" in act, "\n".join(l for l in act.split("\n") if " hook " in l) or act[-300:])
    expect("... and nothing else of what the harness wrote", "HOOKSECRET" not in act and "HOOKSECRET" not in open(root + "/app.log", errors="replace").read(), act[-600:])
    expect("... an event that is not a plain name, or a folder that is not there, is dropped", act.count("hook codex") == 1 and "rm -rf" not in act, act[-600:])
    own, _ = a.call("agent_activity")
    expect("... a worktree's agent sees its own worktree's hooks", f"hook codex Stop | {a_name}" in own and "hook claude-code" not in own, own[-300:])
    hits = subprocess.run(["grep", "-rl", "HOOKSECRET", state_dir], capture_output=True, text=True).stdout.strip()
    expect("... and nothing of it is written to the state folder", hits == "", hits)
    # One status model for every harness: what its hooks say is what the worktree's session says.
    def said():
        return next((l for l in a.call("session")[0].split("\n") if l.startswith("agent session: ")), "")
    def becomes(want):
        return wait(lambda: said() if said() == want else None, 10) or said()
    def codex(event):
        cli("hook", event, "--harness", "codex", "--session", "abc-1", "--cwd", trees["a"], cwd=other)
    expect("a turn that ended leaves the worktree's session idle, under the harness's name", becomes("agent session: Codex (idle)") == "agent session: Codex (idle)", said())
    codex("UserPromptSubmit")
    expect("a prompt's hook shows it working", becomes("agent session: Codex (working)") == "agent session: Codex (working)", said())
    codex("PermissionRequest")
    expect("a permission request shows it waiting for the person", becomes("agent session: Codex (waiting)") == "agent session: Codex (waiting)", said())
    codex("PostToolUse")
    expect("the tool finishing shows it working again", becomes("agent session: Codex (working)") == "agent session: Codex (working)", said())
    codex("Stop")
    expect("the turn's end shows it idle", becomes("agent session: Codex (idle)") == "agent session: Codex (idle)", said())
    # Where the sidebar files the session: the two checks above looked at its simulator, on a build that is current.
    def filed():
        line = next((l for l in a.call("sessions")[0].split("\n") if l.strip().split(" | ")[0] == "feat-a"), "")
        return next((p for p in line.split(" | ") if p.split(":")[0] in ("ready for review", "needs you", "working")), "quiet")
    def files(want):
        return wait(lambda: filed() if filed() == want else None, 10) or filed()
    # How many checks count depends on whether the session's build changed since an earlier part of this script
    # checked its screen: the two above are on the build it has now, one of them failed.
    def ready(line):
        m = re.fullmatch(r"ready for review: (\d+) of (\d+) passed · 1 failed", line)
        return bool(m) and int(m.group(2)) == int(m.group(1)) + 1 and int(m.group(2)) >= 2
    def files_ready():
        return wait(lambda: filed() if ready(filed()) else None, 10) or filed()
    expect("a session whose turn ended on a current build with checks on it is ready for review, a failed check said",
           ready(files_ready()), filed() + "\n" + a.call("sessions")[0])
    codex("UserPromptSubmit")
    expect("... a new turn takes it back to working", files("working: Codex is working") == "working: Codex is working", filed())
    codex("PermissionRequest")
    expect("... a permission asked for is the person's to answer", files("needs you: Codex is waiting for you") == "needs you: Codex is waiting for you", filed())
    codex("PostToolUse")
    codex("Stop")
    expect("... and its turn's end makes it ready again", ready(files_ready()), filed())
    # Cursor reads a hook's answer, and writes the account's address on stdin: answered, and the address never kept.
    def cursor(event, **more):
        body = json.dumps({"conversation_id": "conv-7", "workspace_roots": [trees["a"]], "hook_event_name": event, "cursor_version": "9.9",
                           "user_email": "HOOKSECRET@example.com", "prompt": "HOOKSECRET"})
        return cli("hook", event, "--harness", "cursor", stdin=body, cwd=other, **more)
    code, out, err, took = cursor("beforeSubmitPrompt")
    expect("Cursor's prompt hook is answered with continue, and nothing else", code == 0 and out == '{"continue":true}' and err == "" and took < 5, f"{code} {out!r} {err!r}")
    expect("... and its session is the worktree's, working", becomes("agent session: Cursor (working)") == "agent session: Cursor (working)", said())
    code, out, err, _ = cursor("stop")
    expect("Cursor's other hooks are answered with an empty object", code == 0 and out == "{}" and err == "", f"{code} {out!r} {err!r}")
    expect("... and its turn ended", becomes("agent session: Cursor (idle)") == "agent session: Cursor (idle)", said())
    code, out, err, _ = cursor("beforeSubmitPrompt", state=nobody)
    code2, out2, err2, _ = cursor("stop", state=nobody)
    expect("with no app running Cursor is answered the same, and no app is started",
           (code, out, err, code2, out2, err2) == (0, '{"continue":true}', "", 0, "{}", "") and not os.path.exists(nobody + "/agent.json"), f"{code} {out!r} {err!r} {code2} {out2!r} {err2!r}")
    # Cursor also runs the hooks in Claude Code's settings: heard as Cursor's session, answered as Claude Code is.
    body = json.dumps({"conversation_id": "conv-7", "workspace_roots": [trees["a"]], "cursor_version": "9.9", "user_email": "HOOKSECRET@example.com"})
    code, out, err, _ = cli("hook", "UserPromptSubmit", "--harness", "claude", stdin=body, cwd=other)
    expect("Claude Code's hook run by Cursor prints nothing, and is Cursor's session", code == 0 and out == "" and err == ""
           and becomes("agent session: Cursor (working)") == "agent session: Cursor (working)", f"{code} {out!r} {err!r} {said()}")
    act = a.call("agent_activity", all=True)[0]
    hits = subprocess.run(["grep", "-rl", "HOOKSECRET", state_dir], capture_output=True, text=True).stdout.strip()
    expect("the account Cursor names is never kept: not in the activity, the log or the state folder",
           "HOOKSECRET" not in act and "HOOKSECRET" not in open(root + "/app.log", errors="replace").read() and hits == "", act[-400:] + hits)
    # A session that ended is gone, and so is the line.
    cli("hook", "sessionEnd", "--harness", "cursor", "--session", "conv-7", "--cwd", trees["a"], cwd=other)
    codex("SessionEnd")
    cli("hook", "SessionEnd", "--harness", "claude-code", "--session", "sess-42", "--cwd", trees["b"], cwd=other)
    expect("a session that ended is no longer shown", becomes("") == "", said())
    # open, and the links: they navigate, and that is all.
    def stage():
        t, _ = a.call("app")
        return next((l for l in t.split("\n") if l.startswith("stage: ")), t[:200])
    code, out, err, _ = cli("open")
    expect("greenroom open brings the window forward", code == 0 and out == "Greenroom's window", f"{code} {out} {err}")
    code, out, err, _ = cli("open", f"{scheme}://apk")
    expect("greenroom open LINK goes where the link says: the APK screen", code == 0 and out == "the APK screen" and stage() == "stage: the APK screen", f"{code} {out} {err} | {stage()}")
    code, out, err, _ = cli("open", f"{scheme}://connect")
    expect("... the Connect screen", code == 0 and out == "the Connect screen" and stage().startswith("stage: the Connect screen"), f"{code} {out} {err} | {stage()}")
    code, out, err, _ = cli("open", f"{scheme}://session?path=" + urllib.parse.quote(trees["a"]))
    expect("... a session Greenroom has, and its simulator", code == 0 and out.startswith("feat-a") and "its simulator" in out, f"{code} {out} {err}")
    sessions_before, _ = a.call("sessions")
    code, out, err, _ = cli("open", f"{scheme}://session?path=" + urllib.parse.quote(root + "/nowhere"))
    sessions_after, _ = a.call("sessions")
    expect("a link to a session Greenroom does not have says so, exits 1 and adds nothing",
           code == 1 and "has no session for nowhere" in err and sessions_before == sessions_after, f"{code} {out} {err}")
    code, out, err, _ = cli("open", f"{scheme}://launch?apk=" + urllib.parse.quote(apk))
    sims, _ = a.call("simulators")
    expect("a link never runs anything: a place Greenroom does not have is refused", code == 1 and "has no place called launch" in err, f"{code} {out} {err}")
    other_scheme = "greenroom" if scheme == "greenroom-debug" else "greenroom-debug"
    code, out, err, _ = cli("open", f"{other_scheme}://connect")
    expect("the other copy's link is not this copy's", code == 2 and "link, and this is Greenroom" in err, f"{code} {out} {err}")
    code, out, err, _ = cli("open", root + "/nowhere")
    expect("greenroom open with nothing there exits 2", code == 2 and "there is no" in err, f"{code} {out} {err}")
    code, out, err, _ = cli("open", trees["b"], cwd=other)
    expect("greenroom open DIR opens that worktree's session, and the devices take the stage back", code == 0 and "feat-b" in out and stage() == "stage: the devices", f"{code} {out} {err} | {stage()}")
    cli("open", f"{scheme}://apk")
    code, out, err, _ = cli("open", f"{scheme}://session?path=" + urllib.parse.quote(trees["a"]))
    expect("... as they do for a link to a session", code == 0 and stage() == "stage: the devices", f"{code} {out} {err} | {stage()}")
    count = sum(1 for l in sims.split("\n") if re.match(r"s\d+ ", l))
    code, out, err, _ = cli("open", os.path.relpath(apk, other), cwd=other)
    now, _ = a.call("simulators")
    started = re.match(r"(s\d+)", out)
    expect("greenroom open APK runs it, the path taken from the shell's folder",
           code == 0 and started is not None and "launched" in out and sum(1 for l in now.split("\n") if re.match(r"s\d+ ", l)) == count + 1, f"{code} {out} {err}\n{now}")
    if started:
        a.call("close", sim=started.group(1))


def more_tools(a, away, trees, state_dir, apk, expect):
    """The tools for the rest of Greenroom: the panes (network, perf, accessibility, background, clipboard, inspect, the
    Device pane's settings), the developer hooks, the recorder, tests and snapshots, and the app, its repositories,
    sessions, jobs, pull requests and agent activity; and which of them answer while the agent is paused."""
    listed = {t["name"] for t in a.rpc("tools/list")["result"]["tools"]}
    want = {"network", "network_rule", "perf", "accessibility", "background", "clipboard", "inspect", "devtools", "recorder", "replay",
            "tests", "snapshots", "app", "workspace", "sessions", "session_action", "jobs", "pull_requests", "matrix", "agent_activity", "launch_settings"}
    expect("tools/list has the tools for the rest of Greenroom", want <= listed, sorted(want - listed))
    t, err = a.call("launch")
    sim = re.match(r"(s\d+)", t).group(1) if not err and re.match(r"s\d+", t) else None
    expect("the session's simulator runs for the pane tools", sim is not None, t)
    if sim is None:
        return
    # The panes
    t, err = a.call("network", sim=sim)
    expect("network answers the requests, or that there are none", not err and (" requests" in t or "no requests yet" in t), t)
    t, err = a.call("network", sim=sim, id=999999)
    expect("network refuses an unknown request id", err and "no request #999999" in t, t)
    t, err = a.call("network_rule", sim=sim, action="add", method="GET", pattern="https://example.invalid/items*", status=503, body='{"error":"x"}')
    expect("network_rule adds a mock and lists it", not err and "rule added" in t and "example.invalid/items*" in t and "answers 503" in t, t)
    t, err = a.call("network_rule", sim=sim, action="add", method="GET", pattern="has space", status=200)
    expect("... refuses a pattern with a space", err and "no spaces" in t, t)
    t, err = a.call("network_rule", sim=sim, action="clear")
    t2, _ = a.call("network_rule", sim=sim)
    expect("... clears them", not err and t2 == "no rules", t + "\n" + t2)
    t, err = a.call("perf", sim=sim, sample_ms=300)
    expect("perf answers frames, memory and cpu", not err and ("frames:" in t or "footprint" in t or "cpu:" in t), t)
    t, err = a.call("accessibility", sim=sim)
    expect("accessibility audits the screen", not err and ("issue" in t.lower() or "no issues" in t.lower()), t)
    t, err = a.call("background", sim=sim)
    expect("background lists jobs, services and alarms", not err and "jobs:" in t and "services:" in t and "alarms:" in t, t)
    t, err = a.call("clipboard", sim=sim, text="greenroom clip")
    t2, err2 = a.call("clipboard", sim=sim)
    expect("clipboard sets and reads the device's clipboard", not err and not err2 and "greenroom clip" in t2, t + "\n" + t2)
    screen, _ = a.call("screen", sim=sim)
    ref = next((l.split()[0] for l in screen.split("\n")[1:] if l.startswith("e")), None)
    t, err = a.call("inspect", sim=sim, ref=ref or "e1")
    expect("inspect describes a node: bounds, tap point, accessibility", not err and "bounds: [" in t and "a tap lands at" in t and "accessibility:" in t, t)
    t, err = a.call("set", sim=sim, setting="statusbar", value="off")
    expect("set takes the Device pane's controls (statusbar off)", not err and t.startswith(f"{sim} statusbar off"), t)
    t, err = a.call("set", sim=sim, setting="thermal", value="melting")
    expect("... and checks their values", err and "not a value it takes" in t, t)
    a.call("set", sim=sim, setting="statusbar", value="on")
    t, err = a.call("devtools", sim=sim)
    expect("devtools status says adb, debugger and traffic", not err and "adb: off" in t and "debugger: off" in t and "traffic: live" in t, t)
    t, err = a.call("devtools", action="har_list")
    expect("devtools har_list answers without a simulator", not err, t)
    t, err = a.call("recorder", sim=sim)
    expect("recorder status: off", not err and "flight recorder is off" in t, t)
    t, err = a.call("recorder", sim=sim, action="on")
    t2, _ = a.call("recorder", sim=sim)
    expect("recorder on turns it on", not err and "recording input" in t and "is on" in t2, t + "\n" + t2)
    t, err = a.call("recorder", sim=sim, action="off")
    expect("... and off", not err and "is off" in t, t)
    # The flight recorder's recording, saved and replayed headless on its own build.
    a.call("recorder", sim=sim, action="on")
    a.call("tap", sim=sim, text="Add")
    a.call("tap", sim=sim, text="Add")
    t, err = a.call("recorder", sim=sim, action="save")
    name = re.match(r"saved (\S+):", t).group(1) if not err and re.match(r"saved \S+:", t) else None
    a.call("recorder", sim=sim, action="off")
    t2, _ = a.call("recorder", action="list")
    expect("recorder save writes a recording that list shows", name is not None and name in t2, t + "\n" + t2)
    if name:
        t, err = a.call("replay", recording=name, timeout_s=200)
        expect("replay replays it headless and says how it went", not err and t.startswith(name + " on its own build: ") and any(w in t for w in ("same", "diverged", "crashed", "cannot replay", "failed")) or "still running" in t, t)
    # Developer hooks: each restarts the app with the same data, in the same place.
    t, err = a.call("devtools", sim=sim, action="debugger_on")
    sim2 = re.match(r"(s\d+)", t).group(1) if not err and re.match(r"s\d+", t) else sim
    t2, _ = a.call("devtools", sim=sim2)
    expect("devtools debugger_on restarts the app with a JDWP port", not err and "JDWP on localhost:" in t and "debugger: JDWP on localhost:" in t2, t + "\n" + t2)
    t, err = a.call("devtools", sim=sim2, action="debugger_off")
    sim2 = re.match(r"(s\d+)", t).group(1) if not err and re.match(r"s\d+", t) else sim2
    expect("... and debugger_off detaches it", not err and "debugger detached" in t, t)
    t, err = a.call("devtools", sim=sim2, action="adb_on")
    sim2 = re.match(r"(s\d+)", t).group(1) if not err and re.match(r"s\d+", t) else sim2
    expect("devtools adb_on answers the adb connect command", not err and ("adb connect localhost:" in t or "adb is starting" in t), t)
    t, err = a.call("devtools", sim=sim2, action="adb_off")
    sim2 = re.match(r"(s\d+)", t).group(1) if not err and re.match(r"s\d+", t) else sim2
    expect("... and adb_off turns it off", not err and "adb is off" in t, t)
    t, err = a.call("devtools", sim=sim2, action="har_record")
    sim2 = re.match(r"(s\d+)", t).group(1) if not err and re.match(r"s\d+", t) else sim2
    har = re.search(r"to (agent-\S+):", t).group(1) if not err and re.search(r"to (agent-\S+):", t) else None
    t2, err2 = a.call("devtools", sim=sim2, action="har_stop")
    sim2 = re.match(r"(s\d+)", t2).group(1) if not err2 and re.match(r"s\d+", t2) else sim2
    t3, _ = a.call("devtools", action="har_list")
    expect("devtools har_record records traffic to a HAR, har_stop writes it, har_list shows it", har is not None and not err2 and "traffic is live again" in t2 and har in t3, t + "\n" + t2 + "\n" + t3)
    if har:
        t, err = a.call("devtools", sim=sim2, action="har_replay", name=har)
        sim2 = re.match(r"(s\d+)", t).group(1) if not err and re.match(r"s\d+", t) else sim2
        expect("devtools har_replay answers every request from it", not err and f"answered from {har}" in t, t)
        t, err = a.call("devtools", sim=sim2, action="har_stop")
        sim2 = re.match(r"(s\d+)", t).group(1) if not err and re.match(r"s\d+", t) else sim2
    sim = sim2   # the session's simulator, restarted
    t, err = a.call("replay", recording="nonesuch")
    expect("replay refuses an unknown recording", err and "no recording called nonesuch" in t, t)
    t, err = a.call("tests")
    expect("tests without test_apk answers that there is no run", not err and "no test run yet" in t, t)
    t, err = a.call("tests", test_apk="/etc/hosts")
    expect("tests refuses a file that is not an APK", err and "not an .apk" in t, t)
    t, err = a.call("snapshots")
    expect("snapshots status says what is set up", not err and ("spec" in t), t)
    # The app and its repositories
    t, err = a.call("app")
    expect("app answers the versions and every setting", not err and "engine: apksim" in t and "sessions_warm =" in t and "crash_reports =" in t, t)
    t, err = a.call("app", setting="crash_reports", value="on")
    expect("... refuses the owner's settings", err and "owner's to change" in t, t)
    t, err = a.call("app", setting="sessions_warm", value="4")
    expect("... changes one of the others", not err and t == "sessions_warm: 4", t)
    a.call("app", setting="sessions_warm", value="3")
    t, err = a.call("workspace")
    expect("workspace answers this worktree's repository and its settings", not err and "base_ref = " in t and "default_recipe = " in t, t)
    t, err = a.call("workspace", setting="variant", value="release")
    expect("... changes a setting", not err and "variant = release" in t, t)
    a.call("workspace", setting="variant", value="debug")
    t, err = a.call("workspace", setting="share_maps", value="on")
    expect("... refuses the owner's", err and "owner's to change" in t, t)
    t, err = away.call("workspace")
    expect("workspace from no worktree asks which repository", err and "say which repository" in t, t)
    t, err = away.call("workspace", repo="repo")
    expect("... and takes repo", not err and t.startswith("repo ("), t)
    t, err = a.call("sessions")
    expect("sessions lists the repositories and their sessions", not err and "feat-a" in t and "feat-b" in t and "repo2" in t, t)
    t, err = a.call("session_action", action="close", session="feat-b")
    expect("session_action closes another session's simulator by its branch", not err and ("closed" in t or "no simulator running" in t), t)
    t, err = a.call("session_action", action="open", session="feat-b")
    expect("... and opens it", not err and ("runs feat-b" in t or "is starting" in t), t)
    t, err = a.call("jobs")
    expect("jobs lists the queue", not err and ("running" in t or "no jobs" in t), t)
    t, err = a.call("pull_requests")
    expect("pull_requests lists them", not err and ("pull request" in t.lower() or t.startswith("#")), t)
    t, err = a.call("agent_activity")
    expect("agent_activity has this worktree's calls", not err and "client: mcp-check" in t and "workspace" in t, t)
    # Paused: what only reads still answers, what changes is refused.
    open(state_dir + "/agent-paused-check", "w").write("1")
    try:
        t, err = a.call("app")
        expect("paused: app still answers", not err and "settings:" in t, t)
        t, err = a.call("app", setting="sessions_warm", value="4")
        expect("paused: app setting is refused", err and "paused" in t, t)
        t, err = a.call("network_rule", sim=sim)
        expect("paused: network_rule list answers", not err, t)
        t, err = a.call("network_rule", sim=sim, action="clear")
        expect("paused: network_rule clear is refused", err and "paused" in t, t)
        t, err = a.call("clipboard", sim=sim, text="x")
        expect("paused: clipboard set is refused", err and "paused" in t, t)
    finally:
        os.remove(state_dir + "/agent-paused-check")
    t, err = a.call("matrix", apk=apk, devices=["phone"], appearances=["light", "dark"])
    expect("matrix runs one APK on several combinations and answers their ids", not err and "on 2 simulators" in t and t.count(" running") >= 2, t)
    t, err = a.call("matrix", action="close")
    expect("... and closes them", not err and "closed" in t, t)

def mp4_has_video(path):
    """A video track: a `hdlr` box whose handler type is `vide`, inside a file with a `moov`."""
    data = open(path, "rb").read()
    if b"moov" not in data:
        return False
    return any(data[i + 12:i + 16] == b"vide" for i in (m.start() for m in re.finditer(b"hdlr", data)))

def session_tools(a, b, away, trees, repo2, state_dir, root, recipe, built_apk, base_apk, key_of, apk, slot, wait, expect, Shim, up):
    """session, build, changes, screenshot's screen and the recording of the agent's session (W5b)."""
    def sim_of(shim, branch):
        sims, _ = shim.call("simulators")
        return next((l.split()[0] for l in sims.split("\n") if f"(session {branch})" in l and "--fresh" not in l), None), sims
    nowhere = "not a worktree of a repository added to Greenroom"
    # session
    t, err = a.call("session")
    expect("session answers the branch, commit and that it is clean", not err and re.match(r"feat-a [0-9a-f]{7} \(clean", t), t)
    expect("... its build, the default recipe, the base and the simulator",
           "build: " in t and "default recipe: local" in t and "base: origin/main" in t and re.search(r"simulator: s\d+ running", t), t)
    for tool in ("session", "build", "changes"):
        t, err = away.call(tool)
        expect(f"{tool} from a folder with no session fails clearly", err and nowhere in t, t)
    t, err = away.call("screenshot", screen="s1")
    expect("screenshot with a screen from no session fails clearly", err and nowhere in t, t)

    # The recording of an agent's session: a few actions, then 3 s of nothing (the check's idle time; 60 s by default).
    videos = lambda: set(glob.glob(state_dir + "/evidence/*/video/agent-*.mp4"))
    sid, _ = sim_of(a, "feat-a")
    # Earlier steps of this check were recorded too: let those recordings end (3 s idle), then count from here.
    wait(lambda: not glob.glob(state_dir + "/evidence/*/video/*.part"), 30)
    before = videos()
    for call in (lambda: a.call("screen", sim=sid), lambda: a.call("check", sim=sid, visible=["FAB clicks"]), lambda: a.call("tap", sim=sid, text="Add"),
                 lambda: a.call("tap", sim=sid, text="Add")):
        call()
    t, _ = a.call("session")
    expect("session says it is being recorded while it is", "recording: " in t and ".mp4" in t, t)
    new = wait(lambda: (videos() - before) and not glob.glob(state_dir + "/evidence/*/video/*.part"), 30)
    files = sorted(videos() - before)
    steps_rows = lambda f: [json.loads(l) for l in open(os.path.dirname(f) + "/steps.jsonl")] if os.path.exists(os.path.dirname(f) + "/steps.jsonl") else []
    files = [f for f in files if [r["tool"] for r in steps_rows(f) if r["video"] == os.path.basename(f)][:4] == ["screen", "check", "tap", "tap"]] or files
    expect("a few actions leave an agent-*.mp4 under the build's evidence", bool(new) and bool(files), str(glob.glob(state_dir + "/evidence/*/*")))
    if files:
        expect("... with a video track", mp4_has_video(files[0]) and os.path.getsize(files[0]) > 2000, files[0])
        steps = os.path.dirname(files[0]) + "/steps.jsonl"
        rows = [json.loads(l) for l in open(steps)] if os.path.exists(steps) else []
        mine = [r for r in rows if r["video"] == os.path.basename(files[0])]
        expect("... and steps.jsonl beside it lists the calls", [r["tool"] for r in mine][:4] == ["screen", "check", "tap", "tap"] and all("time" in r and "summary" in r for r in mine), json.dumps(mine)[:400])
        expect("... and a chapters file with a chapter per call", os.path.exists(files[0][:-4] + ".chapters.json") and len(json.load(open(files[0][:-4] + ".chapters.json"))) >= 4,
               str(glob.glob(os.path.dirname(files[0]) + "/*")))
    # What is stored of the calls: never typed text, a link's query, a setting's value or the text of a tap or wait.
    wait(lambda: not glob.glob(state_dir + "/evidence/*/video/*.part"), 30)
    secret, query = "hunter2-SECRET-text", "SECRETQUERY"
    a.call("tap", sim=sid, text="Trips")
    a.call("type", sim=sid, text=secret, tap_text="Trip note")
    a.call("open_url", sim=sid, url=f"apksim://composeapp/trips?token={query}#fragbit")
    a.call("set", sim=sid, setting="appearance", value="dark")
    a.call("set", sim=sid, setting="appearance", value="light")
    a.call("wait_for", sim=sid, text="Italian vacation", timeout_ms=3000)
    wait(lambda: not glob.glob(state_dir + "/evidence/*/video/*.part") and glob.glob(state_dir + "/evidence/*/video/steps.jsonl"), 30)
    stored = ""
    for f in glob.glob(state_dir + "/evidence/*/video/steps.jsonl") + glob.glob(state_dir + "/evidence/*/video/*.chapters.json"):
        stored += open(f).read().replace("\\/", "/")   # JSON may escape slashes
    mp4s = "".join(open(f, "rb").read().decode("latin-1") for f in glob.glob(state_dir + "/evidence/*/video/agent-*.mp4"))
    expect("steps.jsonl and the chapters say how much was typed, not what", f"typed {len(secret)} characters" in stored and secret not in stored and secret not in mp4s and "SECRET" not in stored, stored[-600:])
    expect("... an app's own link as its scheme alone", "open_url: apksim" in stored and "composeapp" not in stored and query not in stored and "fragbit" not in stored, "open lines: " + " | ".join(l for l in stored.replace("}", "\n").split("\n") if "open" in l or query in l or "fragbit" in l)[:600])
    expect("... a setting without its value, a tapped or awaited text by its length",
           '"set: appearance"' in stored and "dark" not in stored and "wait_for: text of 16 characters" in stored and "Italian vacation" not in stored and "Trip note" not in stored, stored[-600:])
    # The per-repository switch, off for the second repository.
    c = Shim(repo2)
    t, err = c.call("launch")
    expect("a repository with its recording off still launches", not err and "launched" in t, t)
    before = videos()
    sid2, _ = sim_of(c, "main")
    for _ in range(3):
        c.call("tap", sim=sid2, text="Add")
    time.sleep(6)
    expect("... and its agent's actions are not recorded", videos() == before, str(videos() - before))

    # build, with a stand-in recipe as the workspace's local one.
    sidb, _ = sim_of(b, "feat-b")
    key = key_of(built_apk)
    open(root + "/recipe-sleep", "w").write("x")
    answer = []
    th = threading.Thread(target=lambda: answer.append(b.call("build", timeout_s=240)))
    th.start()
    time.sleep(2.5)
    t0 = time.time()
    t, err = a.call("session")
    expect("another agent call answers while a build runs", th.is_alive() and not err and "feat-a" in t and time.time() - t0 < 5, f"{time.time() - t0:.1f} s, build alive {th.is_alive()}")
    th.join(120)
    os.remove(root + "/recipe-sleep")
    t, err = answer[0] if answer else ("no answer", True)
    expect("build runs the recipe and answers the new build's key", not err and t.startswith(f"built {key} with the local recipe"), t)
    env_seen = open(root + "/recipe-env.txt").read() if os.path.exists(root + "/recipe-env.txt") else ""
    expect("... told never to dispatch a CI workflow", "GREENROOM_CI_DISPATCH=0" in env_seen and "GREENROOM_REF=feat-b" in env_seen, env_seen)
    reloaded = wait(lambda: (lambda sims: f"/builds/{key}/app.apk" in "".join(l for l in sims.split("\n") if "(session feat-b)" in l and "--fresh" not in l))(b.call("simulators")[0]), 60)
    expect("... and the session's simulator reloads on it", bool(reloaded), b.call("simulators")[0])
    t, _ = b.call("session")
    expect("session then shows that build, current", f"[{key}]" in t and "current" in t, t)
    open(root + "/recipe-fail", "w").write("x")
    t, err = b.call("build", timeout_s=120)
    expect("a failing recipe answers the log's error lines", err and "build failed" in t and "unresolved reference: boom" in t, t)
    os.remove(root + "/recipe-fail")
    t, err = b.call("build", recipe="remote")
    expect("the remote recipe without the person's yes is refused, saying who can give it",
           err and "allow it in Greenroom" in t and "cannot give that yes" in t, t)
    t, err = b.call("build", recipe="nonesuch")
    expect("an unknown recipe is refused", err and "no recipe called nonesuch" in t, t)
    open(state_dir + "/agent-paused-check", "w").write("1")
    t, err = b.call("build")
    expect("with the pause switch on, build is refused", err and "paused" in t, t)
    t, err = a.call("changes", base=base_apk)
    expect("... and so is changes", err and "paused" in t, t)
    t, err = b.call("session")
    expect("... while session still answers", not err and "feat-b" in t, t)
    os.remove(state_dir + "/agent-paused-check")

    # changes. First what needs no walk.
    # A commit nothing built (no stored build, no CI, no worktree on it): a branch one commit ahead of main.
    tree_sha = subprocess.run(["/usr/bin/git", "rev-parse", "HEAD^{tree}"], cwd=root + "/repo", capture_output=True, text=True).stdout.strip()
    head_sha = subprocess.run(["/usr/bin/git", "rev-parse", "HEAD"], cwd=root + "/repo", capture_output=True, text=True).stdout.strip()
    ghost = subprocess.run(["/usr/bin/git", "-c", "user.name=Check", "-c", "user.email=check@example.invalid", "commit-tree", tree_sha, "-p", head_sha, "-m", "unbuilt"],
                           cwd=root + "/repo", capture_output=True, text=True).stdout.strip()
    subprocess.run(["/usr/bin/git", "branch", "ghost", ghost], cwd=root + "/repo", check=True)
    t, err = a.call("changes", base="ghost")
    expect("a base nothing built is answered as text saying what would build it, and starts nothing",
           not err and "no build of" in t.lower() and "Nothing was started" in t and not glob.glob(state_dir + "/changes/*"), t)
    for bad in ("/etc/hosts", "/no/such/dir/x.apk", "relative.apk"):
        t, err = a.call("changes", base=bad)
        expect(f"a base path that is not a readable .apk file is refused ({bad})", err and (".apk" in t), t)
    t, err = a.call("changes", base="no-such-branch")
    expect("a base that does not exist is an error", err and "No branch or commit called" in t, t)
    # Against the same build: a walk of both, no differences.
    own = trees["a"] + "/app/build/outputs/apk/debug/app-debug.apk"
    t, err = a.call("changes", base=own, timeout_s=280)
    expect("changes against the same build answers no differences",
           not err and "the same build" in t and not re.search(r"^[+~-] ", t, re.M) and "0 new, 0 changed, 0 gone" in t, t)
    expect("... and counts crashes", "crashes: none" in t, t)
    # Against another build whose launches differ (the base is launched with a different Settings value).
    t, err = a.call("changes", base=base_apk, timeout_s=280)
    lines = [l for l in t.split("\n") if l.startswith("~ ")]
    expect("changes against a base that looks different answers a ~ line with its pixels", not err and len(lines) == 1 and re.search(r": [0-9,]+ px differ.* \[[^\]]+\]$", lines[0]), t)
    sid_screen = re.search(r"\[([^\]]+)\]$", lines[0]).group(1) if lines else ""
    for side in ("head", "base", "diff"):
        r = a.rpc("tools/call", {"name": "screenshot", "arguments": {"screen": sid_screen, "side": side, "max_size": 400}}).get("result", {})
        images = [x for x in r.get("content", []) if x["type"] == "image"]
        expect(f"screenshot with that screen id returns the {side} capture", not r.get("isError") and len(images) == 1 and len(images[0]["data"]) > 1000, json.dumps(r)[:300])
    t, err = a.call("screenshot", screen="nonesuch")
    expect("an unknown screen id is an error", err and "no head capture" in t, t)
    # The repository's skin and launch options (LaunchSettings): read, changed, shown by session, used by the next launch.
    t, err = a.call("launch_settings")
    expect("launch_settings answers no skin and no options, and the stored skins", not err and "skin: none" in t and "options: none" in t and "galaxy-s25" in t, t)
    t, err = a.call("launch_settings", skin="nonesuch")
    expect("... refuses a skin that is not stored", err and "no stored skin called nonesuch" in t, t)
    t, err = a.call("launch_settings", skin="galaxy-s25", options="--timezone Europe/Berlin --headless --data-slots x")
    expect("... saves a skin and options, leaving out Greenroom's own", not err and "skin: galaxy-s25" in t and "options: --timezone Europe/Berlin --headless --data-slots x" in t
           and "left out" in t and "--data-slots x" in t.split("left out")[1] and "--skin galaxy-s25" in t, t)
    t, err = a.call("session")
    expect("session shows them", not err and "launch: skin galaxy-s25, options --timezone Europe/Berlin" in t, t)
    t, err = b.call("launch_settings")
    expect("the other worktree of the repository has them too", not err and "skin: galaxy-s25" in t, t)
    t, err = a.call("launch", fresh=True)
    sims, _ = a.call("simulators")
    expect("a launch for the session takes the skin and the options, without the left-out ones",
           not err and "skin galaxy-s25" in t and "--skin galaxy-s25" in sims and "--timezone Europe/Berlin" in sims and "--headless --data-slots x" not in sims, t + "\n" + sims)
    t, err = away.call("launch", apk=apk, fresh=True, skin="galaxy-a56", options="--font-scale 1.3 --window front")
    sims, _ = away.call("simulators")
    expect("launch takes skin and options of its own, leaving out Greenroom's", not err and "skin galaxy-a56" in t and "left out" in t and "--font-scale 1.3" in sims, t + "\n" + sims)
    t, err = a.call("launch_settings", skin="", options="")
    expect("... and clears them", not err and "skin: none" in t and "options: none" in t, t)

def history_mode():
    """One worktree of a temporary repository with two commits; the store holds the fixtures' `mixed` base at the first and its
    head at the second (the session's). `changes` base snapshot:FIRST and `history` answer from it; nothing is walked."""
    root = os.path.realpath(tempfile.mkdtemp(prefix="grmcp-", dir="/tmp"))
    repo, state_dir = root + "/repo", root + "/state"
    def git(*a, cwd=repo, out=False):
        r = subprocess.run(["/usr/bin/git", "-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false", *a],
                           cwd=cwd, check=True, capture_output=True, text=True)
        return r.stdout.strip()
    os.makedirs(repo); os.makedirs(state_dir)
    open(repo + "/README.md", "w").write("hello\n")
    git("init", "-q", "-b", "main"); git("add", "."); git("commit", "-q", "-m", "first")
    first = git("rev-parse", "HEAD")
    git("commit", "-q", "--allow-empty", "-m", "second")
    second = git("rev-parse", "HEAD")
    wt = root + "/wt"
    git("worktree", "add", "-q", "-b", "feat", wt)
    env = dict(os.environ, GREENROOM_STATE=state_dir, GREENROOM_ADD_REPOSITORY=repo, GREENROOM_CHECK_AUTO="off",
               GREENROOM_CHECK_HISTORY_SEED=f"mixed:{first}:{second}")
    app_log = open(root + "/app.log", "w")
    app = subprocess.Popen([exe, "--background", "--agent-check"], stdout=app_log, stderr=subprocess.STDOUT, env=env)
    failures = []
    def expect(what, ok, got=""):
        print(("ok   " if ok else "FAIL ") + what + ("" if ok else "\n     got: " + str(got)[:600].replace("\n", "\n          ")))
        if not ok:
            failures.append(what)
    shim = None
    try:
        agent = state_dir + "/agent.json"
        def up():
            try:
                os.kill(json.load(open(agent))["pid"], 0); return True
            except Exception:
                return False
        end = time.time() + 60
        while time.time() < end and not up():
            time.sleep(0.2)
        if not up():
            sys.exit("mcp-check: Greenroom did not start its agent endpoint within 60 s\n" + open(root + "/app.log", errors="replace").read()[-2000:])
        shim = subprocess.Popen([exe, "--mcp", "--agent-check"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1, cwd=wt, env=env)
        n = [0]
        def rpc(method, params=None):
            n[0] += 1
            shim.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params or {}}) + "\n"); shim.stdin.flush()
            return json.loads(shim.stdout.readline())
        rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp-check", "version": "1"}})
        def call(name, **args):
            r = rpc("tools/call", {"name": name, "arguments": args}).get("result", {})
            return r, "\n".join(c["text"] for c in r.get("content", []) if c["type"] == "text"), bool(r.get("isError"))
        # The repository is added by the app at launch, and its rows are read from git a moment later.
        t, err = "", True
        end = time.time() + 60
        while time.time() < end:
            _, t, err = call("history")
            if "not a worktree" not in t:
                break
            time.sleep(0.5)
        print("---- history\n" + t + "\n----")
        lines = t.split("\n")
        expect("history lists the two stored snapshots, newest first, the session's commit marked",
               not err and lines[0].startswith("history: 2 snapshots") and lines[1].startswith(second[:7]) and "(this session)" in lines[1] and lines[2].startswith(first[:7]) and "the first" in lines[2], t)
        expect("... and says what changed against the one before",
               re.search(r"\+\d+ new, ~\d+ changed, -\d+ gone against " + first[:7], lines[1]) is not None, lines[1])
        _, c, err = call("changes", base="snapshot:" + first[:7])
        print("---- changes\n" + c + "\n----")
        cl = c.split("\n")
        expect("changes from stored maps says so in its first line and started no walk",
               not err and cl[0].startswith("changes from history, no walk started:") and not glob.glob(state_dir + "/changes/*/crawl.json"), c)
        expect("... with the baseline", any(l.startswith("baseline: ") and first[:7] in l for l in cl), c)
        changed = [l for l in cl if l.startswith("~ ")]
        expect("... each ~ line keeps its [id] and carries reasons after the colon",
               changed and all(re.search(r": .+ \[[^\]]+\]$", l) for l in changed) and any(re.search(r"route|text|visual|structure", l) for l in changed), c)
        expect("... counts, and no crashes", any(re.match(r"\d+ new, \d+ changed, \d+ gone, \d+ the same", l) for l in cl) and "crashes: none" in cl, c)
        redirected = [l for l in cl if l.startswith("> ")]
        print("redirected lines:", redirected)
        shown = [l for l in changed if re.search(r": [1-9][0-9,]* px differ", l)]
        m = re.search(r"\[([^\]]+)\]$", (shown or changed or [""])[0])
        for side in ("head", "base", "diff"):
            r, t2, err = call("screenshot", screen=m.group(1) if m else "x", side=side)
            images = [x for x in r.get("content", []) if x["type"] == "image"]
            expect(f"screenshot with a screen id from a history comparison returns the {side} picture", not err and len(images) == 1 and len(images[0]["data"]) > 100, t2)
        # Lineage of one screen.
        title = None
        for l in cl:
            mt = re.match(r"~ (.+?): ", l)
            if mt: title = mt.group(1); break
        _, h, err = call("history", screen=title or "x")
        print("---- history screen\n" + h + "\n----")
        expect("history with screen gives that screen's lineage, one line per changing commit",
               not err and h.startswith(f"history of {title}") and any(l.startswith(second[:7]) for l in h.split("\n")[1:]), h)
        r, t3, err = call("screenshot", screen=title or "x", commit=first[:7])
        images = [x for x in r.get("content", []) if x["type"] == "image"]
        expect("screenshot with screen and commit gives the stored picture", not err and len(images) == 1 and (first[:7] in t3), t3)
        _, t4, err = call("screenshot", screen="no such screen", commit=first[:7])
        expect("... and an unknown screen is an error", err and "no stored capture" in t4, t4)
        _, t5, err = call("history", screen="no such screen")
        expect("history of an unknown screen is an error", err and "no screen" in t5, t5)
        _, t6, err = call("changes", base="snapshot:" + "0" * 40)
        expect("a base commit with no stored map is an error, not a walk", err and ("not a commit" in t6 or "no stored map" in t6), t6)
    finally:
        if shim:
            try: shim.stdin.close(); shim.wait(timeout=10)
            except Exception: shim.kill()
        app.terminate()
        try: app.wait(timeout=20)
        except subprocess.TimeoutExpired: app.kill()
        if failures:
            print("the app's output:\n" + open(root + "/app.log", errors="replace").read()[-3000:])
        remove(root)
    print(f"mcp-check --history: {len(failures)} failed" if failures else "mcp-check --history: all passed")
    sys.exit(1 if failures else 0)

if "--history" in sys.argv:
    history_mode()
if "--sessions" in sys.argv or "--tools" in sys.argv:
    sessions_mode()
state = (os.environ.get("GREENROOM_STATE") or os.path.expanduser("~/Library/Application Support/Greenroom")) + "/agent.json"   # GREENROOM_STATE: a state folder of its own
def running_pid():
    try:
        pid = json.load(open(state))["pid"]
        os.kill(pid, 0)
        return pid
    except Exception:
        return None
was_running = running_pid()
# A state folder of the check's own with nothing in it yet: the app this starts is on its first run.
first_run = bool(os.environ.get("GREENROOM_STATE")) and not was_running and not os.path.exists(os.path.dirname(state) + "/connect-seen") \
    and not os.path.exists(os.path.dirname(state) + "/sessions/workspaces.json")
started = None
if not was_running:
    # Started here rather than by the shim (which uses LaunchServices: on CI's runners the app it opened never served
    # its endpoint within the shim's 15 s), and given a minute: a cold first launch on a runner is slow.
    import tempfile
    app_log = tempfile.NamedTemporaryFile(prefix="greenroom-mcp-check-", suffix=".log", delete=False)
    started = subprocess.Popen([exe, "--background", "--agent-check"], stdout=app_log, stderr=subprocess.STDOUT)
    for _ in range(600):
        if running_pid():
            break
        time.sleep(0.1)
    else:
        sys.exit("mcp-check: Greenroom did not start its agent endpoint within 60 s")
p = subprocess.Popen([exe, "--mcp", "--agent-check"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
n, failures = [0], []

def rpc(method, params=None):
    n[0] += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params or {}}) + "\n")
    p.stdin.flush()
    line = p.stdout.readline()
    if not line:
        sys.exit("mcp-check: the shim closed its output")
    return json.loads(line)

def call(name, **args):
    answer = rpc("tools/call", {"name": name, "arguments": args})
    if "result" not in answer:
        return "no result: " + json.dumps(answer)[:300], True, []
    r = answer["result"]
    text = "\n".join(c["text"] for c in r.get("content", []) if c["type"] == "text")
    return text, bool(r.get("isError")), [c for c in r.get("content", []) if c["type"] == "image"]

def expect(what, ok, got=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else "\n     got: " + got[:300].replace("\n", "\n          ")))
    if not ok:
        failures.append(what)

try:
    r = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp-check", "version": "1"}})
    expect("initialize answers with the asked version", r["result"]["protocolVersion"] == "2025-06-18", json.dumps(r))
    # What the server says about itself. The release copy's words are as they were; the Debug copy (Info.plist's
    # GreenroomVariant) says what it is first, so an agent that has both does not pick it to test an app.
    words, title = r["result"].get("instructions", ""), r["result"].get("serverInfo", {}).get("title")
    release_words = ("Drives Android apps in Greenroom on this Mac; the person there sees the same simulators. launch an APK, then tap/type/key/swipe: "
                     "each action answers with the nodes that changed (+ added, - removed, ~ changed; refs like e3 stay the same while a node is on screen), "
                     "so call screen or screenshot only when you need all of it. check verifies texts in one call. APKs and their data stay on this Mac. "
                     "Sign-ins are the owner's: never ask for or type passwords. To sign in, run_script a script the owner allowed (scripts lists them): "
                     "it types their stored credentials, which you never see.")
    try:
        import plistlib
        variant = plistlib.load(open(os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(exe))), "Info.plist"), "rb")).get("GreenroomVariant", "release")
    except Exception:
        variant = "release"
    if variant == "debug":
        expect("the Debug copy's instructions open by saying what it is, then say the same",
               words.startswith("This is Greenroom Debug, the development build of Greenroom itself. Use it only when asked to test the debug build")
               and words.endswith(release_words) and len(words) < 4096 and title == "Greenroom Debug", (title, words))
    else:
        expect("the release copy's instructions are as they were", words == release_words and title == "Greenroom", (title, words))
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
    listed = rpc("tools/list")
    if "result" not in listed:
        print("FAIL tools/list: " + json.dumps(listed)[:500])
        if started:
            print("the app " + ("is running" if started.poll() is None else f"ended with status {started.returncode}"))
            print(open(app_log.name, errors="replace").read()[-3000:])
        sys.exit(1)
    tools = listed["result"]["tools"]
    expect("tools are listed", {"launch", "tap", "type", "screen", "check", "screenshot", "logs"} <= {t["name"] for t in tools}, str([t["name"] for t in tools]))
    r = rpc("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "1999-01-01"}})
    expect("an unknown protocol version is refused", r.get("error", {}).get("code") == -32022, json.dumps(r))

    # First run (a state folder with nothing in it): the window shows the Connect screen until an agent's app opens.
    stage = lambda: next((l for l in call("app")[0].split("\n") if l.startswith("stage: ")), "")
    if first_run:
        expect("on first run the window shows the Connect screen", stage().startswith("stage: the Connect screen"), stage())
    t, err, _ = call("launch", apk=apk, fresh=True)
    expect("launch answers with the screen", not err and "launched" in t and '"FAB clicks: 0"' in t, t)
    expect("the agent's app takes the stage", stage() == "stage: the devices", stage())
    t, err, _ = call("tap", text="Add")
    expect("a tap answers with what changed", not err and '"FAB clicks: 0" -> "FAB clicks: 1"' in t, t)
    ref = next((l.split()[1] for l in t.split("\n") if l.startswith("~ ") and "FAB clicks" in l), "")
    t, err, _ = call("tap", text="Add")
    expect("a node keeps its reference while it is on screen", f"~ {ref} " in t and '"FAB clicks: 2"' in t, t)
    t, err, _ = call("tap", text="Trips")
    expect("navigation shows as added and removed nodes", not err and '+ ' in t and '"Italian vacation"' in t, t)
    t, err, _ = call("type", text="packed twice", tap_text="Trip note")
    expect("typing reaches the tapped field", not err and "packed twice" in t, t)
    t, err, _ = call("check", visible=["Italian vacation", "packed twice"], absent=["FAB clicks"])
    expect("check passes on what is there", t.startswith("PASS"), t)
    t, err, _ = call("check", visible=["Not on this screen"])
    expect("check fails on what is not, and says what", t.startswith("FAIL") and "Not on this screen" in t, t)
    t, err, _ = call("tap", ref="e9999")
    expect("a reference that is not on screen is an error", err and "not on screen" in t, t)
    t, err, _ = call("key", key="ENTER; quit")
    expect("a key that is not a key name is refused", err, t)
    t, err, _ = call("set", setting="rotate", value="landscape")
    expect("set rotates the device", not err and "rotate landscape" in t, t)
    t, err, _ = call("screen")
    expect("screen reports the turned device", "1782x822" in t.split("\n")[0], t)
    t, err, images = call("screenshot", annotate=True, max_size=600)
    expect("screenshot answers with a picture and its legend", not err and len(images) == 1 and len(images[0]["data"]) > 2000 and "click" in t, t)
    t, err, _ = call("logs", lines=20)
    expect("logs has the app's lines", not err and len(t) > 20, t)
    t, err, _ = call("wait_for", text="No such text anywhere", timeout_ms=600)
    expect("wait_for gives up at its timeout", err and "not on screen after" in t, t)
    call("set", setting="rotate", value="portrait")
    call("tap", text="Home")
    t, err, _ = call("launch", apk="sample", fresh=True)   # the app that comes with Greenroom, by name
    second = t.split()[0]
    expect("a second launch, of the sample app by name, runs beside the first", not err and second == "s2" and '"FAB clicks: 0"' in t, t)
    call("tap", sim="s2", text="Add")
    call("tap", sim="s2", text="Add")
    # s1 was tapped twice at the start of the session: both now show "FAB clicks: 2".
    t, err, _ = call("compare")
    expect("compare finds two copies in the same state the same", not err and "SAME" in t.split("\n")[0] and "identical pixels" in t, t)
    call("tap", sim="s2", text="Add")
    t, err, images = call("compare", map=True)
    expect("compare lists what differs and how many pixels", not err and "DIFFERENT" in t and '- "FAB clicks: 2"' in t
           and '+ "FAB clicks: 3"' in t and "of pixels differ" in t, t)
    expect("compare's map is a picture", len(images) == 1 and len(images[0]["data"]) > 2000, str(len(images)))
    t, err, _ = call("tap", text="Add")
    expect("with two simulators, an action must say which", err and "say which" in t, t)
    call("close", sim="s2")
    t, err, _ = call("close")
    expect("close stops the simulator", not err and "closed" in t, t)
    t, err, _ = call("tap", text="Add")
    expect("with no simulator, an action says to launch one", err and "launch" in t, t)
finally:
    p.stdin.close()
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
    pid = running_pid()
    if pid and pid != was_running:
        os.kill(pid, signal.SIGTERM)
        time.sleep(1)
    if started:
        try:
            started.wait(timeout=20)
        except subprocess.TimeoutExpired:
            started.kill()

if failures and started:
    print("the app it started " + ("is running" if started.poll() is None else f"ended with status {started.returncode}") + "; its output:")
    print(open(app_log.name, errors="replace").read()[-4000:])
    reports = sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/Greenroom*")), key=os.path.getmtime)
    if reports:
        print("its newest crash report, " + reports[-1] + ":")
        print(open(reports[-1], errors="replace").read()[:4000])
print(f"mcp-check: {len(failures)} failed" if failures else "mcp-check: all passed")
sys.exit(1 if failures else 0)
