#!/usr/bin/env python3
"""Checks the agent interface as an agent uses it: `Greenroom --mcp` on stdin/stdout, against the bundled test app.
Usage: scripts/mcp-check.py GREENROOM_EXECUTABLE APK
Starts Greenroom if it is not running (and quits the copy it started)."""
import json, os, signal, subprocess, sys, time

exe, apk = sys.argv[1], sys.argv[2]
state = os.path.expanduser("~/Library/Application Support/Greenroom/agent.json")
def running_pid():
    try:
        pid = json.load(open(state))["pid"]
        os.kill(pid, 0)
        return pid
    except Exception:
        return None
was_running = running_pid()
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
    r = rpc("tools/call", {"name": name, "arguments": args}).get("result", {})
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
    tools = rpc("tools/list")["result"]["tools"]
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

print(f"mcp-check: {len(failures)} failed" if failures else "mcp-check: all passed")
sys.exit(1 if failures else 0)
