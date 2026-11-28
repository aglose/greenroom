---
name: verify
description: Verify a change to an Android app in Greenroom's simulators - build this worktree, see which screens differ from the base, drive the app and check the result. Use after changing an Android app's code or resources when the greenroom tools are available, or when asked to run, try, screenshot, compare or verify the app or an APK.
argument-hint: "[what to verify]"
---

# Verifying a change with Greenroom

Greenroom runs Android APKs in simulators on this Mac, and the person at the Mac sees the same simulators in its
window. Its tools are this plugin's `greenroom` server (`session`, `build`, `changes`, `history`, `launch`, `tap`, `type`,
`check`, `screenshot`, `compare` and more). Use them instead of adb, an emulator or Gradle's install tasks.

What to verify: $ARGUMENTS

If that is empty, verify the change this worktree makes: read the diff, decide which screens it touches, and check
those.

## The loop

Work from the worktree you are changing. Each worktree of a repository in Greenroom is a session, with its own
build, simulator and app data. Your first call from a worktree with an Android app in it adds its repository; the
person sees that and can undo it.

1. **`session`**: the branch, whether its build is `current` or `stale`, the default recipe and the base. It only
   reads.
2. **`build`**: runs the recipe and waits. It answers `built <key> ...`, or the last error lines of the build log:
   fix those and call it again. Skip it only when `session` says the build is `current`.
3. **`changes`**: the new build against the base, screen by screen. `+ Name (new) [s4]` and `- Name (gone) [s9]` are
   screens the change added or removed; `~ Name: 4,812 px differ, 1 route added, 2 texts changed [s3]` is a screen that
   differs, with why after the colon, and `> Name: "Open Home" now leads to Inbox` is a control that was redirected.
   When both builds have a stored map the first line says `changes from history` and nothing was walked.
   `screenshot` with `screen: "s3"` and `side: "diff"` (or `head`, `base`) shows where. Screens you did not mean to
   change are the finding. A `not finished: ...` line means the walk of the app stopped early, and
   `? Name (not reached: ...)` is a screen it did not get to: the other lines stand, calling again gives the same
   answer, so cover the screens you care about yourself in steps 4 to 6. **`history`** lists the maps stored for earlier
   commits (what changed at each) and, with `screen`, one screen's lineage; `screenshot` with `screen` and `commit` shows
   a stored picture.
4. **`launch`** with no `apk`: the session's simulator, on its newest build, with its data kept.
5. **`tap`** and **`type`** to reach the screens the change touched.
6. **`check`**: texts that must be on screen (`visible`) and must not (`absent`), answered `PASS` or
   `FAIL | ... | not on screen: "Saved"`. This is the verdict; do not judge by eye what `check` can assert.
7. **`screenshot`**: only for what text does not show (pictures, layout, colours), or as evidence at the end.

Report what you checked and what each `check` answered. A `FAIL`, a crash in `changes` or an unexpected `~` line
is a result to report or fix, not to explain away.

## Reading the answers

- **Screens are text.** `launch` and `screen` answer one line per node: `e7 "Sign in" click`, `e9 "Email" field`.
  A reference (`e7`) stays the same node while it is on screen. Tap by `ref` or by `text`.
- **Every action answers with what changed**, once the app has gone quiet: `~ e3 "0" -> "1"` (changed),
  `+ e12 "Saved" click` (new), `- e5 "Loading"` (gone). Read that instead of calling `screen` again. Only text is
  compared: when an action changes colours or pictures alone, the answer says the text did not change.
- **`wait_for`** waits for a text to appear or go. Never sleep.
- **`logs`** gives the app's log lines since the last call: look there after a crash.
- With several simulators running, each tool takes `sim` (`s1`, `s2`...).

## A/B against another build

`changes` compares whole builds. To compare one flow, `launch` the other APK as well (it starts beside the
session's simulator), do the same steps on each with `sim`, then **`compare`**: `-` is only on the base, `+` only on
the other, `>` moved, with the share of pixels that differ. `s1 vs s2: SAME` means the change did nothing visible on
that screen. `set` changes appearance, locale, font scale, rotation and more on either.

## Debugging what you see

When something looks wrong, look before you guess:

- **`network`** lists the app's requests (`failed: true` for failures); `network` with `id` shows one exchange's
  headers and bodies. **`network_rule`** mocks, fails, patches or slows a request to reproduce a server problem.
- **`perf`** answers frame rate, frame times, memory and CPU; **`accessibility`** audits the screen; **`inspect`**
  gives one node's resource id, bounds and tap box.
- **`set`** also covers the Device pane: `clock`, `thermal`, `fold`, `keyboard`, `push`, `lowmemory` and more.
- **`devtools`** turns on adb or a debugger port, or records the app's traffic to a HAR and replays it. Each restarts
  the app with its data; the answer starts with the simulator's new id.
- **`recorder`** keeps the last while of a session; `save` it and **`replay`** it on another build to see whether the
  change altered behaviour. **`tests`** runs instrumentation tests; **`snapshots`** the owner's screenshot tests.
- **`sessions`**, **`jobs`**, **`workspace`** and **`app`** show (and change) what Greenroom is doing and how it is set up.

## From a shell

The same tools are the `greenroom` command, when it is on the PATH (`command -v greenroom`): `greenroom session`,
`greenroom build`, `greenroom launch app.apk`, `greenroom tap --text Add`, `greenroom check --visible Saved`.
`greenroom tools` lists them and `greenroom help TOOL` gives one tool's arguments. Run it from the worktree, or pass
`-C DIR`. An answer is printed as the tool gives it; a picture is saved and its path printed (`--out FILE` says
where). The exit status is 0, 1 when the tool failed or a `check` answered `FAIL`, 2 for a wrong argument and 3 when
Greenroom could not be reached. Prefer the tools themselves when you have them: the command is for scripts and for
a harness without them.

## What you cannot do, and what to do instead

- **Paused.** The person can pause the agent in Greenroom. While paused every action is refused (`build`,
  `changes`, `launch`, `tap`, `type`, `set`...); only reading works (`session`, `simulators`, `screen`, `check`,
  `wait_for`, `compare`, `screenshot`, `logs`, `network`, `perf`, `sessions`, and the other tools when they only list or answer a status). Do not retry an action: tell the person that Greenroom's Agent button (✦) has the switch, and wait.
- **`remote` builds need the person's consent.** The `remote` recipe uploads source code to the person's own
  account, so it runs only after they allowed it for that repository in Greenroom. You cannot give that yes: if
  `build` says so, ask them to allow it in the app, or use another recipe.
- **`ci`** fetches what CI already built for the commit and never starts a workflow. With no run, it says so.
- **`changes` never builds the base.** For a base nothing has built it says what would build it; pass `base` as
  `session:BRANCH`, `pr:NUMBER`, a branch, tag or commit, or the full path of an `.apk`.
- **Not a session.** `this folder is not a worktree of a repository added to Greenroom` comes with the reason in
  brackets: no Android app was found in this repository, the person removed it from Greenroom (only they can add it
  back: do not try `session_action add_repository`), or agents are paused. `session`, `build` and `changes` need a
  session; without one, `launch` with the full path of an `apk` and the driving tools still work.
- `build` and `changes` wait at most 200 s per call, then say they are still going: call again, which joins the same
  run.
- Sign-ins are the person's: never ask for or type passwords. If the app needs one, call `scripts`: a sign-in script the person allowed can be run with `run_script` (it types their stored credentials, which you never see); otherwise ask the person to sign in.
- While you drive a session's simulator its screen is recorded on this Mac, for the person to review.
- Some settings are the person's alone (telemetry, the pause switch, recording agents, sharing maps, custom recipes):
  `app` and `workspace` show them and refuse to change them. Ask the person instead.

If the tools are missing or the server failed to start, Greenroom.app is not installed where the plugin looks
(`/Applications`, `~/Applications`, Spotlight): say so instead of falling back to an emulator silently.
