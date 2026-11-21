# The agent interface

Greenroom serves the [Model Context Protocol](https://modelcontextprotocol.io), so a coding agent can launch, drive
and check Android apps in the same simulators the person at the Mac is looking at.

## Connecting

Claude Code:

```bash
claude mcp add greenroom -- "/Applications/Greenroom.app/Contents/MacOS/Greenroom" --mcp
```

Any other MCP client: run that program with `--mcp` as a stdio server. The toolbar's Agent button (✦) has the
command for this copy of the app, a log of what agents did, and a switch that pauses them.

`Greenroom --mcp` holds no simulators itself. It passes each message to the running app, starting Greenroom in
the background if it is not open, so what an agent launches appears in the window and what the person opened is
there for the agent.

## How it is meant to be used

The answers are built to be cheap to read:

- **The screen is text.** `launch` and `screen` answer with one line per node: `e7 "Sign in" click`,
  `e9 "Email" field`. A reference (`e7`) stays the same node for as long as it is on screen.
- **Every action answers with what changed**, after the app has gone quiet: `~ e3 "0" -> "1"` (changed),
  `+ e12 "Saved" click` (new), `- e5 "Loading"` (gone). There is seldom a reason to read the whole screen again. Only text is compared: when an action changes
  colours or pictures alone (dark mode), the answer says the text did not change, and `screenshot` shows the rest.
- **`check` verifies in one call**: texts that must be visible and texts that must not, answered `PASS` or
  `FAIL | ... | not on screen: "Saved"`.
- **`wait_for`** waits for a text to appear or go, instead of sleeping.
- **`screenshot`** is for what nodes do not show (pictures, canvases, layout). `annotate` draws each tappable
  node's reference on the picture. It is downscaled to 1000 px by default.
- **`logs`** gives the app's log lines since the last call.

| Tool | |
| --- | --- |
| `launch` | start an APK: `apk` (left out inside a worktree of a repository added to Greenroom: see below), and optionally `device`, `appearance`, `locale`, `font_scale`, `fresh` |
| `simulators`, `close` | what is running; stop one |
| `tap` | by `ref`, by `text`, or at `x`,`y` |
| `type` | `text`, into the field named by `ref` or `tap_text`; `enter` |
| `key`, `back`, `swipe`, `open_url` | keys, Back, a swipe by `direction` or coordinates, a deep link |
| `set` | appearance, locale, font scale, rotation, network, device, time zone, animation scale, permissions; home, resume, lock, unlock, recreate, restart, process-death |
| `screen`, `check`, `wait_for`, `screenshot`, `logs` | reading and verifying |
| `compare` | how two simulators' screens differ: `-` only on the base, `+` only on the other, `>` moved, and the share of pixels that differ; `map` adds a picture of where |

With several simulators running, each tool takes `sim` (`s1`, `s2`...). A second `launch` puts its simulator
beside the first, so the same build can be driven on a phone and a tablet at once.

To check a change against the build before it: `launch` both APKs, do the same steps on each, and `compare`.
`s1 vs s2: SAME | same content, identical pixels` means the change did nothing visible on that screen; otherwise
the lines say exactly what moved, appeared or went.

## Worktrees and sessions

When the person has added a git repository to Greenroom (Sessions), each of its worktrees is a session, with its
own simulator and its own app data. The shim (`Greenroom --mcp`) tells the app where it was started, with every
request it forwards:

| Header | Value |
| --- | --- |
| `X-Greenroom-Cwd` | the shim's working folder, percent-encoded |
| `X-Greenroom-Parent` | the process id of the program that started the shim (the agent) |

The app ties the connection to the session whose worktree contains that folder (`git rev-parse --show-toplevel`,
symlinks resolved; a subfolder counts, and a folder in no added worktree ties to none). It keeps the folder and the
parent process id per connection, so several agents in different worktrees stay apart, and the Agent popover shows
one activity feed per session (and one for calls tied to none), each entry saying which session it came from.
Older shims send neither header and everything works as before.

- `launch` **without `apk`** starts the connection's session's simulator from its newest build, with the session's
  data and as a click on its row does; if that simulator is already running it is selected (device and other
  options are not applied to a running one). Without a session it answers `this folder is not a worktree of a
  repository added to Greenroom: pass apk`; with a session that has no build, `no build yet for <branch>`.
- `launch` **with `apk`** that is the session's own build (its newest output or stored build) runs on the session's
  data and replaces the session's running simulator, if any: one simulator per data slot, and the old one exits
  first so its data is kept. Any other APK starts a simulator of its own, on the default data, beside the session's.
- `launch` with **`fresh: true`** inside a session never touches the session's data: the build starts beside the
  session's simulator on a separate, empty data slot, and the answer says so.
- `simulators` lists each simulator with its session's branch: `(session feat-login)`.

The headers are hints from a local program that already holds the token. They select a row and grant nothing: no
tool can reach a file or an app it could not before, and the folder is never read, only compared with the added
worktrees.

## What an agent cannot do

- Name a file for the engine to read or write. `screenshot` and `logs` answer with their content; nothing else
  touches the disk on an agent's say.
- Send the engine a raw command. Settings and keys are checked against fixed patterns.
- Act while paused. The Agent popover's switch refuses every action until it is lifted; reading still works.

## Who can reach it

The app listens on the loopback interface only, on a port the system picks, and answers only requests carrying a
token it writes to `~/Library/Application Support/Greenroom/agent.json` (readable by you alone). A request with an
`Origin` header, which a browser adds to any page's cross-site request, is refused, as is one whose `Host` is not
this address: a web page cannot drive it. `scripts/mcp-check.py` runs a session as an agent would.

An agent you connect sees the screens and logs of the apps you run, as you asked it to. Greenroom itself sends
nothing anywhere ([PRIVACY.md](../PRIVACY.md)).
