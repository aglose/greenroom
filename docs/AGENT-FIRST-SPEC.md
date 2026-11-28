# Greenroom, agent-first: the spec

A spec (2026-11-27). The owner's decisions are at the end. **All nine steps, A1 to A9, are built**: A1 in `AgentAdoption.swift`,
`WaitingStage.swift` and the APK screen in `EmptyStage.swift`; A2 in `Harnesses.swift`, `ClaudeConnect.swift` and
`ConnectScreen.swift`; A3 in `CLI.swift`, `Links.swift`, `Skills.swift` and `plugin/bin/greenroom`; A4 in
`Hooks.swift` and `HookSessions.swift`; A5 in `Attention.swift`, `AttentionUI.swift` and `Work.swift`; A6 in `AgentReviewTools.swift`, `Review.swift`,
`SessionPanel.swift` and `Merge.swift`; A7 in `AgentTools.swift` (a device taken over) and `AgentServer.swift`
(the lanes); A8 in `CIWatch.swift` (checked by `--connect-check`, `--waiting-check`, `--attention-check`,
`--review-check`, `mcp-check.py` and `plugin-check.py`); A9 is the words outside the app (README, the plugin's
manifests and skill, the Homebrew cask's description, PRIVACY.md). Where a step built something other than what
this page first said, an "As An built it" paragraph says what, and what it left undone. The spec changes what Greenroom is for, what a new user sees first, and how the
window is arranged. The engine, the simulators, the tools in [AGENTS-INTERFACE.md](AGENTS-INTERFACE.md) and the
sessions model in [SESSIONS-PLAN.md](SESSIONS-PLAN.md) stay; most of this is a new front on what they already do.
The clickable prototype is [prototype/agent-first.html](prototype/agent-first.html).

## What Greenroom is

**Before:** a Mac app that runs an APK you drop on it, which agents can also drive.

**After:** the place an agent's Android work shows up to be watched, checked and steered. An agent is given a
spec, writes the code, and gets an APK built on this Mac or on CI. From the moment that APK reaches Greenroom it is
launched, driven and verified in a simulator the person can see the whole time. Many agents work at once; the
window says which one is ready for you.

Five rules everything below follows:

1. **The agent brings the work.** Nothing is dragged in. A session appears when an agent calls Greenroom.
2. **Any harness.** Claude Code, Codex, Cursor, Antigravity, Copilot, opencode, T3 Code and the rest connect the
   same way and look the same in the window. No screen says "Claude" where it means "agent".
3. **The person watches, judges and steers.** Every click still works: the mouse is still the finger. What is new
   is that the person can answer the agent from the window.
4. **The whole loop is on screen.** Spec, code, build, run, verify, review: each session shows where it is.
5. **Attention is routed.** The window, the Dock and a notification say which session needs you, so switching to
   whichever agent finished first is one key.

## The loop

| Stage | Who | What the window shows | Today |
| --- | --- | --- | --- |
| Spec | the person, in their harness | the task's title and its acceptance criteria, as a checklist | title only, read from Claude Code's and T3 Code's files |
| Code | the agent | "working", the files it changed, how long | a working/idle/waiting dot, Claude Code and T3 Code only |
| Build | the agent's `build`, or CI | the recipe, a timer, the log's last line; for CI the run and its link | built: local, ci, remote recipes, `link_apk`, the job queue |
| Run | Greenroom | the build on a device, reloaded in place with its data kept | built |
| Verify | the agent | each tool call as it happens, a pointer on the device, each criterion ticked by the `check` that proved it | calls and video are recorded; nothing ties a `check` to a criterion |
| Review | the person | a verdict (checks passed, screens changed), Approve or Request changes, comments pinned to the screen | missing: the person can only pause |

The row marked missing is the largest change: today the loop ends when the agent stops calling tools, and
Greenroom never learns whether the agent thinks it is done or what the person thought of it.

## Connecting agents

The question was whether MCP is the best way to connect harnesses. Researched on 2026-11-27 against each
harness's own documentation; what could not be confirmed is listed under "To check before building".

**Answer: MCP stays the tool channel, and it is not enough by itself.** Three facts decide it:

- **The part of MCP every harness implements is small**: tools, pictures in results, and (mostly) server
  instructions, over stdio or HTTP. Elicitation, resources, tasks and MCP Apps each work in two or three clients.
- **MCP 2026-07-28 took out what an app with a person watching would want**: sessions and requests from server to
  client are gone, and push moved to an Events extension no coding harness ships yet. A server cannot tell a
  running agent "the person left a comment".
- **Which session is working, finished or waiting is not in any tool protocol.** Harness hooks answer it.

So Greenroom has one core API and four ways in. Xcode, Chrome DevTools, Playwright, Figma and XcodeBuildMCP
arrived at the same shape.

| Way in | What it is for | Reaches | Today |
| --- | --- | --- | --- |
| **MCP server** (stdio shim to the running app) | the tools; a process per agent, which is how a call is tied to a worktree | every harness | built (`Greenroom --mcp`) |
| **`greenroom` CLI and one skill** | the same tools from a shell: for harnesses with weak MCP, for scripts and CI, and for hooks to call. The skill teaches the loop | any harness with a shell; skills in Claude Code, Codex, Cursor, Copilot, opencode, Antigravity | built in A3: `greenroom` (inside the app and in the plugin's `bin/`), and the skill written to `~/.agents/skills/greenroom` and `~/.claude/skills/greenroom` |
| **Hooks** | session start and end, turn finished, waiting for permission, file edited: what the sidebar's status needs, without the agent calling anything. A turn-end hook can also hand the agent the person's queued comments | Claude Code, Codex, Cursor, Antigravity | missing. Status comes from reading Claude Code's and T3 Code's private files, which neither promises to keep |
| **Per-harness package** | installs the three above in one step | Claude Code plugin; Agent Plugins 1.0 for Codex, Copilot, VS Code | Claude Code plugin with the MCP server and skill |

Getting word back to a running agent, most portable first:

1. **A tool that waits.** `review` (below) blocks until the person decides, as `build` waits today.
2. **The turn-end hook** returns the person's comments as the reason to continue. Works in the four harnesses with
   hooks.
3. **MCP Tasks**, where the client has them (Claude Code today): the call returns at once and the result wakes an
   idle agent. Right for "CI finished".
4. **Claude Code channels and plugin monitors**: real push, but a research preview behind an allowlist. Behind a
   flag at most.

Not building: A2A (nothing local uses it), MCP sampling, roots and resource subscriptions (deprecated in
2026-07-28), Claude Code's IDE lockfile protocol (undocumented), `.mcpb` bundles (Claude Desktop only). ACP and Codex's
app-server are for an app that starts agents itself, which Greenroom does not (decision 1). Later, if wanted: an
MCP Apps panel that puts the simulator inside Cursor's or VS Code's chat.

### Installing, per harness

The Connect screen finds what is installed and connects each with that harness's own command where it has one,
shown before it runs. It writes a config file only where there is no command.

Built in A2: the Tools column for Claude Code (`claude mcp add`; an enabled plugin counts as connected and is not
installed by Greenroom), Codex (`codex mcp add`) and Cursor (`~/.cursor/mcp.json`: the install link cannot be seen
to have worked, so the file is written, with every other entry kept). Built in A3: the Skill column for the same
three, so a row says "Adds Greenroom's tools and a skill"; "Another agent" has "Add the Skill" for the shared
folder, and the screen has a row that links the `greenroom` command into a folder on the PATH. Built in A4: the
Status column for the same three. Connecting writes each harness's hooks (`~/.codex/hooks.json`,
`~/.cursor/hooks.json`; for Claude Code the plugin's `hooks/hooks.json`, or `~/.claude/settings.json` when it is
connected with `claude mcp add` or its installed plugin predates hooks), touching only the file's `hooks` value and
keeping the person's own; disconnecting removes them; a row says "Adds Greenroom's tools, a skill and session
status". `HookSessions` is the one status model (working, waiting, idle, from the harness's name, session id and
folder), joined with what Claude Code's and T3 Code's files say; `onTurnEnd` holds a walk until the agent's turn
ends and starts no build. Every other harness found is
named under "Another agent", with the stdio command and the JSON to paste.

| Harness | Tools | Status (hooks) | Skill |
| --- | --- | --- | --- |
| Claude Code | the plugin (`claude plugin install`), or `claude mcp add` | the plugin's `hooks/hooks.json` | in the plugin; `~/.claude/skills/greenroom` when connected with `claude mcp add` |
| Codex (CLI, IDE, desktop) | `codex mcp add greenroom -- <shim>` | `~/.codex/hooks.json` (the person trusts it once with `/hooks`) | `~/.agents/skills/greenroom` |
| Cursor | the `cursor://…/mcp/install` link, else `~/.cursor/mcp.json` | `~/.cursor/hooks.json` | `~/.agents/skills/greenroom`, which Cursor reads too: one file for Codex and Cursor |
| Antigravity, Gemini CLI | `~/.gemini/config/mcp_config.json`; `gemini mcp add` | `~/.gemini/config/hooks.json` | its skills folder |
| VS Code Copilot, Copilot CLI | the `vscode:mcp/install` link; `~/.copilot/mcp-config.json` | Copilot CLI hooks | `~/.agents/skills/greenroom` |
| opencode | `opencode mcp add` | none | `~/.config/opencode/skills` |
| Zed, Goose, Amp, Devin Local | the settings file, or Goose's `goose://extension` link | none | `~/.agents/skills` where read |
| T3 Code, Conductor and other hosts | nothing of their own: they run Claude Code and Codex, which are connected above | the hosted harness's hooks | |
| Anything else | the stdio command, shown to copy | none: the session shows as "connected", with no working or finished state | the CLI |

A harness without hooks still works. Its sessions show what Greenroom can see for itself (calls arriving, a
build, a `review` asked for) and nothing about the time between.

### What a hook sends

`greenroom hook <event>` posts the harness's name, its session id, the working folder and the event to the
running app over the same loopback channel as the shim, and exits in a few milliseconds whether or not the app is
open. It never reads the transcript and never sends a prompt or a file's content. PRIVACY.md changes with it.
(Built in A3: the command, and the app keeping the newest 200 for `agent_activity`. It never starts the app.)
Once hooks are in, reading Claude Code's and T3 Code's files becomes the fallback for sessions started before
connecting, then goes.

### To check before building

- Whether a Claude Code plugin's hooks and `bin/` load for a plugin installed by `claude plugin install` from our
  marketplace as documented. (A3 ships `plugin/bin/greenroom` on that documentation; it was not seen on a real
  Claude Code's PATH.) (`claude mcp get` and `claude plugin list` were read from a real Claude Code 2.1 in A2
  and answer as `ClaudeConnect.swift` expects; `mcp add` and `mcp remove` are still only run against a stand-in.)
- Codex's `mcp add`, `mcp get --json` and `mcp remove` against a real Codex: A2 took them from its documentation.
  (Checked after A4 on Codex 0.172 with `Greenroom --real-harness codex`: they work as `CodexConnect` expects;
  the command sits under `transport` in the JSON, and `get` exits 1 for a missing server.)
- Codex's hook trust step: what the person sees, and whether a hook can be offered without it. (A4 writes
  `~/.codex/hooks.json` and says to trust the hooks in `/hooks`; the command line is kept the same from build to
  build so the trust, which is by the hook's hash, is asked once. Seen on Codex 0.172: an untrusted hook is
  skipped without a word in `codex exec`, and there is no command that trusts one, so the step stays the
  person's.)
- Cursor against a real Cursor. (Checked after A4 on Cursor 3.32 with `Greenroom --real-harness cursor`: it starts
  the server from `~/.cursor/mcp.json` unasked and runs the hooks. It also loads Claude Code's plugins and user
  hooks, so with Greenroom's Claude Code plugin installed it has Greenroom's server twice; and it fails to run
  `sessionEnd` when the app quits. docs/AGENTS-INTERFACE.md, "Seen on real harnesses".)
- What no harness's hooks say (A4): that a permission was granted (a session shows as waiting until its tool
  finishes) and, outside Claude Code's idle notification a minute later, that the person interrupted (it shows as
  working until 15 minutes pass with no hook).
- A turn's end that carries the person's words back (A6). Read from each harness's documentation on 2026-11-27,
  and not run on a real harness: Claude Code and Codex continue the turn when a `Stop` hook prints
  `{"decision":"block","reason":"..."}` (Codex: "it tells Codex to continue and automatically creates a new
  continuation prompt ... using your `reason` as that prompt text", and plain text on stdout is invalid for
  `Stop`, so the hook prints JSON or nothing); Cursor submits `followup_message` from its `stop` hook as the next
  user message, five times in a row at most by default. How Cursor reads `decision` from a Claude Code hook it
  runs is not documented, so that path is not used. Codex still runs only hooks the person trusted.
- Antigravity's file names and skills folder: sources disagree.
- Whether Cursor and VS Code show pictures from a tool result. Only Claude Code documents it.
- MCP Tasks in a second client. If only Claude Code has them, `review` and the CI wait stay blocking calls.

## Onboarding

The first screen today says "Drop an APK or Git Repository". It goes. First run is three steps, and each can be
left at any time.

1. **Connect your agents.** A list of the harnesses found on this Mac, each with what connecting does ("adds
   Greenroom's tools, a skill, and session status") and the exact command or file behind a disclosure. One button
   connects all that are ticked; each row then reads Connected, or says what the harness answered. Harnesses not
   installed are listed dimmed; "Another agent…" shows the stdio command.
2. **Give it something to do.** A prompt to paste into the agent, in two forms: for the person's own project
   ("Build this app and open it in Greenroom, then verify …") and for the bundled sample app, which needs no
   project and no build. The window listens: the moment an agent calls, it says which harness, from which folder,
   and opens the session. This is the proof the connection works, and it is the product's first impression: the
   agent's pointer moving on a device within a minute of installing.
3. **You are set.** What the sidebar's states mean, the key that jumps to the next session that needs you, and
   whether to notify.

A2 built steps 1 and 2 as screens on the stage (first run when no repository was ever added; File > Connect
Agents… at any time; the list of step 1 is also Settings > Agents). A5 built step 3: the four groups in a line
each, the key, and a switch for notifications (off until it is turned on; macOS asks once). When the agent's app
opens before the person reaches step 3, the screens close as before so the device is seen, and a line in the
window says the same in short, with "Notify Me" to click.

**The Debug copy is not for testing apps.** The release copy is the default everywhere; Greenroom Debug is for
developing Greenroom itself. So the Debug copy is never registered for every project: this repository's `.mcp.json`
registers it, which covers every worktree of the repository and nothing else, and its server instructions open by
saying what it is. Its Connect screen connects nothing and offers to remove an entry at user scope left by an
earlier build. (An agent that could call the Debug copy from another app's repository would add that repository
to the Debug copy's Sessions too.)

Below all three, small: "Run an APK yourself…" (⌘O).

**The APK screen.** Running an APK by hand has a screen of its own, reached from the Mac menu bar: File > Run an
APK… (⌘O). It takes the stage and holds what the first screen held: the drop outline, "Choose an APK…", the recent
APKs and the sample app, with a way back. An APK still opens from Finder and from `greenroom open` too. "Connect
Git Repo…", "Open a project folder…" and "Clone from GitHub…" leave the stage for the File menu and the sidebar's +
menu, for someone preparing a project before any agent runs.

**A repository adds itself.** Today an agent in a folder Greenroom has not been shown gets "this folder is not a
worktree of a repository added to Greenroom". Agent-first, the first call from a git worktree adds its repository
and makes the session, and the window says so ("Added homesafe: an agent called from feat/trip-rename", with
Undo). Three limits: only a repository with an Android app in it is added (an agent that launches an APK by its
path from some other repository adds nothing); a repository the person removed is not added again by an agent,
only by hand; and nothing is added while agents are paused. The same trust applies as now: the caller is a local
program holding the token, and adding a repository runs `git` in it and nothing else until a build is asked for.
The question about a device skin and launch options that follows adding by hand is not asked. And where a
repository added by hand fetches its base branch and builds it at once, one an agent added does not: "Keep main
built" starts off for it, so an agent's first call never starts a Gradle build nobody asked for. Until the person
turns it on, `changes` against the base branch has a build to compare with only when CI made one, and otherwise
says what would build it.

With no session and agents connected, the stage reads "Waiting for an agent" with the prompt to paste and the
connected harnesses, in place of a drop target.

## The window

```
┌───────────────┬────────────────────────────────────────────┬──────────────────┐
│ 1 ready · 1 needs you · 2 working            jobs · agents · ⌘K               │
├───────────────┼────────────────────────────────────────────┼──────────────────┤
│ READY         │  Spec ─ Code ─ Build ─ Run ─ Verify ─ Review │ Rename a trip   │
│  Rename a trip│                                            │ 5 of 5 passed    │
│  Rounding  ✗  │                                            │ [Approve] [Ask…] │
│ NEEDS YOU     │              the device                    │ Spec             │
│  Empty inbox  │         (agent's ring and pointer)         │  ✓ criterion …   │
│ WORKING       │                                            │ Activity         │
│  Dark mode    │                                            │  12:04 tap …     │
│  Offline      │   driving: Claude Code · Take over         │ ───────────────  │
│ QUIET         │                                            │ Tell the agent…  │
└───────────────┴────────────────────────────────────────────┴──────────────────┘
```

**Sessions, by what they need.** The sidebar groups sessions by state, not by repository (a switch gives the
grouping by repository back):

| Group | A session is here when | Card shows |
| --- | --- | --- |
| Ready for review | the agent called `review`, or its turn ended after a build and checks | checks passed and failed, screens changed, how long ago; oldest first, so the first to finish is on top |
| Needs you | the harness waits on a permission, the app needs a sign-in, a remote build needs a yes, the agent is paused | the question, and the button that answers it when Greenroom can |
| Working | a turn is running, a build or CI run is going, calls are arriving | the stage of the loop it is in, and for how long |
| Quiet | nothing for a while; the base branch | the build's age |

Each card carries the harness's mark, the task's title, repository and branch, and six small steps for the loop.
⌘1-9 still pick a row; a new key (proposed ⌘') goes to the next session in Ready or Needs you. The top bar
carries the counts and the Dock icon a badge. A notification is sent when a session enters Ready or Needs you
while Greenroom is not in front, if the person said yes in step 3.

**As A5 built it** (`Attention.swift`; the rule is one function, `AttentionState.judge`):

- **Ready for review** without `review` (decision 5): the harness's hook said the turn ended, the newest build is
  of the sources as they are, and at least one `check` ran on that build since the person last dealt with the
  session. `check` notes itself as it answers (`Work.swift`, kept in the state folder under `work/`), so this is
  what Greenroom saw, not what an agent said. A session whose agent starts a new turn goes back to Working. Until
  A6 brings Approve, a card in Ready has "Mark as reviewed" (on hover, and in its menu), which takes it out of
  Ready until its agent does more.
- **Needs you**: a harness waiting on a permission or a question (its hook, or what Claude Code's and T3 Code's
  files say); the app on a sign-in screen one of the person's scripts signs in from; an agent's `build` with the
  remote recipe refused for want of the person's yes; and agents paused while one is at work here.
- **Working**: a turn running, a build queued or running, or a tool call in the last minute.
- **Quiet**: the rest, and each repository's base branch row.
- Order: Ready and Needs you the longest waiting first, Working in the order it began, Quiet as last used. ⌘1-9
  pick rows in that order.
- A card: the harness's two letters in the group's colour (CC, CX, CU, T3; a T3 Code thread is marked by the
  harness it runs), the title, repository and branch (or the commit, when the title is the branch), six marks for
  the loop, and one line: the checks' count, who waits, the step under way and for how long, or the build's age.
- The repositories are listed under the groups, each with its + menu (worktrees not shown, recipes, skin, Keep
  main built, Remove), since the groups have no header for them.
- **Window > Group Sessions by Repository** (also Settings > Agents and ⌘K) gives the old sidebar back.
- The top bar's chip reads "1 ready · 1 needs you · 2 working" and a click goes to the next session waiting for
  the person; **Window > Next Session That Needs You** is ⌘'. The Dock badge counts Ready and Needs you.
- A notification is posted when a session enters Ready or Needs you while Greenroom is not in front, if the
  person turned them on. A click on it opens the session. One a session: a newer one replaces the one before.
- The `sessions` tool says each shown session's group when it is not Quiet.

The six marks use what is known today: Spec stays empty until A6's `spec`; Review is "waiting for you" in Ready.

**The loop strip** sits over the stage for the selected session: Spec, Code, Build, Run, Verify, Review, each
done, going, failed or not yet, with one line of detail (`local · 42 s`, `CI run 4812 · 3 min`, `4 of 5`). A
click opens that stage's detail: the build log, the CI run, the checks.

**The stage** is as now: the device is the hero and every click reaches it. While an agent drives, the device
has its ring and pointer and a line under it reads "Claude Code is driving · Take over". Take over pauses that
agent's actions for this session only (today's pause is all agents at once) until Hand back.

**The session panel** (right) replaces the Agent popover and is about one session:

- **Verdict**, when there is one: "5 of 5 checks passed · 2 screens changed", Approve and Request changes.
  Approve answers the agent. Once approved, a session with a pull request offers **Merge**: the pull request's
  number, its checks and whether it can merge, and one button that runs `gh pr merge` as the person, with the
  method the repository allows (squash where it is allowed). A session with no pull request says so and offers
  to ask the agent for one. Merging is the person's alone: no tool lets an agent do it, and it is asked once
  more when checks are failing.
- **Spec**: the task as the agent declared it, each criterion with its state and the evidence behind it: the
  `check` that passed, at its second in the recording. A click plays that moment.
- **Activity**: the calls, as the Agent feed has them, with the person's comments in line.
- **Tell the agent**: a comment, optionally pinned to a node picked on the device (the Inspector's picker). It is
  queued and delivered by the first of: the `review` call that is waiting, the turn-end hook, the next tool call's
  answer. The panel says which ("delivered when its turn ends").

**As A6 built it** (`Review.swift`, `SessionPanel.swift`, `Merge.swift`):

- The panel shares the right slot with the old feed (⌥⌘A, the ✦ button): with a session chosen it is that
  session's panel, and "All agents" gives the feed of every agent's calls, with pause and recording, back
  ("Session" returns). **Window > Review This Session** is ⇧⌘'. Going to a session that waits for a review opens
  it, when the right side is free.
- Its first card says where the session stands (Ready for review with the agent's summary, Approved or Changes
  requested and whether the agent has been told, else its group's line) over the loop's six marks, with **Approve**
  and **Request Changes**. Request Changes sends what is written in the comment box with it, and asks for a
  comment when there is none. An approval is for the commit the session is at; more commits and the buttons are
  back. "Mark as reviewed" stays on the card, and takes a waiting request back without an answer.
- **Merge** is not gated on Approve (decision 6 puts it beside): it is offered whenever the session's branch has
  an open pull request at the session's own commit that is not a draft and has no conflicts, and it asks first,
  saying what is not right (checks failed or running on GitHub, a reviewer's changes, no approval here for this
  commit, criteria failed or unchecked, uncommitted changes). The commit is passed to `gh` so it merges nothing
  else. A session with no pull request shows no Merge; offering to ask the agent for one is not built.
- **Spec**: the criteria with a tick, a cross or nothing, when, and "on an older build"; a criterion checked while
  the session was recorded has a play button for that second, once the recording is finished (a recording still
  being written cannot be played). The agent's own judgement of a criterion is kept as such in the check's line.
- **Tell the agent**: comments with whether and how each was given; one not yet given can be taken back. **Pin to
  Screen** makes the next click on the session's device pick a node (the Inspector need not be open): the comment
  then carries the node's label, its frame, the screen's name and a picture of that part of the screen with the
  node outlined.
- **Last calls**: the session's last twelve calls. The comments are in their own card, not interleaved.
- **The loop strip** shows over the stage when the chosen simulator is the chosen session's: the six steps with
  their line of detail and a button (Review, or Session) that opens the panel. Its steps do not open their own
  detail yet.

**As A7 built it.** Take Over is in the loop strip, which is over the device, not in a line under it: the strip
reads "Codex is driving" while calls arrive, with **Take Over** beside it, and "You have the device" with **Hand
Back** after. It is also in the Window menu and ⌘K. It is the old pause for one session: that session's actions
are refused (builds included, so nothing reloads the device under the person's hands), reading and `spec`,
`review`, `feedback` still answer, every other session goes on, and the session is filed under Needs you until the
device is handed back. An agent that was refused is told when it is. The device's ring and pointer are as before.
Which session a call belongs to is the session of the simulator it acts on, else the caller's, so another agent
cannot drive a device the person took. It is kept in memory: after a restart every device is the agents' again.
Calls no longer queue behind each other across agents: a lane per simulator, per launch target and per agent
(`AgentServer.laneKey`).

**As A8 built it** (`CIWatch.swift`). A session on a branch whose head is what its upstream has is asked about
without being asked: `gh run list --commit`, every 30 s while a run goes, every minute for half an hour while
none shows, never again once the runs are over. A run going makes the session Working ("CI run 4812 · 3 min", also
the strip's Build step); a failed one marks the Build step failed. When they pass, the `ci` recipe fetches the APK
with `GREENROOM_CI_DISPATCH=0`, but only for a repository known to build its APKs on CI (default recipe `ci`, an
artifact or workflow set, or a CI build fetched before), a clean worktree, and a commit the session has no build
of: most repositories' runs are linters and tests, and a failed fetch for each push would be noise. The agent is
told how it ended with its next call's answer or its turn's end; a `build` call with the `ci` recipe still waits
for the run itself, as before. MCP Tasks are not used. The switch is Settings > Agents > Watch CI for pushed
sessions, on by default.

Changes, Screen Map, Jobs, Log, Network and the Device drawer are where they are.

## What agents get

Four additions; everything else is the existing tool list.

| Tool | |
| --- | --- |
| `spec` | declares what the session is for: `title`, `text`, `criteria` (a list of short sentences), and optionally a link to an issue or pull request. Calling it again replaces it. Shown in the session panel |
| `check` | takes `criterion` (its number or text): a `PASS` ticks it and a `FAIL` marks it failed, with the moment in the recording |
| `review` | says the agent is done: `summary`. Moves the session to Ready and waits, as `build` does (200 s, then "still waiting"; calling again joins). Answers `approved`, or `changes requested:` with the person's comments and, for a pinned one, the node and a picture of it |
| `feedback` | the person's comments not yet delivered, for an agent that did not call `review` |

Every tool answer also ends with what the person said when comments are waiting, so an agent in a harness with
no hooks still hears. (As built: the comments themselves ride on the answer, not a line asking for `feedback`,
which saves the call. `check` also takes `passed` and `note` for a criterion texts cannot show, kept as the
agent's word; and `review` may wait up to 1800 s.)

The skill's loop becomes: `spec`, `build`, `changes`, `launch`, drive and `check` each criterion, `review`. An
agent that calls none of the new tools still works as today; its session shows its calls and checks without
criteria, and goes to Ready when its turn ends, if a hook says so.

**CI.** An agent that pushes and calls `build` with the `ci` recipe waits for the run, as now. New: a session
whose commit is pushed and has a run is watched without being asked; the strip shows the run; when the artifact
lands the session's simulator reloads, and a waiting `build` call (or a Task, or the next turn-end hook) tells
the agent. An agent still never starts a workflow.

## Feature gaps

What the loop needs that Greenroom does not have, largest effect first.

| # | Gap | Why it matters | Size |
| --- | --- | --- | --- |
| 1 | Onboarding and empty stage are built around dropping a file; Connect is Claude Code only and lives in Settings | the first screen teaches the old product | M |
| 2 | A call from a repository not added is refused | the agent cannot bring the work; the person has to prepare each repository by hand | S |
| 3 | No way to connect any harness but Claude Code in a click | "any agent" is a doc page today | M: one connector per harness, each with a stand-in check |
| 4 | No hooks: status is scraped from two harnesses' private files; `onTurnEnd` is declared and never fires | status for every other harness is blank; the scrape can break on any release | M |
| 5 | No `review`, no verdict, nothing from person to agent but pause | the loop has no end and no way to steer | M |
| 6 | No `spec`; checks are not tied to criteria | "verified" cannot be shown against what was asked | S |
| 7 | Sidebar is grouped by repository with no order by attention; no notification, no Dock badge, no "next ready" key | with many sessions, finding the one that finished is a search | M |
| 8 | The Agent popover is one feed for all; there is no per-session panel or loop strip | the person cannot see where a session is | M |
| 9 | Pause is global; no Take over for one session | taking the device from one agent stops them all | S |
| 10 | CI builds arrive only when asked for | "compiles via CI" needs someone to press Build | S |
| 11 | No `greenroom` CLI on the PATH, no skill outside the Claude Code plugin, no `greenroom://` link | hooks have nothing to call; harnesses with weak MCP have no way in | M |
| 12 | Calls run one at a time across all agents | five agents verifying at once queue behind each other's `launch` and `wait_for` | M: a queue per simulator |
| 13 | Words: Settings > Claude Code, `ClaudeSession`, "Open in Claude", "Show my Claude Code sessions" | rule 2 | S, but wide |
| 14 | README, AGENTS-INTERFACE.md, the plugin's skill and the Homebrew cask's description say "drop an APK" | the outside matches the old product | S |
| 15 | A pull request can be opened, fetched and compared, not merged | the review ends in another app | S: `gh pr merge` through the code that already runs `gh` |

Not gaps, already there and reused as they are: a session per worktree with its own simulator and data, builds
from local, CI, remote and a linked APK, the walk and Changes against a base, the recording with a chapter per
call, sign-in scripts the agent can run without seeing a password, the job queue, pull request rows.

## Order of work

Each step ends in a build that can be installed, and each has its own `--…-check`.

| | Step | Closes |
| --- | --- | --- |
| A1 | A repository adds itself on an agent's first call; the empty stage becomes "Waiting for an agent"; the APK screen behind File > Run an APK… | 2, part of 1 |
| A2 | The Connect screen: detection, a connector per harness (Claude Code, Codex, Cursor first), first-run steps 1 and 2, the sample-app prompt (`launch` with `apk: "sample"`); the Debug copy kept to this repository | 1, 3 |
| A3 | `greenroom` CLI (`mcp`, `hook`, `open`, and the driving tools), the skill in each harness's folder, `greenroom://` | 11 |
| A4 | Hooks in for Claude Code, Codex and Cursor; one status model for every harness; `onTurnEnd` wired; renames | 4, 13 |
| A5 | Sidebar by attention, top-bar counts, notification, Dock badge, next-ready key | 7 |
| A6 | `spec`, `check` with a criterion, `review`, `feedback`; the session panel and the loop strip; comments pinned to a node; Merge | 5, 6, 8, 15 |
| A7 | Take over per session; a call queue per simulator | 9, 12 |
| A8 | CI runs watched for pushed sessions | 10 |
| A9 | README, docs, plugin, cask, PRIVACY.md | 14 |

A1 and A2 are the redesign of onboarding and can ship alone. A3 adds ways in and changes no screen but the
Connect screen's rows. A6 is the reason to keep the window open.

## Decisions (the owner's, 2026-11-27)

1. **Greenroom does not start agents.** It receives sessions from wherever the person runs them. No ACP, no
   app-server; "New session…" only copies a prompt.
2. **A repository is added without asking** on an agent's first call, said in the window, with Undo.
3. **Running an APK by hand has a screen of its own, reached from the Mac menu bar** (File > Run an APK…). No
   other screen offers a drop target.
4. **The sidebar is grouped by attention**, with the repository on each card and the old grouping one click away.
5. **A session becomes Ready without `review`** when its turn ended, its build is current and at least one
   `check` ran. Otherwise it goes Quiet.
6. **Approve answers the agent; Merge is beside it.** A session's pull request can be merged from Greenroom, by
   the person only.
