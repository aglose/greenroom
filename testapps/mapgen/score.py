#!/usr/bin/env python3
"""Scores a comparison of two mapgen builds against what mapgen changed.

    testapps/mapgen/score.py B_DIR/mutations.json MAPWALKS_OUTPUT [--model B_DIR/model.json]

MAPWALKS_OUTPUT is what `Greenroom --map-walks DIR WALK_A WALK_B` printed for a walk of build A and a walk of build B
(one line per screen that differs: `added: Title [id]`, `modified: Title [id] (visual, text)`, ...). Screens are matched
by title, which mapgen keeps unique and the crawler takes from the top bar (a screen's dialog, sheet or tab states are
screens of their own with the same title: one of them reported is enough).

Prints what was found, what was missed, what was reported that mapgen did not change, and whether each modified
screen was given the expected reason (visual, text, structure, routes). Exits 1 when a change was missed.
"""
import json
import re
import sys

LINE = re.compile(r"map-walks: (added|removed|modified|notCompared): (.*?) \[[^\]]*\](?: \(([^)]*)\))?")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    changes = json.load(open(sys.argv[1]))
    reported = {}
    for line in open(sys.argv[2], errors="replace"):
        m = LINE.search(line)
        if m:
            status, title, reasons = m.group(1), m.group(2), set(filter(None, (m.group(3) or "").replace(" ", "").split(",")))
            e = reported.setdefault(title, {"statuses": set(), "reasons": set()})
            e["statuses"].add(status)
            e["reasons"] |= reasons
    expected = {}
    for c in changes:
        e = expected.setdefault(c["title"], {"expect": c["expect"], "reasons": set(), "kinds": []})
        if c.get("reason"):
            e["reasons"].add(c["reason"])
        e["kinds"].append(c["kind"])
        if c["expect"] in ("added", "removed"):
            e["expect"] = c["expect"]
    found, missed, wrong_reason, not_compared = [], [], [], []
    for title, e in sorted(expected.items()):
        r = reported.get(title)
        if not r:
            missed.append(f"{title} ({', '.join(e['kinds'])}: expected {e['expect']})")
            continue
        if e["expect"] in r["statuses"] or (e["expect"] == "modified" and r["statuses"] & {"modified"}):
            found.append(title)
            if e["expect"] == "modified" and not e["reasons"] <= r["reasons"]:
                wrong_reason.append(f"{title}: expected {', '.join(sorted(e['reasons']))}, reported {', '.join(sorted(r['reasons'])) or 'none'}")
        elif r["statuses"] == {"notCompared"}:
            not_compared.append(f"{title} ({', '.join(e['kinds'])})")
        else:
            missed.append(f"{title} ({', '.join(e['kinds'])}: expected {e['expect']}, reported {', '.join(sorted(r['statuses']))})")
    extra = sorted(t for t, r in reported.items() if t not in expected and r["statuses"] - {"notCompared"})
    print(f"score: {len(found)} of {len(expected)} changed screens found, {len(missed)} missed, {len(not_compared)} not compared, "
          f"{len(extra)} reported that mapgen did not change, {len(wrong_reason)} with an unexpected reason")
    for name, lst in (("missed", missed), ("not compared", not_compared), ("unexpected reason", wrong_reason),
                      ("reported but not changed", [f"{t} ({', '.join(sorted(reported[t]['statuses']))}; {', '.join(sorted(reported[t]['reasons']))})" for t in extra])):
        for x in lst:
            print(f"  {name}: {x}")
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    main()
