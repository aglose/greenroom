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
# A packet counts as ours when its process (or the process a DNS lookup was made for) is named like the app, the engine
# or a tool they could start, or was started under this script (PIDs recorded every 0.1 s). The app's state folder is
# moved aside for the run, so it is a first launch. Needs root for the capture (`sudo -n`: CI's runners have it; on a
# Mac, `sudo -v` first). A canary fetch must show up first, its DNS lookup tagged with it, or the check fails.
# Why not a sandbox refusing the network: the engine's own sandbox cannot be applied inside another one, and the
# kernel does not log the refusals of the engine's JVM reliably (seen on macOS 26.1: none at all).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$(cd "${1:-$ROOT/build/Greenroom.app}" && pwd)
APK=${2:-$APP/Contents/Resources/engine-testapp.apk}
[[ "$APK" == /* ]] || APK="$PWD/$APK"
BIN="$APP/Contents/MacOS/Greenroom"
[[ -x "$BIN" && -f "$APK" ]] || { echo "usage: scripts/network-check.sh [APP] [APK]" >&2; exit 2; }
sudo -n true 2>/dev/null || { echo "error: the capture needs root: run 'sudo -v' first" >&2; exit 2; }
pgrep -x Greenroom >/dev/null && { echo "error: quit Greenroom first (the check runs its own)" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-netcheck.XXXXXX")
CAP="$WORK/capture.txt"; PIDS="$WORK/pids.txt"
# A first launch, as a customer's: the app's state folder is moved aside for the check (and put back after), so the
# engine's first launch, the copy of its training app and the startup-cache training all happen inside the capture.
SUPPORT="$HOME/Library/Application Support/Greenroom"
ASIDE="$SUPPORT.network-check-$$"
[[ -e "$SUPPORT" ]] && mv "$SUPPORT" "$ASIDE"
# Processes whose packets count, by name (also tools the engine's scripts may start) and by PID: every process
# started under this script is recorded while it runs, so a helper with any name counts too.
OURS='Greenroom|java|apksim-client|sandbox-exec|bash|sh|zsh|env|unzip|zip|shasum|python3|Python|curl|nc|ssh|openssl|perl|ruby|open|osascript'

sudo -n /usr/sbin/tcpdump -i pktap,all -k -n -l -q 'not (host 127.0.0.1 or ip6 host ::1)' > "$CAP" 2> "$WORK/tcpdump.err" &
DUMP=$!
# Keep sudo's credentials fresh for a long run, so tcpdump can be stopped at the end.
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
# Record this script's descendants every 0.1 s.
( while :; do ps -A -o pid=,ppid= > "$WORK/ps.now" 2>/dev/null
    awk -v root=$$ '{ parent[$1] = $2 } END { for (p in parent) { q = p; for (i = 0; i < 64 && q != "" && q != 0; i++) {
      if (q == root) { print p; break } q = parent[q] } } }' "$WORK/ps.now" >> "$PIDS"; sleep 0.1; done ) & WATCH=$!
cleanup() {
  kill "$WATCH" "$KEEP" 2>/dev/null || true
  wait "$WATCH" "$KEEP" 2>/dev/null || true
  if kill -0 "$DUMP" 2>/dev/null; then
    sudo -n kill -INT "$DUMP" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$DUMP" 2>/dev/null || break; sleep 0.1; done
  fi
  if [[ -e "$ASIDE" ]]; then rm -rf "$SUPPORT"; mv "$ASIDE" "$SUPPORT"; fi
}
trap cleanup EXIT
for _ in $(seq 50); do grep -q 'listening on' "$WORK/tcpdump.err" && break; sleep 0.2; done
sleep 1

echo "== canary: a fetch the capture must see, its DNS lookup included"
# A copy of curl under a name of its own, so its packets are told apart from any curl the engine might start.
cp /usr/bin/curl "$WORK/netcheck-canary"
"$WORK/netcheck-canary" -s -m 10 -o /dev/null https://example.com/ || true
for _ in $(seq 20); do grep -q 'proc netcheck-canary:' "$CAP" && break; sleep 0.5; done
echo "a captured line: $(grep -m1 'netcheck-canary:' "$CAP" || true)"
grep -q 'proc netcheck-canary:' "$CAP" || { echo "error: the capture did not see the canary's packets, so it cannot see any"; head -5 "$CAP"; cat "$WORK/tcpdump.err"; exit 1; }
grep 'proc mDNSResponder:' "$CAP" | grep -q 'eproc netcheck-canary:' || { echo "error: the canary's DNS lookup was not tagged with the canary, so the engine's would not be either"; grep -m3 mDNSResponder "$CAP" || true; exit 1; }
echo "seen, DNS included"
sleep 3   # the canary's connection closing, so its last packets land before the mark
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
[[ -f "$SUPPORT/engine/app.aot" ]] && echo "training: done inside the capture" || echo "training: no startup cache was built (see the engine's train.log)"
kill "$WATCH" 2>/dev/null || true
sudo -n kill -INT "$DUMP" 2>/dev/null || true
for _ in $(seq 50); do kill -0 "$DUMP" 2>/dev/null || break; sleep 0.1; done

sort -u "$PIDS" > "$PIDS.u"
sent=$(tail -n +"$((MARK + 1))" "$CAP" | awk -v names="^($OURS)$" -v pidfile="$PIDS.u" '
  BEGIN { while ((getline p < pidfile) > 0) ours[p] = 1 }
  /netcheck-canary:/ { next }   # the canary (a child of this script) is not the app
  { bad = 0; line = $0
    while (match(line, /(e?proc) [^:,)]+:[0-9]+/)) {
      split(substr(line, RSTART, RLENGTH), f, /[ :]/); line = substr(line, RSTART + RLENGTH)
      if (f[2] ~ names || (f[3] in ours)) bad = 1 }
    if (bad) print }')
if [[ -n "$sent" ]]; then
  echo "FAIL: $(echo "$sent" | wc -l | tr -d ' ') packets sent outside this Mac by Greenroom or its engine, by process:"
  echo "$sent" | grep -oE 'e?proc [^:,)]+' | sort | uniq -c
  echo "the first of them:"
  echo "$sent" | head -20
  exit 1
fi
echo "PASS: no packet from Greenroom or its engine left this Mac ($(sort -u "$PIDS" | wc -l | tr -d ' ') processes watched, $(($(wc -l < "$CAP") - MARK)) packets from other processes meanwhile)"
