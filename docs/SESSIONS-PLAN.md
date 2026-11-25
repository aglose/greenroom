# Sessions: worktrees, builds and what changed

A plan (2026-11-20). W0 (the model and store, git, the sidebar section, switching, data slots, warm simulators,
reload on a new build) is built, and so are the builds, evidence, Claude link and pull request rows. **W4 (Changes) is
built** (`Changes.swift`, `ChangesSheet.swift`, `ChangesCheck.swift`, `--changes-check`): the sheet with Summary,
Screens, Map, Video (the tour) and Live, export as Markdown and the report, ⌘D. Left over: the offer's remote
build is not wired (it only checks the commit out as a worktree), the cache key of a pair ignores a start link and
base options (only the check uses them), and posting to a pull request.

## Goal

Someone working with a coding agent has several changes in flight, each in its own git worktree, often each with
its own Claude Code session. Greenroom should let them move between those changes in one click and see, for each,
**what the change did to the app**: the build running in a simulator, pictures and video of the screens it
changed, the screen map with the differences marked, all against another branch, pull request or APK.

Five parts, each useful without the next:

1. **Sessions**: a sidebar section with a row per worktree; a click switches to its simulator.
2. **Builds**: each row can be built on this Mac, fetched from CI, or built on a remote machine.
3. **Evidence**: every new build is walked and captured by itself: screenshots, a screen map, video.
4. **Changes**: a build against a base (branch, PR, APK): screens new, changed and gone, the map, video, live.
5. **The agent's side**: an agent connected over MCP is tied to its worktree, and can build, check and read the
   changes itself.

## What exists and what does not

| Have (reuse) | Where | Missing |
| --- | --- | --- |
| A sidebar with Running and Recent rows | `Workbench.sidebarController`, `Row` | Any knowledge of git: worktrees, branches, commits, PRs |
| Reload a simulator when its APK is rebuilt | `BuildWatcher`, `DevHooks.built/relaunch` | One folder only, matched by file name; nothing starts a build |
| Screen map: walk, graph, routes, "go there" | `CrawlRun`, `ScreenMap`, `MapCanvas` | The engine's `crawl.py --base` (new/changed/gone, difference images) is not wired; the map shows one run |
| Two live simulators compared (nodes, pixels) | `Comparison`, `Workbench.compare(with:)` | No stored comparison of two builds |
| Review grid: golden / actual / difference, wipe | `SnapshotReview` | Needs a hand-written spec; nothing captured per build automatically |
| Recordings, replay on a build, first build that differs | `RecordingsPane`, `ReplayRunner`, `Bisect` | Builds ordered by file time, not by commit |
| The H.264 stream of every simulator | `FrameChannel`, `VideoDecoder` | No video file is ever written from it |
| MCP server, stdio shim, activity feed | `AgentServer`, `AgentShim`, `AgentPanel` | The shim passes no working folder; one feed for all agents |
| Matrix wall, memory figure, settings window | `MatrixWall`, `Memory`, `SettingsWindow` | |

Simulators of one package share the engine's default data slots today (`--data-slots` is never passed), so two
branches of one app would share sign-ins and databases.

## The model

```swift
struct Workspace: Codable {          // a repository the person added
    var root: URL                    // the main checkout
    var module: String?              // Gradle application module (":app"); found if nil
    var variant: String              // "debug"
    var baseRef: String              // "origin/main": what a change is compared with by default
    var recipes: [String: Recipe]    // "local", "ci", "remote": see Builds
    var auto: Auto                   // what happens by itself: see Evidence
}
struct Session {                     // one row: a worktree of a workspace
    let worktree: URL
    var branch: String?, head: String, dirty: Bool, ahead: Int   // from git
    var claude: ClaudeSession?       // title, status, pull request: see "The Claude Code link"
    var build: Build?                // the newest build of this worktree
    var simulator: Simulator?        // alive or not
}
struct Build: Codable {              // an APK and where it came from
    let key: String                  // first 16 hex of the file's SHA-256
    let apk: URL                     // builds/<key>/app.apk (an APFS clone: no extra disk)
    let source: Source               // local | ci | remote | file
    let sha: String?, ref: String?, dirty: Bool, date: Date
}
```

A base is always resolved to a `Build`, so everything downstream compares two builds and does not care whether
they came from a worktree, a PR or a file dropped on the window.

Stored under `~/Library/Application Support/Greenroom/` (0700, as the rest):

```
sessions/workspaces.json                 the workspaces and their settings
builds/<key>/{build.json,app.apk,build.log}
evidence/<key>/map/                      crawl.py's output: crawl.json, screens/<id>/<combination>.png
evidence/<key>/video/                    agent-<time>.mp4 with steps.jsonl, manual recordings
changes/<head key>-<base key>/           crawl.py --base output, diff/, tour-head.mp4, tour-base.mp4
```

Pruned: the last 3 builds per session, base builds unused for 14 days, everything of a worktree that is gone,
under a size cap in Settings (default 5 GB), oldest first.

## 1. Sessions

- **Adding**: File > Add Repository..., dropping a folder on the sidebar, or (with the Claude Code link on) one
  click on "3 Claude sessions in a repository you have not added". `git worktree list --porcelain` gives the rows;
  an FSEvents stream on the repository's `.git/worktrees` and each worktree's `HEAD` keeps them current.
- **A row**: title (the Claude session's, else the branch), branch and short commit, a status dot, the build's age
  and source, and a badge when the build is older than the worktree's sources ("stale") or there is none.
- **A click** selects the session's simulator, starting it from its newest build if it is not alive. Each session
  launches with `--data-slots gr<8 hex of the worktree path>`, so its app data is its own and survives rebuilds
  and restarts; "Copy data from..." clones another session's slot (sign in once, branch from there).
- **Staying warm**: the last 3 sessions' simulators stay alive (a setting; the memory figure from `Memory` shown
  beside it), the least recently used quits beyond that. Switching between warm ones is a selection, nothing more.
- **Keyboard**: ⌘1-9 for the first nine, ⌥⌘Tab for the last used, all rows in the ⌘K palette. Command keys are never
  sent to the device, so the keys the app under test may use (⌃1, ⌃Tab...) stay its own.
- **A new build** of a session reloads its simulator in place (`DevHooks.relaunch`: same options, same data),
  whether or not it is the selected one. One FSEvents stream watches every session's outputs folder.
  This is one call site (the watcher's callback), where hot swap's swap -> recreate -> relaunch ladder plugs in when
  phase 6 lands; a resource-only change always relaunches.

## 2. Builds

A build is made by a **recipe**: an executable run with the person's own tools and credentials, told what to
build through its environment, which leaves an APK where it is told to.

```
GREENROOM_WORKTREE  GREENROOM_REPO  GREENROOM_REF  GREENROOM_SHA  GREENROOM_DIRTY (0|1)
GREENROOM_MODULE    GREENROOM_VARIANT              GREENROOM_OUT (write the APK here)
exit 0 with the file there: built. Anything else: failed. stdout and stderr are the build log.
```

Three ship in `Resources/recipes/`, readable and copyable; "Custom..." takes any executable (another CI, another
remote builder).

| Recipe | What it runs | Builds | Notes |
| --- | --- | --- | --- |
| `local` | `./gradlew :MODULE:assembleVARIANT` in the worktree, then copies the newest APK of the outputs folder | the worktree as it is, uncommitted changes included | Needs the JDK and Android SDK the person builds with anyway. One at a time per workspace (Gradle's daemon and caches). |
| `ci` | `gh run list --commit SHA`, `gh run watch`, `gh run download -n ARTIFACT`; with no run and a `workflow_dispatch` workflow named in the settings, `gh workflow run --ref BRANCH` first | pushed commits only | The row says so when the worktree is ahead: "CI has a1b2c3d, 2 commits behind". Costs nothing extra when CI builds every push. The artifact's name and the APK's pattern inside it are settings. |
| `remote` | a boat.dev sandbox: resume (or fork from a template snapshot), upload the tree (`git archive HEAD` plus the uncommitted diff and untracked files, by `boat scp`), `boat exec --detach` the Gradle task, poll, `boat scp` the APK back, stop the sandbox | the worktree as it is | boat.dev is a general sandbox service, not a build service: the template (JDK 17+, the Android SDK) is prepared once by a "Prepare remote builder" step and kept as a snapshot. The sandbox is stopped, not deleted, between builds, so Gradle's caches make the next one incremental. Auth is the `boat` CLI's own key. |

- **The Build button** on a row runs the workspace's default recipe; its menu has the others. Progress and the log
  are in the row's detail; a failure keeps the last good build running and shows the log's last error.
- **Resolving a base** (`origin/main`, a branch, a PR): the cached build for that commit, else `ci` for it, else
  an existing worktree already at that commit with a fresh APK, else an offer to build it (`remote`, or `local` in
  a scratch worktree under the state folder). A PR number resolves through `gh pr view N --json headRefOid`.
- **Pull requests without a worktree** can be rows too ("Review" section): the PR's CI build, run and compared
  without checking anything out.

## 3. Evidence

What Greenroom captures for a build by itself, in the background, on hidden simulators:

1. **The walk**: `crawl.py APK --out evidence/<key>/map` (default depth 2, 120 s, light appearance, 2 instances):
   the screen map, and a capture of every screen it reached. With a base set, the same run is
   `crawl.py APK --base BASE_APK --out changes/<head>-<base>`, which also walks the base and pairs the screens.
   Cached by build key (and base key): switching back to a session shows its evidence at once.
2. **The change tour** (after a walk with a base): for each new or changed screen (12 at most), both builds are
   taken there by the map's own route (`ScreenMapData` steps, as "Go there" replays them), held for 1.5 s, and
   recorded: `tour-head.mp4`, `tour-base.mp4`, chapters per screen. Played side by side.
3. **The agent's session**: while an agent drives a session's simulator, the stream is recorded
   (`evidence/<key>/video/agent-<time>.mp4`) with a `steps.jsonl` of its tool calls as chapter marks, and the
   flight recorder is on, so the same run can be saved as a `.apkrec` and replayed on another build.
4. **By hand**: File > Record Screen (⌃⌘R: ⌘R is Rotate) and Save Screen, filed under the session's build.

Video comes from the H.264 stream the app already receives: a `Recorder` writes the samples into an MP4
(`AVAssetWriter`, passthrough, no second encode), so recording costs nothing in the engine and works headless.
If local display moves to shared IOSurfaces (PLAN.md phase 0, S1), the stream stays on, or is started, whenever
something records, or the Recorder encodes from the surfaces itself.

- **When** (`Workspace.auto`): `off`, `onBuild` (default: every new build is walked), `onTurnEnd` (when the
  session's Claude turn ends and the sources are newer than the build: build, then walk). A walk is cancelled when
  a newer build of the same session arrives; one walk runs at a time.
- **Sign-ins**: by default a walk is fresh: no session's data is used, so nothing taps through the person's real
  session on every build. A workspace can opt in ("Walk with my signed-in data", off by default): the walk then runs
  on a clone of the session's data slot (`--keep-data` on the clone, which the crawler walks on several simulators, each
  on its own clone, and never with a base), so it starts where the person is signed in and changes nothing of theirs; the row's detail
  says which it was. The crawler's skip list (delete, pay, send, sign out...) applies as always. The captures of
  screens (which may show signed-in content) stay under `evidence/` until the store prunes them with their build.
- **Limits said in the UI**: a walk reaches what tapping reaches within its budget; a screen behind typed input
  or a server state is not found. "Add a start" (a deep link) and a saved recording replayed on each build
  (`apksim replay`, already in `ReplayRunner`) cover what the walk cannot.

## 4. Changes

A full-stage sheet (as Screenshot Tests and the Screen Map are), opened from a row or ⌘D.

- **Header**: `fix-login a1b2c3d (local, 2 min ago)  against  main 9f8e7d6 (CI)`, and the base picker: the
  workspace's base branch, another session, a pull request, a branch or commit, an APK file.
- **Summary**: 2 new, 3 changed, 1 gone, 14 the same; crashes found on either side; what the walk did not finish.
- **Screens**: the review grid's tiles (`SnapshotTileItem`) for every changed, new and gone screen: base, head and
  difference side by side or under the wipe slider; "Go there" opens the screen on the live simulator.
- **Map**: the map of the head build with new screens and routes in green, changed in amber, gone in red (drawn
  from the base's map); selecting a node shows its tile.
- **Video**: the change tour, both builds playing in step, a chapter per screen.
- **Live**: both builds side by side with mirrored input (`Workbench.compare(with:)`), for what only hands find.
- **Export**: the engine's `report.html` for the pair (one file), and "Copy summary" as Markdown for a PR
  description. Posting to a PR is a later step and always asked.

Later, from the same two builds: network calls and frame timings that differ (PLAN.md, phase 4).

## 5. The Claude Code link

No account sign-in is involved: everything is on this Mac. Settings > Claude Code has two switches.

**"Show my Claude Code sessions"** (off until chosen). Greenroom then reads, and only reads:

| File | Gives |
| --- | --- |
| `~/.claude/sessions/<pid>.json` | live sessions: folder, name, idle or busy, the desktop app's session id |
| `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json` | the desktop app's sessions: title, worktree and repository, archived, pull requests, last activity |
| `~/.claude/projects/<folder>/*.jsonl` (first and last lines only) | folder, branch, title, PR link for sessions not running |

A session is joined to a row by its folder. These are Claude Code's own files, not an interface it promises:
every field is optional to the reader, an unreadable file is skipped, and a version whose files no longer parse
turns the rows back into plain worktree rows with one line saying so. Checked against fixture files, never real
ones. The status dot: working, idle, waiting for you. "Open in Claude" brings the session up in Claude (the
`claude://` link format is a spike; until then it activates the app).

**"Connect Claude Code"** runs `claude mcp add --scope user greenroom -- "<this app>" --mcp` (shown before it
runs) and says when it is already connected.

**What the agent gets** (protocol additions, all optional to older clients):

- The shim sends its working folder and its parent's process id with each request (`X-Greenroom-Cwd`,
  `X-Greenroom-Parent`); the parent is the Claude Code process, whose id names its session file. The server ties
  the connection to a `Session`; the activity feed and the recordings are per session.
- `launch` with no `apk` starts the session's newest build, in the session's own simulator and data.
- `session`: the worktree, branch, build (age, source, stale or not), base.
- `build`: run a recipe and wait; answers the build's key or the log's last error lines.
- `changes`: the comparison with the base as text (`+ Settings > Privacy (new)`, `~ Trips: 4,812 px differ`,
  `- Legacy import (gone)`), walking first if needed; `screenshot` takes a screen id for the pictures.

So an agent's "verify your change" is three calls, and what it did is on file for the person to watch.

## Privacy

PRIVACY.md changes in the same commit as each of these:

- **Claude Code's files** are read on this Mac when the switch is on; titles are shown in the window and go
  nowhere, not into reports or usage counts.
- **Recipes run the person's own tools.** `git`, `gradle`, `gh` and `boat` talk to the network as themselves,
  with their own credentials, when the person runs a recipe or turns on an automatic one. Greenroom still makes
  no connection of its own, and no recipe runs for a workspace that has not chosen it.
- **The remote recipe uploads source code** to the person's own sandbox account. Its setup sheet says so in
  those words before the first run. APKs come back; none is uploaded.
- `scripts/network-check.sh` gains a pass with a workspace added and the Claude Code switch on, no recipe run:
  still no packet.

## The engine

Nothing is needed from apksim for the first version: `crawl.py --base`, `--data-slots`, `--keep-data`, `replay`
and the stream are in 0.57.1. Worth adding there later, as general options:

- `crawl.py --base-run DIR`: pair against a walk already made of the base, so a base is walked once, not once
  per comparison.
- A walk that reports each finished screen as a line of JSON, so the map fills in live with its difference state.

## Workstreams

Each is one pull request from its own worktree, with a check (`Greenroom --<name>-check`) run against a
temporary git repository with two worktrees, the bundled test app as their "builds", fixture Claude files, and
stand-in `gh` and `boat` programs on `PATH`. W0 lands first and sets the shapes above; after it W1, W2a, W3a and
W5a touch files of their own and run side by side. `Workbench.swift` is the file everyone would otherwise edit:
W0 adds a `SessionsController` that owns the sidebar section, and later streams go through it.

| | Work | New files | Done when | Model |
| --- | --- | --- | --- | --- |
| W0 | Model and store, `Git` (worktrees, head, dirty, ahead, merge base through `/usr/bin/git`), the sidebar section, per-session data slots, switching, warm simulators, shortcuts | `Sessions.swift`, `SessionStore.swift`, `Git.swift`, `SessionsController.swift`, `SessionsCheck.swift` | two worktrees listed, a click switches, each keeps its own data across a rebuild | Sonnet, reviewed by the planning session |
| W1 | Claude Code discovery behind its switch, titles and status dots, "Open in Claude" | `ClaudeSessions.swift` | fixture files of three shapes join the right rows; a broken file changes nothing | Sonnet |
| W2a | Recipes, the `local` recipe, the Build button and log, one watcher for all sessions | `Builds.swift`, `Recipes.swift`, `Resources/recipes/local.sh` | a row builds, its simulator reloads, a failure keeps the old build | Sonnet |
| W2b | The `ci` recipe, base resolution, PR rows | `Resources/recipes/ci.sh` | a pushed commit's artifact arrives through a stand-in `gh`; "behind" is shown | Sonnet |
| W2c | The `remote` recipe and "Prepare remote builder" | `Resources/recipes/remote.sh` | passes against a stand-in `boat`; one real build with the owner's key | Sonnet, the real run with the owner |
| W3a | `Recorder`: the stream into an MP4, chapters, File > Record Screen | `Recorder.swift` | a 10 s recording plays in QuickTime at the stream's size and length | Sonnet |
| W3b | The evidence queue: walk per build, cache, cancel, prune, the cloned data slot | `Evidence.swift` | a new build has a map and captures a minute later with nobody asking | Sonnet |
| W4 | Changes: `--base` runs, `ScreenMapData` reading `compare`, the sheet (summary, screens, map colours, video, live), the tour, export | `Changes.swift`, `ChangesSheet.swift` | the test app against itself with one setting changed shows exactly that screen changed | Sonnet for the data, the planning session for the sheet's design pass |
| W5a | Shim headers, a connection tied to a session, per-session feed, `launch` without `apk` | (edits `AgentServer`, `AgentTools`, `AgentPanel`) | `scripts/mcp-check.py` run from a worktree lands in that row | Sonnet |
| W5b | `session`, `build`, `changes` tools, one-click connect, AGENTS-INTERFACE.md | | a real agent session verifies a change in three calls (docs/AGENT-SESSION.md) | Sonnet |
| D | PRIVACY.md and README wording inside each PR, palette entries, PLAN.md status rows, fixtures | | | Haiku |

Order of value: W0 + W1 + W5a (switching, with Claude's names on the rows) is the first thing to ship; W2a makes
it self-sufficient; W3 and W4 are the reason to keep it open.

## Spikes (an hour or two each, before the stream that needs them)

- SS1 (W1): the `claude://` link that opens a given session in the desktop app, if there is one.
- SS2 (W2b): `gh run download` on a repository whose workflow uploads a debug APK: artifact naming, time to fetch.
- SS3 (W2c): a boat.dev template with the Android SDK; first and second build times of a mid-sized app; whether
  `rsync` works over `boat ssh` (it would replace the archive upload); the 30 s exec default and detached polling.
- SS4 (W3b): `crawl.py --keep-data` on a clone of a slot: that the clone is what it uses and the original is
  untouched.
- SS5 (W0): three warm simulators of a large app: memory, and whether the least recently used should quit or drop
  to `--max-fps 1`.

## Open decisions

1. Automatic building: `onBuild` walks are cheap, but `onTurnEnd` starts a Gradle build after every agent turn.
   Proposed default: off, offered per workspace.
2. The default base: the merge base with `origin/main` (what the PR would show) or `origin/main`'s tip.
   Proposed: the merge base.
3. Posting evidence to a pull request (pictures need hosting): proposed as a later step.
