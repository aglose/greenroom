# A real agent session

The agent interface ([AGENTS-INTERFACE.md](AGENTS-INTERFACE.md)) is checked by `scripts/mcp-check.py`, a script that
calls the tools as an agent would. This is the other half: a real model, given only Greenroom's tools and a task in
plain words, on 2026-11-20.

## Setup

- Claude Code 2.1, headless (`claude -p`), model Sonnet, Greenroom connected as the only MCP server and every
  built-in tool turned off (`--tools ""`, `--strict-mcp-config`), so the model could do nothing but drive Greenroom.
- An ad hoc build of `main` plus the matrix wall branch, engine 0.54.0, the bundled test app.
- The task, in full: launch the test app on a phone; find the trips list and rename "Italian vacation" to "Roman
  vacation" ("the app has a way to do this; find it") and verify it; check the Settings tab in dark mode and in German
  ("a second simulator side by side is fine") and report anything broken or untranslated; close every simulator it started; report on the tools.

```bash
claude -p "$(cat task.txt)" --mcp-config mcp.json --strict-mcp-config --tools "" \
  --allowedTools mcp__greenroom --model sonnet --output-format stream-json --verbose
```

## What happened

Done in **13 turns, 27 s, $0.07**, every step right:

1. `launch` (phone): the answer was the screen as text, so no screenshot was needed to find the bottom bar.
2. `tap e15` (Trips), then `tap e19` ("Italian vacation"): the answer `~ e19 "Italian vacation" -> "Roman vacation"`
   showed the rename itself; the model found the gesture by trying.
3. `check` with `visible: ["Roman vacation"]` and `absent: ["Italian vacation"]`: `PASS`.
4. `set appearance dark`, `tap "Settings"`, `screenshot`, `set locale de-DE` (answered with the date changing to
   "20.11.2026, 17:15"), `screenshot`, `swipe up`, `screenshot`.
5. `close`.

Its findings were right: dark mode fine; under German only number and date formats change and every label stays
English (the test app has no German strings, so that is a true finding about the app, not the tools).

## What it said about the tools, and what was done

| Friction | Done |
| --- | --- |
| `set appearance dark` answered "no change" and it could not tell whether dark mode had applied: only a screenshot settled it | Answers now say "no change in the screen's text (colours and pictures are not compared: screenshot shows them)" |
| Screenshots are 461×1000 while the device is 822×1782, so coordinates in a picture are not device pixels | Left: node references avoid coordinates, and the screenshot's legend gives the scale. Worth a line in the tool description if a second session trips on it |
| It did not use a second simulator side by side for the locale check, though the task allowed it | Nothing to change: one simulator was enough |

## Running it again

The transcript format makes a session easy to replay as a check: the tool calls are in the `stream-json` output.
A model run costs a few cents and is not deterministic, so it stays a manual check, run when the tool surface
changes, rather than a CI step.
