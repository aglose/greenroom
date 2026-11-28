#!/usr/bin/env python3
"""The Claude Code plugin (plugin/, .claude-plugin/marketplace.json), checked without Claude Code:
the manifests agree with each other and with what Settings shows, the skill is where Claude Code looks, and the
launcher script finds an app, says why when there is none, and serves MCP through it.
usage: scripts/plugin-check.py /path/to/Greenroom.app"""
import json, os, plistlib, re, shutil, subprocess, sys, tempfile, time

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

# The repository's own .mcp.json: the Debug copy, for agents working in this repository and its worktrees only.
project = json.load(open(root + "/.mcp.json"))
expect("the repository's .mcp.json declares one server, greenroom-debug", list(project.get("mcpServers", {})) == ["greenroom-debug"], list(project.get("mcpServers", {})))
debug = project["mcpServers"].get("greenroom-debug", {})
debug_argv = [debug.get("command", "")] + debug.get("args", [])
debug_script = root + "/scripts/greenroom-debug-mcp.sh"
expect("it runs scripts/greenroom-debug-mcp.sh from the worktree's own root", "git rev-parse --show-toplevel" in debug_argv[-1] and "scripts/greenroom-debug-mcp.sh" in debug_argv[-1] and os.access(debug_script, os.X_OK), debug_argv)
expect(".mcp.json and its script name no home folder", not any(re.search(r"/Users/|/home/", open(f).read()) for f in (root + "/.mcp.json", debug_script)))
expect("the Debug copy is never added for every project", "repositoryOnly" in connect and '"--scope", "user"' in connect)

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

# The greenroom command and the skill: the plugin's own files, and the copies inside the app are the same bytes.
command = plugin + "/bin/greenroom"
expect("the plugin has the greenroom command in bin/, which Claude Code puts on its Bash tool's PATH", os.access(command, os.X_OK), command)
bundled = app + "/Contents/Resources/bin/greenroom"
expect("the app carries the same command", os.access(bundled, os.X_OK) and open(bundled, "rb").read() == open(command, "rb").read(), bundled)
bundled_skill = app + "/Contents/Resources/skill/SKILL.md"
expect("the app carries the same skill", os.path.isfile(bundled_skill) and open(bundled_skill).read() == skill, bundled_skill)
expect("the skill says the command's exit statuses and how to find it", "command -v greenroom" in skill and "`greenroom help TOOL`" in skill and "3 when" in skill)
info = plistlib.load(open(app + "/Contents/Info.plist", "rb"))
scheme = "greenroom-debug" if info.get("GreenroomVariant") == "debug" else "greenroom"
schemes = [s for t in info.get("CFBundleURLTypes", []) for s in t.get("CFBundleURLSchemes", [])]
expect(f"the app opens {scheme}:// links, and no other", schemes == [scheme], schemes)

# The launcher, with no app to find.
def launch(env, stdin=""):
    return subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=60, env=env)
plain = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/")}
r = launch(dict(plain, GREENROOM_APP="/nowhere/Greenroom.app"))
expect("a GREENROOM_APP that is no app is refused, in words", r.returncode == 1 and "not a Greenroom.app" in r.stderr and r.stdout == "", r.stderr)
r = subprocess.run(debug_argv, capture_output=True, text=True, timeout=60, cwd=root, env=dict(plain, GREENROOM_DEBUG_APP="/nowhere/Greenroom Debug.app"))
expect("the Debug launcher refuses a GREENROOM_DEBUG_APP that is no app, in words", r.returncode == 1 and "not a Greenroom Debug.app" in r.stderr and r.stdout == "", r.stderr)
empty = tempfile.mkdtemp(prefix="grplugin-")
fake = empty + "/bin"
os.makedirs(fake)
# An app from before the command: `greenroom mcp` still runs it, anything else says to update (it would open a window).
old = empty + "/old/Greenroom.app"
os.makedirs(old + "/Contents/MacOS")
open(old + "/Contents/MacOS/Greenroom", "w").write("#!/bin/sh\necho ran \"$@\"\n")   # (a copied system program does not start)
os.chmod(old + "/Contents/MacOS/Greenroom", 0o755)
r = subprocess.run([command, "tools"], capture_output=True, text=True, timeout=60, env=dict(plain, GREENROOM_APP=old))
expect("the command refuses an app older than itself, in words", r.returncode == 1 and "is older than the greenroom command" in r.stderr and "Check for Updates" in r.stderr and r.stdout == "", (r.returncode, r.stderr))
r = subprocess.run([command, "mcp"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, env=dict(plain, GREENROOM_APP=old))
expect("... and still starts its MCP server", r.returncode == 0 and r.stdout.strip() == "ran --mcp" and r.stderr == "", (r.returncode, r.stdout, r.stderr))
r = subprocess.run([command, "tools"], capture_output=True, text=True, timeout=60, env=dict(plain, GREENROOM_APP="/nowhere/Greenroom.app"))
expect("the command refuses a GREENROOM_APP that is no app, in words", r.returncode == 1 and "not a Greenroom.app" in r.stderr and r.stdout == "", r.stderr)
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
    names_of_app = set()
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
            names_of_app.update(names)
    served(dict(plain, GREENROOM_APP=app, GREENROOM_MCP_ARGS="--agent-check", GREENROOM_STATE=state), "from GREENROOM_APP")
    # The repository's .mcp.json, as Claude Code would run it from a subfolder of a worktree.
    r = subprocess.run(debug_argv, input=messages, capture_output=True, text=True, timeout=60, cwd=root + "/scripts",
                       env=dict(plain, GREENROOM_DEBUG_APP=app, GREENROOM_MCP_ARGS="--agent-check", GREENROOM_STATE=state))
    try:
        debug_names = {t["name"] for t in [json.loads(l) for l in r.stdout.splitlines() if l.strip()][-1]["result"]["tools"]}
    except Exception:
        debug_names = set()
    expect("the repository's .mcp.json serves MCP from a subfolder of the worktree", {"launch", "check"} <= debug_names, (r.returncode, r.stdout[:300], r.stderr[:300]))
    # The command: inside the app (as a link on the PATH leads to it), and the plugin's copy told where the app is.
    checking = dict(plain, GREENROOM_MCP_ARGS="--agent-check", GREENROOM_STATE=state)
    def said(argv, env):
        r = subprocess.run(argv, capture_output=True, text=True, timeout=60, env=env, cwd=empty)
        return r.returncode, r.stdout, r.stderr
    code, out, err = said([bundled, "tools"], checking)
    listed = {l.split()[0] for l in out.splitlines() if l.strip()}
    expect("the command inside the app lists the app's tools", code == 0 and names_of_app <= listed, (code, sorted(names_of_app - listed)[:8], err[:300]))
    os.symlink(bundled, fake + "/greenroom")
    code, out, err = said(["greenroom", "version"], dict(checking, PATH=fake + ":/usr/bin:/bin"))
    expect("a link to it on the PATH runs the app it is inside", code == 0 and info["CFBundleShortVersionString"] in out and ("Debug" in out) == (scheme == "greenroom-debug"), (code, out, err[:300]))
    code, out, err = said([command, "simulators"], dict(checking, GREENROOM_APP=app))
    expect("the plugin's command reaches the app GREENROOM_APP names", code == 0 and out.strip() != "" and err == "", (code, out[:200], err[:300]))
    code, out, err = said([command, "nope"], dict(checking, GREENROOM_APP=app))
    expect("... and a wrong tool is a usage error (2), not a window", code == 2 and "greenroom tools" in err and out == "", (code, out[:200], err[:300]))
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
