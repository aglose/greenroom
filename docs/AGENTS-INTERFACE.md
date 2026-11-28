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
standard error when there is none. `GREENROOM_APP` names another copy (a build of your own). The plugin's `bin/`
holds the `greenroom` command (below), which Claude Code puts on its Bash tool's PATH. Its tools are named
`mcp__plugin_greenroom_greenroom__launch` and so on. The plugin's `hooks/hooks.json` is the session status (below).
The Connect screen shows the two lines; Greenroom does not
run them, but it counts an enabled plugin as connected (`claude plugin list`) and does not offer to add the server
a second time. `scripts/plugin-check.py` checks the manifests and runs
the script against a built app; to try the plugin from a checkout without installing it,
`claude --plugin-dir plugin` (not with `--strict-mcp-config`, which leaves out a plugin's servers too).

**Connect**: the Connect screen (first run, File > Connect Agents…, and the same list in Settings > Agents) lists
the harnesses found on this Mac, shows what connecting each would run or write, and connects the ticked ones on
one button. It says when Greenroom is already connected, when a harness is not installed, and shows the harness's
own words when a command fails; each row's details have Disconnect.

| Harness | Connect runs or writes | Found by |
| --- | --- | --- |
| Claude Code | `claude mcp add --scope user greenroom -- "<Greenroom>" --mcp`; removed with `claude mcp remove --scope user greenroom` | `claude` on your login shell's PATH |
| Codex | `codex mcp add greenroom -- "<Greenroom>" --mcp`; read with `codex mcp get greenroom --json`, removed with `codex mcp remove greenroom` | `codex` on the PATH, else inside Codex.app or ChatGPT.app |
| Cursor | the `greenroom` entry under `mcpServers` in `~/.cursor/mcp.json` (the other entries are kept; a file that is not plain JSON is left alone) | Cursor.app, or `cursor-agent` on the PATH |
| any other | nothing: "Another agent" shows the stdio command and the JSON to paste | |

`<Greenroom>` is this copy's program, `/Applications/Greenroom.app/Contents/MacOS/Greenroom` when installed there.
If a harness already has a `greenroom` entry that runs another copy of the app, the row says so and offers
Reconnect. The `claude mcp` lines and the shape of their answers were read from a real Claude Code (2.1), and
Codex's and Cursor's were run against a real Codex (0.172) and a real Cursor (3.32), below; every check runs
stand-ins (`--connect-check`). The command lines are in `ClaudeConnect.swift` and `Harnesses.swift`. Each call is
stopped at a deadline, and none runs on the app's main thread.

Disconnecting removes what connecting added. Cursor's `~/.cursor/mcp.json` is removed when Greenroom's entry was
all it held. Codex writes `~/.codex/config.toml` itself, in its own layout: after `codex mcp add` and
`codex mcp remove` the file says the same as before, but Codex may have re-sorted its keys and rewritten numbers
(`120` as `120.0`).

**Session status** comes from each harness's own hooks, which connecting adds and disconnecting removes:

| Harness | Hooks are in | For |
| --- | --- | --- |
| Claude Code | the plugin's `hooks/hooks.json`; `~/.claude/settings.json` when connected with `claude mcp add`, or when the installed plugin is from before it had hooks (the row then offers "Add the Hooks") | `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Notification` (a permission or a question; idle), `Stop`, `SessionEnd` |
| Codex | `~/.codex/hooks.json` | `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Stop` |
| Cursor | `~/.cursor/hooks.json` | `sessionStart`, `beforeSubmitPrompt`, `postToolUse`, `afterFileEdit`, `stop`, `sessionEnd` |

Each hook runs `"<Greenroom>" --cli hook EVENT --harness NAME` (the plugin's run its own `bin/greenroom`). Only the
`hooks` value of the file is touched: the hooks you have there stay, in their order, and every other byte of the
file is kept. A file that is not laid out as the harness documents is left alone and the row shows what to paste.
Greenroom recognises its own lines by their shape, rewrites them when this copy moved, and removes the file when
nothing else is left in it. Codex runs a new hook only after you trust it (`/hooks` in Codex, or Settings > Hooks
in its app), so Codex's status starts once you have. The Debug copy writes no hooks.

From the hooks every harness's session has one status, shown on its row and in `session` (`agent session: Codex
(working)`): **working** from a prompt or a tool call, **waiting** from a permission request or a question,
**idle** when the turn ends. What no harness says: that you allowed a permission (the session shows as waiting
until the tool finishes), and, except Claude Code a minute later, that you interrupted it (it shows as working
until 15 minutes pass with no hook). A session is known from its first hook after Greenroom opened, and by the
harness's name, its session id and its folder only. Claude Code's transcripts and T3 Code's threads are still
read for titles and pull requests, and for sessions from before the harness was connected (Settings > Agents).

**A walk can wait for the turn's end.** A session row's menu has Walk New Builds Automatically > Wait for the Agent's Turn to End
(`workspace` setting `auto: on_turn_end`): a build that lands while an agent is mid-turn in that worktree is not
walked until its turn ends, so the builds it makes along the way are not walked one by one. It starts no build,
and with no agent heard in the worktree it is the same as walking every build.

**Seen on real harnesses** (November 2026, with `Greenroom --real-harness`, below):

- **Codex 0.172.** `codex mcp add`, `mcp get --json` (the command sits under `transport`; a missing server makes
  `get` exit 1) and `mcp remove` work as the connector expects. Codex names itself `codex-mcp-client`, lists the
  skill in `~/.agents/skills/greenroom`, and calls Greenroom's tools from `codex exec`. A hook it does not trust
  yet is skipped without a word; once trusted (or with `codex exec --dangerously-bypass-hook-trust`),
  `SessionStart`, `UserPromptSubmit`, `PostToolUse` (after a shell command and after an MCP tool) and `Stop`
  arrive, and the session shows as working, then idle. Codex has no hook for a session's end.
- **Cursor 3.32.** Opening a window starts the server in `~/.cursor/mcp.json` without asking; Cursor names itself
  `cursor-vscode`. It loads all six hooks from `~/.cursor/hooks.json` and takes `{"continue":true}` and `{}` as
  valid answers; `beforeSubmitPrompt`, `postToolUse` (after an MCP tool) and `stop` arrive from its agent. It did
  not run `sessionStart` for a new conversation in the editor, and when the app quits it asks for `sessionEnd`
  but fails to run it (its log: "MainThreadShellExec not initialized"), so a session whose window closed stays
  shown as idle until it ages out.
- **Cursor also reads Claude Code's files**: the hooks in `~/.claude/settings.json` (they run beside its own;
  Greenroom hears a turn's end once) and Claude Code's installed plugins. With Greenroom's plugin installed in
  Claude Code, Cursor starts that plugin's server too, so a Cursor connected here lists Greenroom twice: turn one
  of the two off under Cursor's Settings > MCP.

`Greenroom --real-harness claude|codex|cursor look|connect|disconnect` does from a terminal what the Connect
screen's buttons do for one harness, against the real program and the real files, and prints what the harness
then says. `look` changes nothing. It is not a check and no script runs it. In the Debug copy it connects the
Debug copy, which the screen never does: disconnect it again afterwards.

Any other MCP client: run that program with `--mcp` as a stdio server. The toolbar's Agent button (✦) has the
command for this copy of the app, a log of what agents did, and a switch that pauses them.

**The Debug copy** (`scripts/bundle.sh --variant debug`) is for developing Greenroom itself, and is never added to
every project: this repository's `.mcp.json` registers it as `greenroom-debug` (through
`scripts/greenroom-debug-mcp.sh`, which finds the installed Greenroom Debug.app, else this checkout's build), so
agents working in the repository or one of its worktrees have it and no others. Claude Code asks once per worktree
whether to use a project's servers. Its Connect screen connects nothing; it looks for a `greenroom-debug` entry
at user scope left by an earlier build and offers to remove it. Its server instructions open with "This is
Greenroom Debug, the development build of Greenroom itself. Use it only when asked to test the debug build; for
testing an Android app use the greenroom server."

`Greenroom --mcp` holds no simulators itself. It passes each message to the running app, starting Greenroom in
the background if it is not open, so what an agent launches appears in the window and what the person opened is
there for the agent.

### The `greenroom` command

The same tools from a shell: for a harness that has a shell and weak MCP, for scripts, and for a harness's hooks.
It is a script inside the app (`Greenroom.app/Contents/Resources/bin/greenroom`) that runs the app's own program;
the Connect screen's "The greenroom command" row links it into a folder on your PATH (`~/.local/bin`, `~/bin`,
`/usr/local/bin` or `/opt/homebrew/bin`, the first that is on your login shell's PATH and can be written), shows
the `ln -sf` line before it runs, and removes the link again. A file there that is not Greenroom's link is left
alone, and when no folder can be written the row shows the `sudo ln -sf` line to run yourself.

```
greenroom session                      any tool, by its name
greenroom launch app.apk --fresh       the first arguments can go without their flag
greenroom tap --text Add --sim s2
greenroom check Saved --absent Error   exit 0 for PASS, 1 for FAIL
greenroom screenshot --out shot.png    a picture is saved and its path printed
greenroom tools                        the tools, one line each
greenroom help check                   one tool's arguments
greenroom -C ../other-worktree build   as if run from that folder
greenroom mcp                          the stdio MCP server (what a harness's config runs)
greenroom open [APK | DIR | LINK]      the window; an APK run in it; a worktree's session; a link
greenroom hook EVENT                   for a harness's hooks (below)
```

A flag is the tool's argument, with `-` for `_` (`--sim s2`, `--timeout-ms=3000`); one that takes a list is repeated; `--json '{…}'`
gives the arguments as the tool takes them over MCP. A call is tied to the worktree it is run from, as an MCP
call is tied to its agent's. The answer is printed as the tool gives it, a failure on standard error. The exit
status is 0, 1 when the tool failed or `check` answered `FAIL`, 2 for a wrong argument, and 3 when Greenroom could
not be reached. A tool call starts Greenroom in the background if it is not open, as `--mcp` does. The pause
switch holds for the command as for any agent.

**`greenroom hook EVENT`** is what a harness's hook runs (`--harness NAME`, and `--session ID` and `--cwd DIR`
where the harness does not write them as JSON to the hook's standard input). It tells the running app four
things: the harness's name, its session id, the working folder and the event's name. It reads nothing else from
what the harness hands it (no prompt, no tool input, no transcript, and not the account Cursor names there),
always exits 0, and when Greenroom is not open it tells nobody: a hook never starts the app and never holds up an
agent's turn. It prints nothing, except with `--harness cursor`, because Cursor reads a hook's answer:
`{"continue":true}` for `beforeSubmitPrompt` and `{}` for the rest, app open or not. The app keeps the newest 200
in memory, lists them in `agent_activity` (those of the caller's worktree; `all: true` for every one) and builds
each session's status from them (above).

**Links.** `greenroom://` opens a place in the window, from a terminal (`greenroom open LINK`, `open LINK`), a pull
request's description or a chat: `greenroom://open` (the window), `greenroom://connect` (the Connect screen),
`greenroom://apk` (the APK screen) and `greenroom://session?path=DIR` (the session of that worktree, when
Greenroom has it). A link only navigates: it adds no repository, runs no APK and changes no setting, because a
link can come from anywhere. `greenroom open DIR` and `greenroom open app.apk` do add and run, as a command you
typed. The Debug copy's links are `greenroom-debug://`, so a `greenroom://` link always opens the release.

**The skill.** The loop under "Verifying a change" is one text, `plugin/skills/verify/SKILL.md`. Claude Code gets
it from the plugin. For the rest the Connect screen writes it as a file, when a harness is connected and with
"Add the Skill":

| Harness | Where the skill is |
| --- | --- |
| Claude Code with the plugin | in the plugin (`/greenroom:verify`); Greenroom writes none |
| Claude Code connected with `claude mcp add` | `~/.claude/skills/greenroom/SKILL.md` |
| Codex, Cursor | `~/.agents/skills/greenroom/SKILL.md`, one file for both |
| any other that reads `~/.agents/skills` (Copilot CLI, opencode, Gemini CLI, Goose, Amp) | the same file, with "Add the Skill" under "Another agent" |

The file ends with a line saying Greenroom wrote it and for which harnesses. Greenroom rewrites and removes only
a file with that line: a `SKILL.md` of your own in the same place is never touched, and the row says it is there.
Disconnecting a harness takes its name off; the file goes when the last name does. Looking (opening the screen,
launching the app) creates no file; it brings one Greenroom wrote up to date after an update. The Debug copy
writes no skill and links no command.

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
| `launch` | start an APK: `apk` (a path, or `sample` for the sample app that comes with Greenroom; left out inside a worktree of a repository added to Greenroom: see below), and optionally `device`, `appearance`, `locale`, `font_scale`, `fresh`, `skin` (a stored device skin) and `options` (further apksim options as one line; Greenroom's own `--headless`, `--window`, `--control`, `--data-slots` are left out). In a worktree the repository's own skin and options come first |
| `simulators`, `close` | what is running; stop one |
| `tap` | by `ref`, by `text`, or at `x`,`y` |
| `type` | `text`, into the field named by `ref` or `tap_text`; `enter` |
| `key`, `back`, `swipe`, `open_url` | keys, Back, a swipe by `direction` or coordinates, a deep link |
| `set` | appearance, locale, font scale, rotation, network, device, time zone, animation scale, permissions, GPS location (`"LAT LON"` or a moving route `run`/`bike`/`drive`, `none` clears it), `skin NAME` or `off` (this simulator only); home, resume, lock, unlock, recreate, restart, process-death |
| `screen`, `check`, `wait_for`, `screenshot`, `logs` | reading and verifying |
| `session` | this worktree's session: branch and commit, clean or not, its build (age, source, current or stale), the default recipe, the base, the repository's skin and launch options, whether its simulator runs, the Claude session's title when known |
| `launch_settings` | the repository's device skin and custom apksim launch options, used by every simulator Greenroom starts for it and by its walks and comparisons (a walk with other options is another map history). Without arguments it answers them and the stored skins; `skin` (a name, or `""`/`off`) and `options` (the whole line) change them. A running simulator takes a new skin at once, new options at its next launch |
| `build` | run a recipe for the session and wait (`recipe`, `timeout_s`: 10 to 200 s, default 200): answers the build's key and age, or the log's last error lines |
| `link_apk` | link a local `.apk` file on disk (`apk`, optional `pr_number`, `open`) to the current worktree session and/or pull request (also callable from any shell script via `Greenroom --link-apk PATH.apk [--pr N] [--worktree DIR] [--open]`) |
| `changes` | the session's newest build against a base (`base`, `timeout_s`: 10 to 200 s, default 200): `+ Settings > Privacy (new) [s4]`, `~ Trips: 4,812 px differ (0.35%), 1 route added, 2 texts changed [s3]` (the reasons follow the colon: pixels, structure, routes, texts), `> Trips: "Open Home" now leads to Inbox` for a control that was redirected, `- Legacy import (gone) [s9]`, then counts, crashes (new, fixed or still there, when answered from history) and what the walk did not finish. When both builds have a stored map the first line says `changes from history, no walk started:` and a `baseline:` line says where the base came from; `base: snapshot:COMMIT` compares with the stored map of that commit, no build needed. `screenshot` takes `screen` (an id in brackets) and `side` `head`, `base` or `diff` for the pictures, which a comparison from history reads from the store |
| `history` | the maps stored for the session's repository and profile, newest first: commit, date, screens, and what changed against the one before. With `screen` (a title or id): that screen's lineage, a line per commit that changed it (`visual`, `structure`, routes, texts). `screenshot` with `screen` and `commit` answers the stored picture. It only reads |
| `compare` | how two simulators' screens differ: `-` only on the base, `+` only on the other, `>` moved, and the share of pixels that differ; `map` adds a picture of where |

### Debugging: what the panes show

| Tool | |
| --- | --- |
| `network` | the app's HTTP traffic as the Network pane has it: `#12 GET 200 84 ms 3.1 KB https://...` (`mocked` when a rule answered), `filter`, `failed`, `limit`. With `id`: that exchange's headers and bodies, JSON pretty-printed, cut at 8 KB; `Authorization`, `Cookie`, `Set-Cookie` and any header named like a token, secret, password or API key are `••••` |
| `network_rule` | the Network pane's rules: `list`, `add` (`method`, `pattern` with `*`, `status` or 0 to only delay, `body`, `patch` for a JSON merge patch over the server's answer, `content_type`, `latency_ms`), `remove` (`rule`), `clear` |
| `perf` | frame rate, p50/p95 frame times and the share on pace since the last call, Java heap, footprint, CPU over `sample_ms`. It reads the same counter as the Diagnostics pane, so the pane's next sample starts from the agent's call |
| `accessibility` | the Diagnostics pane's audit: each finding with its bounds and the node it is on |
| `background` | scheduled jobs, services and alarms; `run_job` runs a job now |
| `clipboard` | the device's clipboard, or `text` to set it |
| `inspect` | one node (`ref` or `text`): kind, text (never a password field's), hint, content description, resource id, bounds, where a tap lands, the box that takes it, and accessibility problems (no label, under 48 dp) |
| `set` | also takes the Device pane's controls: `statusbar`, `navbar`, `keyboard`, `layoutbounds`, `clock` (ISO 8601 or `real`), `thermal`, `bluetooth`, `fold`, `tilt`, `shake`, `light`, `proximity`, `camera`, `biometrics`, `lowmemory`, `push` (a notification's text), `notification` (opens the last) |
| `devtools` | the developer hooks: `status`, `adb_on` (answers `adb connect localhost:PORT`), `adb_off`, `debugger_on` (a JDWP port for Remote JVM Debug), `debugger_off`, `har_record`, `har_save`, `har_stop`, `har_list`, `har_replay` (`name` from `har_list`). Each but the reading ones restarts the app with the same options and data, and the answer starts with the restarted simulator's id. HARs are kept in the engine's `hars` folder; an agent replays only those, never a file it names |
| `recorder` | the flight recorder: `status`, `on`, `off`, `save` (answers the recording's name), `list` |
| `replay` | replays a saved recording headless on its own build or `apk`, and answers `same`, `diverged` (point, pixels), `crashed` or `cannot replay`. It waits up to `timeout_s` (200 s); calling again with the same recording joins it |
| `tests` | runs instrumentation tests headless: `test_apk`, `app_apk` (default: the worktree's build, else the only running simulator's APK), `filter`; answers passed, failed and ignored with each failure's first stack lines. Without `test_apk` it answers the last run; `stop` ends it |
| `snapshots` | the screenshot tests the owner set up in Snapshots: `status`, `run`, `record`, `accept` (`ids` as `screen/combo`). The spec is the owner's choice; `record` and `accept` write golden pictures in the repository |

### Greenroom itself

| Tool | |
| --- | --- |
| `app` | the version, the engine's, the state folder, what the person sees on the stage (the devices, waiting for an agent, the Connect screen, the APK screen), and every app setting with its value. `setting` and `value` change `sessions_warm`, `auto_archive`, `jobs_at_once`, `evidence_cap_gb`, `build_timeout_minutes`, `reopen_last`, `app_icon`, `update_checks`. `crash_reports`, `usage_reports`, `claude_sessions`, `t3_sessions` and `agents_paused` are answered and never set |
| `workspace` | a repository's settings (default: the connection's; `repo` names another by folder name or path, so an agent outside every worktree can use it). Settable: `base_ref`, `module`, `variant`, `default_recipe`, `auto`, `walk_with_data`, `quick_walk`, `keep_main`, `unsigned_baseline`, `skip_local_apk_scan`, `disable_local_builds`, `ci_workflow`, `ci_artifact`, `ci_apk`. The skin and options are `launch_settings` |
| `sessions` | every repository with its sessions (branch, title, build and whether it is stale, simulator, pull request, the walk of its newest build, and where the sidebar files it when that is not Quiet: `ready for review: 5 of 5 checks passed`, `needs you: Codex is waiting for you`, `working: …`), its main build and the pull requests Greenroom holds |
| `session_action` | by `session` (a branch, title or worktree path; default the connection's): `open`, `close`, `build` (queued, not waited for), `cancel_build`, `walk`, `stop_walk`, `show`, `hide`; and `add_repository` with `path` |
| `jobs` | the job queue, then the recent jobs; a running job says how far it is in what it works on ("23.1 of 48.0 MB · 3.2 MB/s", "214 of about 530 tasks", "9 of 23 screens") when it can; `cancel`, `pause`, `resume`, `prioritize` one by its `job` id, `pause_all`, `resume_all` |
| `pull_requests` | `list`, `add` (a number or address, fetches its CI build), `fetch`, `open`, `close`, `remove` |
| `matrix` | one APK on every combination of `devices`, `appearances`, `locales` and `font_scales` (at most 16), side by side with input mirrored; answers each simulator's id. `close` ends it |
| `agent_activity` | the Agent popover's log: the newest calls, the client, whether agents are paused and which repositories record them |

Tools that both read and change (`app`, `workspace`, `launch_settings`, `jobs`, `pull_requests`, `network_rule`,
`recorder`, `devtools`, `snapshots`, `tests`, `clipboard`, `background`) answer while the agent is paused when the call
only reads (no `setting`, a `list` or `status` action), and refuse otherwise.

With several simulators running, each tool takes `sim` (`s1`, `s2`...). A second `launch` puts its simulator
beside the first, so the same build can be driven on a phone and a tablet at once.

To check a change against the build before it: `launch` both APKs, do the same steps on each, and `compare`.
`s1 vs s2: SAME | same content, identical pixels` means the change did nothing visible on that screen; otherwise
the lines say exactly what moved, appeared or went.

## Worktrees and sessions

Each worktree of a git repository in Greenroom's Sessions is a session, with its own simulator and its own app
data. A repository gets there by itself: the first tool call from a worktree with an Android app in it (a Gradle
application module, or a built APK in its outputs) adds its repository, and the window says so, with Undo. Three
things are not added: a repository with no Android app (an agent that launches an APK by its path from some other
repository adds nothing), one the person removed from Sessions (only they can add it back, with File > Add
Repository…), and any repository while agents are paused. A repository an agent added does not fetch or build its
base branch by itself (`keep_main` starts off; `workspace` shows it), and the person is not asked for a skin or
launch options. The person can also add one by hand. The shim (`Greenroom --mcp`) tells the app where it was started, with every
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
  repository added to Greenroom: pass apk`, with the reason the folder's repository was not added in brackets when
  there is one (`(no Android app was found in tools, so it was not added)`); with a session that has no build, `no build yet for <branch>`.
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

**Where the person sees a session.** The sidebar files sessions by what they need from the person, not by
repository: Ready for review, Needs you, Working, Quiet. What an agent does decides it:

- A turn that runs (its harness's hook), a build, or a call in the last minute: Working.
- A session whose agent called `review` is **Ready for review** from that call until the person answers.
- A `check` counts for the session whose simulator it looked at (else the caller's), on the build that session
  then had. When the turn ends with the build still current and at least one check on it, the session is **Ready
  for review**: the person is told (the top bar's count, the Dock badge, a notification if they turned those on)
  and its card says "5 of 5 checks passed" or "3 of 4 passed · 1 failed". A turn that ends with no check goes
  Quiet, so an agent that wants its work looked at checks what it changed before it stops.
- A harness waiting on a permission, the app on a sign-in screen the person has a script for, and `build` with the
  remote recipe refused for want of the person's yes: Needs you.

`sessions` says where each is filed. Hooks are what make this work for a harness (see "Session status"): without
them a session is Working while calls arrive and Quiet after.

## Spec, review, and what the person says

The loop has two ends an agent declares. Both need a session (a worktree of an added repository).

- **`spec`** (`title`, `text`, `criteria`, `link`) says what the session is for, before the work. The person sees
  it in the session panel, beside the simulator. Calling it again replaces it: a criterion whose words did not
  change keeps its tick, so a spec can be refined mid-task. With no arguments it answers the spec as it stands,
  each criterion `[ ]`, `[passed]` or `[FAILED]` (and "on an older build" when the build has changed since).
- **`check`** takes `criterion`: the criterion's number (1 is the first; `"2,3"` for several) or its words. A
  `PASS` ticks it and a `FAIL` marks it failed with what was wrong, at that second of the session's recording, so
  the person can play the moment. A criterion the spec does not have adds a line to the answer and fails nothing.
  For what texts cannot show, `check` with `criterion`, `passed` and `note` (and no `visible` or `absent`) records
  the agent's own judgement: its answer reads `PASS | Activity | the agent's word: ...`, and the person is shown
  it as the agent's word.
- **`review`** (`summary`, `timeout_s` 10 to 1800, default 200) says the agent is done. The session is filed as
  Ready for review at once, whatever else is true of it, and the call waits. It answers `approved`, or
  `changes requested:` followed by the person's comments, one a line; a pinned comment adds
  `pinned to "Total" [left,top,right,bottom] on CartActivity (picture 1)` and the picture is an image block of the
  same answer. When the wait ends first it answers `still waiting: ...`; calling it again joins the same request.
  An approval is for the commit the session was at: an agent that commits more and asks again is asked about
  anew. If the person marks the session reviewed without answering, the call says the request was dismissed.
- **`feedback`** answers what the person said that the agent has not been given (`nothing new from the person`
  when there is nothing), and with `all` the review's answer and every comment again.

What the person writes reaches the agent by the first of these, once:

1. the answer of a `review` call that is waiting;
2. the turn's end, where the harness's hook can carry words back: `greenroom hook Stop` then prints
   `{"decision":"block","reason":"..."}` for Claude Code and Codex, and `{"followup_message":"..."}` for Cursor's
   own `stop` hook, which each harness documents as "carry on, with this as the next instruction". A pinned
   comment's picture is named by its path. A turn the person stopped (Cursor's `status` not `completed`) is not
   continued, and Cursor running Claude Code's hooks is not answered through those (its own hook takes it);
3. the end of the next tool call's answer, as a block that begins `--- from the person at the Mac, in Greenroom`
   (pictures follow as image blocks).

An agent with no hooks and no `review` call still hears, by 3. Approve given while nobody waits is kept and
delivered the same way. `spec`, `review` and `feedback` work while agents are paused: they act on no simulator.

Nothing here approves or merges. Approve, Request Changes and Merge are buttons in the session panel; Merge runs
`gh pr merge NUMBER --squash|--merge|--rebase --match-head-commit SHA` as the person's own GitHub account, for the
commit the session is at, after asking them (and saying so first when checks failed, when a criterion failed or
was not checked, or when they have not approved that commit).

## Verifying a change

From a worktree of a repository added to Greenroom, with the agent started in that folder:

1. `session`: the branch, whether the build is `current` or `stale`, and the base. `spec` says what you are about
   to verify, so the person can follow it.
2. `build`: runs the workspace's recipe and waits. It answers `built <key> ...`, or the last error lines of the log
   to fix. The session's simulator reloads on the new build with its data kept.
3. `changes`: what differs from the base, screen by screen. A `~` line says why: a pixel count is a screen that looks
   different, and routes and texts say what a control or a string did (`> Screen: "Open Home" now leads to Inbox` is a
   redirected control). `history` lists the maps stored for earlier commits and one screen's lineage over time; `screenshot` with its `screen` id and `side: diff` shows where. `+` and `-` are screens the change
   added or removed.
4. `launch` (with no `apk`), then `tap`, `type`, `check` and `screenshot` on the screens the change touched.
   `check` answers `PASS` or says what is missing; with `criterion` it ticks the spec.
5. `review`, with a summary: the person approves or says what to change.

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
  worktree of a repository added to Greenroom`, and why it was not added.

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

- Name a file for the engine to write, or one to read other than an APK (`launch`, `tests`, `replay`, `matrix`) or a
  repository folder to add (`session_action add_repository`). `screenshot` and `logs` answer with their content; HARs
  and recordings are written in Greenroom's own state folder, and replayed by name only.
- Send the engine a raw command. Settings and keys are checked against fixed patterns.
- Act while paused. The Agent popover's switch refuses every action, `build` and `changes` included, until it is
  lifted; reading (`session`, `screen`, `screenshot`, `logs`...) still works.
- Allow the remote recipe, or start a CI workflow, or build a base: see above.
- Change what is the owner's alone: telemetry, reading Claude Code's or T3 Code's sessions, the pause switch, whether
  agents are recorded, sharing maps through git, custom recipes and the PR fetch script (programs Greenroom runs).
  `app` and `workspace` answer them and refuse to set them.
- Read a variable, or run a script the owner has not allowed as it is now: see "Signing in: scripts".

## Who can reach it

The app listens on the loopback interface only, on a port the system picks, and answers only requests carrying a
token it writes to `~/Library/Application Support/Greenroom/agent.json` (readable by you alone). A request with an
`Origin` header, which a browser adds to any page's cross-site request, is refused, as is one whose `Host` is not
this address: a web page cannot drive it. The `greenroom` command reaches the app the same way, with the same
token. `scripts/mcp-check.py` runs a session as an agent would (`--tools` checks the tools above and the command);
`--connect-check` covers the skill files and the link on the PATH, in a home folder of its own.

An agent you connect sees the screens and logs of the apps you run, as you asked it to. Greenroom itself sends
nothing anywhere ([PRIVACY.md](../PRIVACY.md)).
