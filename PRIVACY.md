# Privacy

## The promise

**Your APKs never leave your Mac, and nothing about them is collected.**

An APK you open is read, translated and run on your Mac by the bundled engine. Greenroom does not send, to us or to
anyone, an APK or anything derived from one: its file name or path, package name, classes, resources, screens,
recordings, logs, or the network traffic it makes. The one exception is yours to make: a repository's screen maps,
pushed to that repository's own git remote when you turn on "Share screen maps through git" (below).

## What Greenroom itself sends

One thing, and only after you say yes: **an update check.** On its second launch Greenroom asks whether to check for
updates automatically; until you agree (or choose Greenroom > Check for Updates…) it sends nothing. A check is one
HTTPS request to GitHub for the list of Greenroom versions (`appcast.xml` on the project's releases page). It carries
no identifier and no description of your Mac (Sparkle's system profile is off and cannot be turned on); its user agent
names Greenroom's and Sparkle's versions. GitHub (which redirects it to its download host) sees what any download
would: your IP address, and which Greenroom version asked. An update it downloads is installed only if it is
signed with the project's update key, or by the same developer as the copy you have (Sparkle accepts either). Settings > Updates turns the
checks off.

**Crash reports and usage statistics, if you turn them on.** Both are off until you choose: Greenroom asks once,
shortly after its first launch, and closing the question leaves them off. Settings > Privacy turns each on or off and
shows, word for word, every report waiting to be sent. A report holds only:

- Greenroom's version and build, the engine's version, macOS's version and the day (no time of day, no identifier of
  your Mac or of you);
- a crash report: the signal and the addresses in Greenroom's own code where it crashed (no system or app frames,
  no memory);
- an engine report: the exit status of a simulator's engine when it ends abnormally (a native crash, for instance:
  that may be the engine's or a library of the app's, and the number does not say which; never when the Android app
  itself throws, and never its log or stack, which would name the app's code);
- usage: a count per day of how often each Greenroom feature was used (opened the network pane, took a screenshot),
  from a fixed list of Greenroom's features.

Never anything from an APK: its file name or path, package name, classes, resources, screens, recordings, logs or
traffic cannot enter a report, because a report has no field that could hold them. A report waits a day on your Mac
(in `~/Library/Application Support/Greenroom/reports`, 50 at most) before it is sent, so you can read or discard it
first. Reports are sent with no cookies and no stored credentials over HTTPS to
`https://greenroom-reports-426613790001.us-central1.run.app/report` (the service in `backend/reports/`, hosted on
Google Cloud Run in `us-central1`). The receiver rejects any unexpected field or feature name, does not store your IP
address or request headers (an in-memory, salted hash is used only for short-term rate limiting), and writes only the
validated report fields into BigQuery in `us-central1`, where rows expire automatically after 365 days. Debug builds
(`Greenroom Debug`) omit this address and never send reports.

The engine's one download (a test app it trains its startup cache with) ships inside the app instead.

Network traffic you will see otherwise comes from the Android app you are running, which reaches the network as it
would on a phone.

## Agents

If you connect a coding agent ([docs/AGENTS-INTERFACE.md](docs/AGENTS-INTERFACE.md)), it reads the screens and logs
of the apps you run and acts on them, on this Mac, through a connection only programs running as you can open (a
token in a file only you can read; web pages are refused). What the agent's own provider receives is between you
and that agent; Greenroom sends it nothing by itself.

While an agent drives a session's simulator, Greenroom records that screen to a video and a list of the agent's
calls (`agent-*.mp4` and `steps.jsonl`), kept on this Mac under that build's evidence until the build is pruned.
The list holds only the shape of each call: the tool, how many characters were typed, a link without its query,
the name of a setting without its value, the length of a text tapped or awaited; not the text itself. The video is
the screen, so it shows what was on screen. Nothing is sent anywhere. It can be turned off for each repository in
the Agent popover, which ends a running recording at once; a paused agent is not recorded. "Connect Claude Code"
(Settings) runs `claude mcp add` with your own `claude` program, which changes Claude Code's own list of servers on
this Mac and nothing else.

## Repositories an agent brings

When an agent you connected calls Greenroom from a folder, Greenroom runs `git` in that folder (read-only) to find
its repository, as it always has. New: if the folder is a worktree with an Android app in it and its repository is
not in Sessions, Greenroom adds it, says so in the window and offers Undo. Adding looks through the repository's
folders for Gradle build files and built APKs, on this Mac, and nothing else: a repository an agent added does not
fetch its base branch, ask GitHub for a build or run a recipe until the agent or you ask for a build, or you turn
"Keep main built" on for it. A repository you removed from Sessions is not added again by an agent, and none is added
while agents are paused. The list of removed repositories is a file in the state folder (`sessions/removed.json`,
folder paths only).

## Build recipes

If you add a git repository (Sessions) and build it, Greenroom runs a **recipe**: a program that makes an APK, told
what to build through environment variables. The recipes that come with Greenroom are readable files in the app
(`Resources/recipes`), and you can choose any program of your own. A recipe runs *your* tools with *your*
credentials: `git` and Gradle for `local`, the GitHub CLI (`gh`) with your own sign-in for `ci`. Those tools talk to
the network as themselves, when you press Build, add a pull request or choose a recipe, and only then. Greenroom
makes no connection of its own for it, and shares your sign-ins with no one: it never sees them (`gh` keeps its own).
The **remote** recipe is the one that sends something away: it uploads this repository's source code (the committed
files, your uncommitted changes and the untracked files `.gitignore` does not ignore) to your own boat.dev account,
with the `boat` tool and your own sign-in. Untracked files named like secrets (`*.jks`, `*.keystore`, `*.p12`,
`.env*`, `keystore.properties`, `local.properties`, `google-services.json`, `*.pem`, `id_rsa*`) and nested
repositories are not sent and the build log says which; a secret in an untracked file with an ordinary name is. The
sandbox is stopped when a build ends normally or is cancelled, and at the next launch if the app was killed; the
source stays in the stopped sandbox until you delete it on boat.dev. Greenroom says all this in a sheet before the
first run and needs your yes for each repository; no run happens without it. The APK comes back; none is uploaded.

The **ci** recipe starts a GitHub Actions workflow (`gh workflow run`) only when you press Build on a session with a
workflow set in its settings, never when Greenroom looks for a base or a pull request's build.

Adding a pull request runs `gh` for that pull request's head commit and its CI artifact; the APK it fetches is
opened on this Mac like any other. What a build leaves comes back to this Mac; no APK is uploaded.

This file changes in the same commit as any change to what the app sends.

## Claude Code's sessions

If you turn on "Show my Claude Code sessions" in Settings (it is off until you do), Greenroom reads, on this Mac and
only reads, Claude Code's own session files: `~/.claude/sessions`, the Claude app's `claude-code-sessions` folder, and
the transcripts in `~/.claude/projects` touched in the last 30 days. A long transcript is read at its start and its
last 32 KB only; a small one (64 KB or less) is read whole, into memory, and not kept. It checks whether the process
named in a session file still exists (a signal-0 probe and its start time, nothing more). For a session whose folder
is not in a repository you added, it runs `git` in that folder (read-only) to find the repository, and the
repository's folder name is shown in the sidebar so you can add it. Titles and names are shown in the window and go
nowhere: not into crash reports, engine reports or usage counts. With the switch off, none of those folders is
opened and no process is probed.

## T3 Code's threads

If you turn on "Show my T3 Code threads" in Settings (it is off until you do), Greenroom runs your own `t3` command
(found on your login shell's PATH, or in `~/.t3/bin`, `~/.local/bin` or `~/bin`, where T3 Code installs it): `t3 thread list
--project <folder> --json` for each repository you added to Sessions, and `t3 thread show <id> --json` for threads
updated in the last 30 days, every 20 seconds while Greenroom is the app in front. `t3` asks the T3 Code server
running on this Mac, as it does when you type it; Greenroom opens none of T3 Code's files. "Open in T3 Code" on a
row runs `t3 app <folder>`. Thread titles, statuses and pull request links are shown in the window and go nowhere
else. With the switch off, `t3` is never run.

## Sharing screen maps through git

Each walk of a clean commit leaves a screen map on this Mac: the screens it reached, their captures (pictures of the
app's screens), their texts and routes. If you turn on "Share Screen Maps Through Git" for a repository (the session
row's menu; it is off until you do), Greenroom stores each walk's map in that repository under `refs/greenroom/maps`
and pushes it to `origin`, so teammates see a pull request's map without walking it. **Captures of the app's screens
are uploaded to your git remote**, with `git` and your own credentials for it, as a push of yours would be; whoever
can read that remote can read them. Greenroom also fetches `refs/greenroom/maps/*` from `origin` (at most every ten
minutes per repository, and before a walk looks for the map to compare with) and keeps the maps it finds on this Mac.
Nothing goes anywhere but that repository's `origin`; no branch, tag or file of yours is touched, and pushes are never
forced.

A map walked on your signed-in data ("Walk with My Signed-In Data") can show your account. It is written in the
repository on this Mac but not pushed, unless you also turn on "Also Share Maps Walked on Signed-In Data".

With sharing off, no ref is written, nothing is fetched or pushed, and maps make no connection at all. A failure to
push or fetch is said in the row's detail and never stops a walk.

## What stays on your Mac

`~/Library/Application Support/Greenroom`, readable only by your user: the engine's caches, the data of the apps you
ran (as a phone would keep it, one copy per device kind), your scripts, and logs. The recent-APKs list is in the
app's preferences. Deleting that folder removes all of it.

Variables you add in Settings (sign-ins for your scripts) are in your login Keychain, under
`<bundle id>.variables`, never in a file of Greenroom's; which scripts agents may run is there too, under
`<bundle id>.scripts`. Keychain Access shows and deletes them. Their values go only into the environment of the
scripts and build recipes you run on this Mac; secret ones are replaced by `••••` in the output Greenroom shows.

A variable can instead name a 1Password item's field (`op://Vault/Item/field`). Greenroom keeps only that reference
and, when a script starts, asks the 1Password CLI on this Mac (`op read`) for the value. 1Password asks you to approve,
and the value goes only into that script's environment, masked like any secret. Greenroom keeps no 1Password token,
password or account, and build recipes never get these values.

## Checking this yourself

Greenroom and its engine are open source. The engine is started from `Sources/Greenroom/Engine.swift`; the app's
only request of its own is the update check, in `Sources/Greenroom/Updates.swift`. You can watch the app's
connections with any network monitor: with no APK running and no update check under way there are none.

CI checks it on every change: `scripts/network-check.sh` captures every packet leaving the Mac, tagged with the
process that sent it (or asked for the DNS lookup), while the app launches the engine, trains its startup cache,
streams a simulator, serves an agent and shows every pane, with updates not yet agreed to, and fails if one came from
Greenroom or its engine. You can run it yourself (`sudo -v && scripts/network-check.sh`). It starts from an empty
state folder, so no repository is added and map sharing is off, as it is for everyone until turned on; the git it
would start for sharing counts as Greenroom's if it ever ran.

`scripts/reports-check.sh` shows every kind of report and checks what it holds.
