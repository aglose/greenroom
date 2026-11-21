#!/usr/bin/env python3
"""The Claude Code plugin (plugin/, .claude-plugin/marketplace.json), checked without Claude Code:
the manifests agree with each other and with what Settings shows, the skill is where Claude Code looks, and the
launcher script finds an app, says why when there is none, and serves MCP through it.
usage: scripts/plugin-check.py /path/to/Greenroom.app"""
import json, os, re, shutil, subprocess, sys, tempfile, time

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
app = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
failures = []
def expect(what, ok, got=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else "\n     got: " + str(got)[:400]))
    if not ok:
        failures.append(what)

# The manifests.
market = json.load(open(root + "/.claude-plugin/marketplace.json"))
entry = market["plugins"][0]
source = entry["source"]
expect("the marketplace's plugin is a folder of this repository", source.startswith("./") and ".." not in source, source)
plugin = os.path.normpath(os.path.join(root, source))
manifest = json.load(open(plugin + "/.claude-plugin/plugin.json"))
expect("the marketplace entry and the plugin's manifest have one name", entry["name"] == manifest["name"], (entry["name"], manifest["name"]))
connect = open(root + "/Sources/Greenroom/ClaudeConnect.swift").read()
install = f"/plugin install {manifest['name']}@{market['name']}"
expect(f"Settings shows {install}", f'"{install}"' in connect)
expect("Settings shows /plugin marketplace add aglose/greenroom", '"/plugin marketplace add aglose/greenroom"' in connect)
docs = open(root + "/docs/AGENTS-INTERFACE.md").read()
expect("docs/AGENTS-INTERFACE.md has the same install line", install in docs)

# The server: one, started through the script inside the plugin.
servers = manifest.get("mcpServers", {})
expect("the plugin declares one MCP server, greenroom", list(servers) == ["greenroom"], list(servers))
server = servers.get("greenroom", {})
argv = [server.get("command", "")] + [a.replace("${CLAUDE_PLUGIN_ROOT}", plugin) for a in server.get("args", [])]
script = argv[-1]
expect("its script is inside the plugin", os.path.isfile(script) and os.path.realpath(script).startswith(os.path.realpath(plugin) + "/"), script)
expect("the plugin's files name no home folder", not any(re.search(r"/Users/|/home/", open(os.path.join(d, f), errors="replace").read())
                                                         for d, _, fs in os.walk(plugin) for f in fs))

# The skill: skills/verify/SKILL.md is /greenroom:verify, and it names the loop's tools.
skill = open(plugin + "/skills/verify/SKILL.md").read()
front = skill.split("---")[1] if skill.startswith("---") else ""
expect("the skill has a name and a description", re.search(r"^name: verify$", front, re.M) and re.search(r"^description: \S", front, re.M), front)
loop = ("session", "build", "changes", "launch", "tap", "type", "check", "screenshot", "compare")
missing = [t for t in loop if f"`{t}`" not in skill]
expect("the skill names the loop's tools", not missing, missing)
# Every tool the skill names (held against the app's own list further down).
named = set(loop) | {t for t in ("simulators", "screen", "wait_for", "logs", "set") if f"`{t}`" in skill}
for words in ("paused", "consent", "what changed"):
    expect(f"the skill says: {words}", words in skill.lower())

# The launcher, with no app to find.
def launch(env, stdin=""):
    return subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=60, env=env)
plain = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/")}
r = launch(dict(plain, GREENROOM_APP="/nowhere/Greenroom.app"))
expect("a GREENROOM_APP that is no app is refused, in words", r.returncode == 1 and "not a Greenroom.app" in r.stderr and r.stdout == "", r.stderr)
empty = tempfile.mkdtemp(prefix="grplugin-")
fake = empty + "/bin"
os.makedirs(fake)
open(fake + "/mdfind", "w").write("#!/bin/sh\necho /nowhere/Greenroom.app\n")
os.chmod(fake + "/mdfind", 0o755)
if not os.path.exists("/Applications/Greenroom.app"):
    r = launch({"PATH": fake + ":/usr/bin:/bin", "HOME": empty})
    expect("with no app installed it says where it looked and how to install", r.returncode == 1 and "was not found" in r.stderr and "releases" in r.stderr and r.stdout == "", r.stderr)
    # Spotlight's answer is used: a stand-in mdfind names this app (and, first, one that macOS translocated).
    # (The stand-ins for a translocated copy and a disk image's are real folders with a program, so only the rule skips it.)
    decoys = [empty + "/T/AppTranslocation/A/d/Greenroom.app"]
    for d in decoys:
        os.makedirs(d + "/Contents/MacOS")
        shutil.copy("/usr/bin/true", d + "/Contents/MacOS/Greenroom")
    open(fake + "/mdfind", "w").write("#!/bin/sh\n" + "".join(f"echo '{d}'\n" for d in decoys + [app]))
    found = True
else:
    print("skip the not-installed and Spotlight cases: /Applications/Greenroom.app exists on this Mac")
    found = False

# The launcher, serving: an app with a state folder of its own (--agent-check), then initialize and tools/list through it.
state = tempfile.mkdtemp(prefix="grplugin-state-", dir="/tmp")
env = dict(os.environ, GREENROOM_STATE=state)
log = open(state + "/app.log", "w")
running = subprocess.Popen([app + "/Contents/MacOS/Greenroom", "--background", "--agent-check"], stdout=log, stderr=subprocess.STDOUT, env=env)
try:
    for _ in range(600):
        if os.path.exists(state + "/agent.json"):
            break
        time.sleep(0.1)
    else:
        sys.exit("plugin-check: Greenroom did not start its agent endpoint within 60 s")
    messages = "".join(json.dumps(m) + "\n" for m in (
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "plugin-check", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}))
    def served(env, how):
        r = launch(env, messages)
        try:
            answers = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
            names = {t["name"] for t in answers[-1]["result"]["tools"]}
        except Exception:
            names = set()
        expect(f"the launcher serves MCP {how}", {"session", "build", "changes", "launch", "check", "compare"} <= names, (r.returncode, r.stdout[:300], r.stderr[:300]))
        if names:
            expect("... and every tool the skill names is one of the app's", named <= names, sorted(named - names))
    served(dict(plain, GREENROOM_APP=app, GREENROOM_MCP_ARGS="--agent-check", GREENROOM_STATE=state), "from GREENROOM_APP")
    if found:
        served({"PATH": fake + ":/usr/bin:/bin", "HOME": empty, "GREENROOM_MCP_ARGS": "--agent-check", "GREENROOM_STATE": state}, "from the app Spotlight names, past a translocated copy")
finally:
    running.terminate()
    try:
        running.wait(10)
    except subprocess.TimeoutExpired:
        running.kill()
    shutil.rmtree(empty, ignore_errors=True)
    shutil.rmtree(state, ignore_errors=True)
print("plugin-check: " + ("ok" if not failures else f"{len(failures)} failed"))
sys.exit(1 if failures else 0)
