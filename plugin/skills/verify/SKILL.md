---
name: verify
description: Verify a change to an Android app in Greenroom's simulators - build this worktree, see which screens differ from the base, drive the app and check the result. Use after changing an Android app's code or resources when the greenroom tools are available, or when asked to run, try, screenshot, compare or verify the app or an APK.
argument-hint: "[what to verify]"
---

# Verifying a change with Greenroom

Greenroom runs Android APKs in simulators on this Mac, and the person at the Mac sees the same simulators in its
window. Its tools are this plugin's `greenroom` server (`session`, `build`, `changes`, `launch`, `tap`, `type`,
`check`, `screenshot`, `compare` and more). Use them instead of adb, an emulator or Gradle's install tasks.

What to verify: $ARGUMENTS

If that is empty, verify the change this worktree makes: read the diff, decide which screens it touches, and check
those.

## The loop

Work from the worktree you are changing. Each worktree of a repository the person added to Greenroom is a
session, with its own build, simulator and app data.

1. **`session`**: the branch, whether its build is `current` or `stale`, the default recipe and the base. It only
   reads.
2. **`build`**: runs the recipe and waits. It answers `built <key> ...`, or the last error lines of the build log:
   fix those and call it again. Skip it only when `session` says the build is `current`.
3. **`changes`**: the new build against the base, screen by screen. `+ Name (new) [s4]` and `- Name (gone) [s9]` are
   screens the change added or removed; `~ Name: 4,812 px differ [s3]` is a screen that looks different.
   `screenshot` with `screen: "s3"` and `side: "diff"` (or `head`, `base`) shows where. Screens you did not mean to
   change are the finding.
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

## What you cannot do, and what to do instead

- **Paused.** The person can pause the agent in Greenroom. While paused every action is refused (`build`,
  `changes`, `launch`, `tap`, `type`...); only reading works (`session`, `screen`, `screenshot`, `logs`). Do not
  retry: tell the person that Greenroom's Agent button (✦) has the switch, and wait.
- **`remote` builds need the person's consent.** The `remote` recipe uploads source code to the person's own
  account, so it runs only after they allowed it for that repository in Greenroom. You cannot give that yes: if
  `build` says so, ask them to allow it in the app, or use another recipe.
- **`ci`** fetches what CI already built for the commit and never starts a workflow. With no run, it says so.
- **`changes` never builds the base.** For a base nothing has built it says what would build it; pass `base` as
  `session:BRANCH`, `pr:NUMBER`, a branch, tag or commit, or the full path of an `.apk`.
- **Not a session.** `this folder is not a worktree of a repository added to Greenroom` means the person has not
  added this repository (Sessions, in Greenroom's sidebar). `session`, `build` and `changes` need that; without it,
  `launch` with the full path of an `apk` and the driving tools still work.
- `build` and `changes` wait at most 200 s per call, then say they are still going: call again, which joins the same
  run.
- Sign-ins are the person's: never ask for or type passwords.
- While you drive a session's simulator its screen is recorded on this Mac, for the person to review.

If the tools are missing or the server failed to start, Greenroom.app is not installed where the plugin looks
(`/Applications`, `~/Applications`, Spotlight): say so instead of falling back to an emulator silently.
