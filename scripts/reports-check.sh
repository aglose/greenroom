#!/bin/bash
# The opt-in reports, end to end (PRIVACY.md): a crash of Greenroom's own, an engine ending as a crash would, a day of
# usage; each report checked for its allowed fields and for anything naming the APK, then sent to a receiver on this
# Mac, whose copies are checked again.
#
#   scripts/reports-check.sh [APP] [APK]     (defaults: build/Greenroom.app and the training app inside it)
#
# Both kinds are turned on for these runs only (the argument domain: -reports.crashes YES), so the customer's choice in
# the app's preferences is left as it was; the outbox is the app's own, and is emptied by the send.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$(cd "${1:-$ROOT/build/Greenroom.app}" && pwd)
APK=${2:-$APP/Contents/Resources/engine-testapp.apk}
BIN="$APP/Contents/MacOS/Greenroom"
W=$(mktemp -d "${TMPDIR:-/tmp}/greenroom-reports.XXXXXX")
mkdir -p "$W/received"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 - "$PORT" "$W/received" > "$W/receiver.log" 2>&1 <<'PY' &
import http.server, sys, os, itertools
port, out = int(sys.argv[1]), sys.argv[2]
n = itertools.count()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(out, f"{next(n)}.json"), "wb") as f:
            f.write(body)
        with open(os.path.join(out, f"{next(n)}.headers"), "w") as f:
            f.write(str(self.headers))
        self.send_response(204); self.end_headers()
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
RECEIVER=$!
trap 'kill $RECEIVER 2>/dev/null || true' EXIT
ON=(-reports.crashes YES -reports.usage YES -reports.asked YES)
export GREENROOM_REPORTS_URL="http://127.0.0.1:$PORT/report"

echo "== Greenroom crashes (on purpose)"
"$BIN" --background --reports-crash "${ON[@]}" > "$W/crash.log" 2>&1 || echo "ended with status $? (expected: a crash)"
grep -h 'reports-check' "$W/crash.log" || true
echo "== the next launch: the crash, an engine's end and a day of usage, checked and sent"
"$BIN" --background --reports-check "$APK" "${ON[@]}" | grep '\[greenroom\] reports-check'

echo "== what the receiver got"
ls "$W/received"/*.json >/dev/null 2>&1 || { echo "FAIL: nothing was received"; exit 1; }
python3 - "$W/received" "$APK" <<'PY'
import json, glob, os, sys
folder, apk = sys.argv[1], sys.argv[2]
allowed = {"kind", "day", "app", "build", "engine", "macos", "counts", "status", "signal", "frames"}
kinds, bad = [], []
for f in sorted(glob.glob(os.path.join(folder, "*.json"))):
    text = open(f).read(); r = json.loads(text); kinds.append(r["kind"])
    bad += [f"{r['kind']}: field {k}" for k in r if k not in allowed]
    bad += [f"{r['kind']}: names the APK" for n in (os.path.basename(apk), apk, "composeapp") if n in text]
    print(" ", r["kind"], {k: v for k, v in r.items() if k not in ("kind",)})
for h in glob.glob(os.path.join(folder, "*.headers")):
    hs = open(h).read().lower()
    bad += ["a cookie was sent"] if "cookie:" in hs else []
need = {"crash", "engine-exit", "usage"}
missing = need - set(kinds)
if "app-crash" in kinds: bad.append("an app's own crash was reported")
print("received:", ", ".join(sorted(kinds)))
if missing or bad:
    print("FAIL:", "missing " + ", ".join(sorted(missing)) if missing else "", "; ".join(bad)); sys.exit(1)
print("PASS: crash, engine exit and usage reports received, with allowed fields only and nothing naming the APK")
PY
rm -rf "$W"
