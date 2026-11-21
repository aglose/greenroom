#!/usr/bin/env python3
"""Checks the agent interface as an agent uses it: `Greenroom --mcp` on stdin/stdout, against the bundled test app.
Usage: scripts/mcp-check.py GREENROOM_EXECUTABLE APK [--sessions]
--sessions: the agent tied to its worktree's session (a temporary git repository with two worktrees, a state folder
of its own); without it, the interface itself against the person's own state folder.
Starts Greenroom (its executable, in the background) if it is not running, and quits the copy it started."""
import glob, hashlib, json, os, signal, subprocess, sys, tempfile, time, urllib.request

exe, apk = sys.argv[1], sys.argv[2]

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
    env = dict(os.environ, GREENROOM_STATE=state_dir, GREENROOM_ADD_REPOSITORY=repo, GREENROOM_CHECK_FEEDS="1")
    app_log = open(root + "/app.log", "w")
    app = subprocess.Popen([exe, "--background"], stdout=app_log, stderr=subprocess.STDOUT, env=env)
    failures, shims = [], []
    def expect(what, ok, got=""):
        print(("ok   " if ok else "FAIL ") + what + ("" if ok else "\n     got: " + str(got)[:400].replace("\n", "\n          ")))
        if not ok:
            failures.append(what)
    class Shim:
        def __init__(self, cwd):
            self.p = subprocess.Popen([exe, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1, cwd=cwd, env=env)
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
        def call(self, name, **args):
            r = self.rpc("tools/call", {"name": name, "arguments": args}).get("result", {})
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
        t, err = b.call("launch", apk=apk)
        expect("an apk given inside a session still gets the session's data slot", not err and "replaced the session's running simulator" in t, t)
        sims, _ = b.call("simulators")
        expect("... as the simulators list shows", f"--data-slots {slot(trees['b'])}" in sims and sims.count("(session feat-b)") == 1, sims)
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
               sum(e["tool"] == "launch" for e in feed_a) == 2 and sum(e["tool"] == "launch" for e in feed_b) == 2 and not any(e["tool"] == "tap" for e in feed_b), json.dumps(by)[:600])
        expect("calls from no session are a feed of their own", len(none) >= 4 and all(e["label"] == "" for e in none), json.dumps(none)[:400])
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
        subprocess.run(["rm", "-rf", root])
    print(f"mcp-check --sessions: {len(failures)} failed" if failures else "mcp-check --sessions: all passed")
    sys.exit(1 if failures else 0)

if "--sessions" in sys.argv:
    sessions_mode()
state = os.path.expanduser("~/Library/Application Support/Greenroom/agent.json")
def running_pid():
    try:
        pid = json.load(open(state))["pid"]
        os.kill(pid, 0)
        return pid
    except Exception:
        return None
was_running = running_pid()
started = None
if not was_running:
    # Started here rather than by the shim (which uses LaunchServices: on CI's runners the app it opened never served
    # its endpoint within the shim's 15 s), and given a minute: a cold first launch on a runner is slow.
    import tempfile
    app_log = tempfile.NamedTemporaryFile(prefix="greenroom-mcp-check-", suffix=".log", delete=False)
    started = subprocess.Popen([exe, "--background"], stdout=app_log, stderr=subprocess.STDOUT)
    for _ in range(600):
        if running_pid():
            break
        time.sleep(0.1)
    else:
        sys.exit("mcp-check: Greenroom did not start its agent endpoint within 60 s")
p = subprocess.Popen([exe, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
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

    t, err, _ = call("launch", apk=apk, fresh=True)
    expect("launch answers with the screen", not err and "launched" in t and '"FAB clicks: 0"' in t, t)
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
    t, err, _ = call("launch", apk=apk, fresh=True)
    second = t.split()[0]
    expect("a second launch runs beside the first", not err and second == "s2", t)
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
