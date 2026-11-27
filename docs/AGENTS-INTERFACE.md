# The agent interface

Greenroom serves the [Model Context Protocol](https://modelcontextprotocol.io), so a coding agent can launch, drive
and check Android apps in the same simulators the person at the Mac is looking at.

## Connecting

Claude Code, two ways. Use one: with both, Claude Code lists the same tools twice.

**The plugin** brings the server and a skill that teaches the loop under "Verifying a change" below, also run by
hand as `/greenroom:verify`. This repository is its own marketplace; inside Claude Code:

```
/plugin marketplace add aglose/greenroom
/plugin install greenroom@greenroom
```

(From a shell: `claude plugin marketplace add aglose/greenroom`, then `claude plugin install greenroom@greenroom`.)
The plugin's server is a script, `plugin/scripts/greenroom-mcp.sh`, that runs `Greenroom --mcp` from
`/Applications/Greenroom.app`, else `~/Applications`, else the copy Spotlight finds by bundle id, and says so on
standard error when there is none. `GREENROOM_APP` names another copy (a build of your own). Its tools are named
`mcp__plugin_greenroom_greenroom__launch` and so on. Settings > Claude Code shows the two lines; Greenroom does not
run them, and its "connected" line is about Connect alone. `scripts/plugin-check.py` checks the manifests and runs
the script against a built app; to try the plugin from a checkout without installing it,
`claude --plugin-dir plugin` (not with `--strict-mcp-config`, which leaves out a plugin's servers too).

**Connect**: Settings > Claude Code > Connect Claude Code shows the exact command and runs it on a click, with
your own `claude` program found on your login shell's PATH. It says when Greenroom is already connected, when
`claude` is not installed, and shows `claude`'s own words when the command fails; Disconnect runs the matching
`claude mcp remove`. By hand it is:

```bash
claude mcp add --scope user greenroom -- "/Applications/Greenroom.app/Contents/MacOS/Greenroom" --mcp
```

If `claude` already has a `greenroom` entry that runs another copy of the app, Settings says so and offers
Reconnect (remove, then add). The `claude mcp` flags were checked against the CLI's `--help` and exercised only
against a stand-in `claude`, never run for real; they are in one place, `ClaudeConnect.swift`. Each call is stopped
at a deadline, and none runs on the app's main thread.

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
| `set` | appearance, locale, font scale, rotation, network, device, time zone, animation scale, permissions, GPS location (`"LAT LON"` or a moving route `run`/`bike`/`drive`, `none` clears it); home, resume, lock, unlock, recreate, restart, process-death |
| `screen`, `check`, `wait_for`, `screenshot`, `logs` | reading and verifying |
| `session` | this worktree's session: branch and commit, clean or not, its build (age, source, current or stale), the default recipe, the base, whether its simulator runs, the Claude session's title when known |
| `build` | run a recipe for the session and wait (`recipe`, `timeout_s`: 10 to 200 s, default 200): answers the build's key and age, or the log's last error lines |
| `link_apk` | link a local `.apk` file on disk (`apk`, optional `pr_number`, `open`) to the current worktree session and/or pull request (also callable from any shell script via `Greenroom --link-apk PATH.apk [--pr N] [--worktree DIR] [--open]`) |
| `changes` | the session's newest build against a base (`base`, `timeout_s`: 10 to 200 s, default 200): `+ Settings > Privacy (new) [s4]`, `~ Trips: 4,812 px differ (0.35%), 1 route added, 2 texts changed [s3]` (the reasons follow the colon: pixels, structure, routes, texts), `> Trips: "Open Home" now leads to Inbox` for a control that was redirected, `- Legacy import (gone) [s9]`, then counts, crashes (new, fixed or still there, when answered from history) and what the walk did not finish. When both builds have a stored map the first line says `changes from history, no walk started:` and a `baseline:` line says where the base came from; `base: snapshot:COMMIT` compares with the stored map of that commit, no build needed. `screenshot` takes `screen` (an id in brackets) and `side` `head`, `base` or `diff` for the pictures, which a comparison from history reads from the store |
| `history` | the maps stored for the session's repository and profile, newest first: commit, date, screens, and what changed against the one before. With `screen` (a title or id): that screen's lineage, a line per commit that changed it (`visual`, `structure`, routes, texts). `screenshot` with `screen` and `commit` answers the stored picture. It only reads |
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
  first so its data is kept. Any other APK starts a simulator of its own, on its device's data (as a person's plain
  launch: see the README's "App data per device"), beside the session's.
- `launch` with **`fresh: true`** inside a session never touches the session's data: the build starts beside the
  session's simulator on a separate, empty data slot, and the answer says so.
- `simulators` lists each simulator with its session's branch: `(session feat-login)`.

The headers are hints from a local program that already holds the token. They select a row and grant nothing: no
tool can reach a file or an app it could not before, and the folder is never read, only compared with the added
worktrees.

## Verifying a change

From a worktree of a repository added to Greenroom, with the agent started in that folder:

1. `session`: the branch, whether the build is `current` or `stale`, and the base.
2. `build`: runs the workspace's recipe and waits. It answers `built <key> ...`, or the last error lines of the log
   to fix. The session's simulator reloads on the new build with its data kept.
3. `changes`: what differs from the base, screen by screen. A `~` line says why: a pixel count is a screen that looks
   different, and routes and texts say what a control or a string did (`> Screen: "Open Home" now leads to Inbox` is a
   redirected control). `history` lists the maps stored for earlier commits and one screen's lineage over time; `screenshot` with its `screen` id and `side: diff` shows where. `+` and `-` are screens the change
   added or removed.
4. `launch` (with no `apk`), then `tap`, `type`, `check` and `screenshot` on the screens the change touched.
   `check` answers `PASS` or says what is missing.

## What `build` and `changes` can and cannot start

- `build` runs a recipe through the same queue as the Build button, one build at a time per repository. The
  `remote` recipe uploads source code to the person's own boat.dev account, so it runs only after the person has
  allowed it for that repository in Greenroom; an agent that asks for it without that yes gets a failure telling it
  so, and can never give the yes itself. `ci` fetches what CI already built for the commit and never starts a
  workflow from an agent's call (the answer says so when there is no run); only the person's Build button may.
  `build` counts as an action: it is refused while the agent is paused.
- `changes` answers from stored maps (history) when both builds' commits have one: no walk, no simulator, and its first line says so.
  Otherwise it starts a walk of the two builds (hidden simulators, a minute or two for a large app) when that pair has
  not been compared, and answers from the stored one otherwise. `history` never walks. It never starts a build of the base: a base nothing
  built (a branch, a commit or a pull request with no stored build, no CI build and no worktree with a fresh APK)
  is answered as text saying what would build it, and nothing runs. The base is the repository's base branch unless
  `base` says `session:BRANCH`, `pr:NUMBER`, a branch, tag or commit, or the full path of an `.apk` (anything else with a path is refused). It is also an action,
  refused while paused. `session` only reads, and works while paused.
- All three work only for a connection tied to a session; from any other folder they answer `this folder is not a
  worktree of a repository added to Greenroom`.

## The agent's session is recorded

While an agent drives a session's simulator, Greenroom records its screen: the first action starts
`evidence/<build key>/video/agent-<time>.mp4` in the state folder, with a chapter per tool call and `steps.jsonl`
beside it (one line per call: time, seconds into the video, tool, a short description, whether it failed).

What is written about a call is its shape, never its content: `type` is "typed 14 characters"; `open_url` is the
scheme alone for an app's own link and, for an http(s) link, host and path without query or fragment (a long or
token-looking path segment becomes "…"); `set` is the setting's name (only if it is one of the known settings) without
the value; `swipe` is its direction; a tapped or awaited text is "text of N characters"; `check` is how many texts it
looked for. Typed text, query strings and values are not in `steps.jsonl` or the chapter names. The video itself is
the screen as it was, so what was on screen is in it.

- It stops after 60 s without an agent action (a call still waiting, such as `wait_for`, counts as activity, but never
  for more than 10 minutes), when
  the simulator ends, when the repository's switch in the Agent popover goes off (at once, for every session of that repository), or when the app quits.
- A paused agent is not recorded: reading tools still answer while paused, but they neither start a recording nor
  add to one.
- It never starts while you are recording that simulator yourself. If you choose File > Record Screen while an agent
  recording runs, the agent's file is finished and kept and yours starts.
- A walk that `changes` or a new build starts uses its own hidden simulators; a live agent recording goes on, and an
  agent recording never holds a walk back (only your own recording does).
- The Agent popover says when it is recording and links the file. Files stay on this Mac under the build's evidence
  until the build is pruned; nothing leaves it. The switch is per repository, on by default.

Calls are handled one at a time, all agents' together, except `build` and `changes`, which wait for minutes and run
beside them: `session`, `screen` and the rest answer while one of those waits, but a long `launch` or `wait_for` holds
up the other ordinary calls, another agent's too. One `build` or `changes` call waits at most 200 s in all (resolving the base included), then says it is still going; calling again joins the
same build, base fetch or walk instead of starting another.

## Signing in: scripts

An agent never types a password (the instructions say so). The owner keeps sign-ins as variables in Greenroom's
Settings (in their login Keychain) and writes a script that types them (Device > Run Script > New Script…); once they
switch the script on for agents in Settings > Scripts, an agent can run it:

- `scripts` lists the scripts in Greenroom's scripts folder, whether the agent may run each, and the variables' names.
  No value is ever answered.
- `run_script` runs one on a simulator and waits (10-300 s, 120 by default): it answers the exit status, the last 40
  lines of output with every secret value as `••••`, and what changed on screen, as an action does.

The approval is the script's SHA-256, kept in the Keychain: a script that has changed since it was allowed is refused
until the owner allows it again, so an agent cannot edit an allowed script into one that prints a password. Scripts
in a worktree's `.greenroom/scripts` are the person's to run, never an agent's.

A variable may be a 1Password secret reference (`op://Private/My App/password`, Settings > Variables). The value is
read by the 1Password CLI (`op read`) when the script starts, so the credentials stay in the owner's vault, and 1Password
asks the owner to approve. A reference that cannot be read stops `run_script` before the script runs, with the CLI's
reason, never the value. The agent's view is unchanged: names only, output masked.

## What an agent cannot do

- Name a file for the engine to read or write. `screenshot` and `logs` answer with their content; nothing else
  touches the disk on an agent's say.
- Send the engine a raw command. Settings and keys are checked against fixed patterns.
- Act while paused. The Agent popover's switch refuses every action, `build` and `changes` included, until it is
  lifted; reading (`session`, `screen`, `screenshot`, `logs`...) still works.
- Allow the remote recipe, or start a CI workflow, or build a base: see above.
- Read a variable, or run a script the owner has not allowed as it is now: see "Signing in: scripts".

## Who can reach it

The app listens on the loopback interface only, on a port the system picks, and answers only requests carrying a
token it writes to `~/Library/Application Support/Greenroom/agent.json` (readable by you alone). A request with an
`Origin` header, which a browser adds to any page's cross-site request, is refused, as is one whose `Host` is not
this address: a web page cannot drive it. `scripts/mcp-check.py` runs a session as an agent would.

An agent you connect sees the screens and logs of the apps you run, as you asked it to. Greenroom itself sends
nothing anywhere ([PRIVACY.md](../PRIVACY.md)).
