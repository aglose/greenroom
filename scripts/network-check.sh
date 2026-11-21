#!/bin/bash
# The privacy promise's check: Greenroom and its engine make no network connection of their own (PRIVACY.md).
#
#   sudo -v && scripts/network-check.sh [APP] [APK]   (defaults: build/Greenroom.app and the training app inside it)
#
# Captures every packet on every interface but loopback with Apple's tcpdump, which tags each packet with the process
# that sent it and, for a DNS lookup made through mDNSResponder, the process that asked (`-k`). Meanwhile it runs, as a
# customer would (the engine in its own sandbox, nothing turned off): the engine's first launch and the startup-cache
# training it starts, the headless smoke runs, the agent interface (scripts/mcp-check.py) and the whole app with every
# pane shown (`--privacy-check`). Any packet sent by, or on behalf of, Greenroom or a process of its engine fails the
# check, with the process and the address. The APK must make no requests of its own: the training app's start screen
# makes none.
#
# Needs root for the capture (`sudo -n`: CI's runners have it; on a Mac, `sudo -v` first). Before anything else a
# canary (curl to a public address) must show up in the capture, so a capture that sees nothing fails the check.
# Why not a sandbox refusing the network: the engine's own sandbox cannot be applied inside another one, and the
# kernel does not log the refusals of the engine's JVM reliably (seen on macOS 26.1: none at all).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-$ROOT/build/Greenroom.app}
APK=${2:-$APP/Contents/Resources/engine-testapp.apk}
BIN="$APP/Contents/MacOS/Greenroom"
[[ -x "$BIN" && -f "$APK" ]] || { echo "usage: scripts/network-check.sh [APP] [APK]" >&2; exit 2; }
sudo -n true 2>/dev/null || { echo "error: the capture needs root: run 'sudo -v' first" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-netcheck.XXXXXX")
CAP="$WORK/capture.txt"
# Processes whose packets count: the app, the engine's JVMs and client, and the shells and tools they start.
OURS='Greenroom|java|apksim-client|sandbox-exec|bash|sh|unzip|shasum|python3|Python'

sudo -n /usr/sbin/tcpdump -i pktap,all -k -n -l -q 'not (host 127.0.0.1 or ip6 host ::1)' > "$CAP" 2> "$WORK/tcpdump.err" &
DUMP=$!
stop_capture() { sudo -n kill -INT "$DUMP" 2>/dev/null || true; wait "$DUMP" 2>/dev/null || true; }
trap stop_capture EXIT
for _ in $(seq 50); do grep -q 'listening on' "$WORK/tcpdump.err" && break; sleep 0.2; done
sleep 1

echo "== canary: a connection the capture must see"
/usr/bin/curl -s -m 10 -o /dev/null https://example.com/ || true
for _ in $(seq 20); do grep -qE '(proc|eproc) curl:' "$CAP" && break; sleep 0.5; done
grep -qE '(proc|eproc) curl:' "$CAP" || { echo "error: the capture did not see the canary's packets, so it cannot see any"; head -5 "$CAP"; cat "$WORK/tcpdump.err"; exit 1; }
echo "seen: $(grep -cE '(proc|eproc) curl:' "$CAP") packets, DNS included: $(grep -E 'eproc curl:' "$CAP" | grep -q mDNSResponder && echo yes || echo no)"
MARK=$(wc -l < "$CAP")

echo "== smoke: the engine's first launch (and its startup-cache training, started in the background)"
"$BIN" --smoke "$APK" | tail -1
echo "== smoke-stream: the workbench's path, headless"
"$BIN" --smoke-stream "$APK" | head -2
echo "== agent interface"
"$ROOT/scripts/mcp-check.py" "$BIN" "$APK" | tail -1
echo "== the whole app, every pane"
"$BIN" --background --privacy-check "${PRIVACY_SECONDS:-45}" "$APK" | grep '\[greenroom\] privacy-check'
# Let training finish (it may still be running from the first launch) and the capture catch up.
for _ in $(seq 180); do pgrep -f "$APP/Contents/Resources/engine/scripts/train.sh" >/dev/null || break; sleep 1; done
sleep 3
stop_capture; trap - EXIT

sent=$(tail -n +"$((MARK + 1))" "$CAP" | grep -E "(proc|eproc) ($OURS):" || true)
if [[ -n "$sent" ]]; then
  echo "FAIL: packets sent outside this Mac by Greenroom or its engine:"
  echo "$sent" | head -40
  exit 1
fi
echo "PASS: no packet from Greenroom or its engine left this Mac ($(($(wc -l < "$CAP") - MARK)) packets from other processes meanwhile)"
rm -rf "$WORK"
