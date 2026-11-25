# Walking only what changed: how I1 and I2 were built

Packages I1 and I2 of `docs/MAP-HISTORY-PLAN.md` ("Walking only what changed"). Code: `MapImpact.swift` (pure rules,
the git reading, the workspace's ledger), `History.swift` (`plan`, `filed`, the audit, `verifyPlan`, `verified`),
`MapStore.swift` (`importWalk`'s new fields, `writeSeed`), `CrawlRun.swift` (`Support`, the new options),
`Evidence.swift` (the plan before each walk, the row's words, the menu items). Check: `Greenroom --map-impact-check DIR [APK]`.

## Engine support

`crawl.py --help` is read once per crawler (`CrawlRun.support`). A seeded walk needs both `--seed`/`--only-file` and
`--record-deps`; `--record-deps` alone is passed whenever offered. apksim 0.58.0 and later offer them; with an
older engine (0.57.1 and before) nothing changes: no plan, no note, no extra option, no `greenroom-impact.json`.

## Comparing a walk with its seed (apksim 0.62.0)

When the crawler offers `--diff-seed` and `--diff-controls` (`Support.diffSeed`), every seeded walk but a
verification passes them: the engine keeps its instances parked on the screens it walks and compares them with the seed.

- **What a snapshot keeps for it.** `--diff-controls changed` carries a screen's transitions for the controls the seed
  already has and taps only the new ones. It needs each seed screen's `actions` and each edge's `kind` and `steps`, so
  `MapSnapshot.Screen.actions` and `Edge.kind`/`.steps` are kept (optional: an older snapshot has none, and its
  screens are walked with every control tried). `writeSeed` writes them back.
- **When `changed` is used.** Only off main, when no Kotlin or Java file changed and every named screen has its
  `actions`: a changed handler can change where an existing control leads, and the engine would not try it
  (aglose/apksim#632). Otherwise `all`.
- **Why each screen was walked** (`MapImpact`'s reasons, "strings.xml changed") is kept in `greenroom-impact.json` as
  `why`, by screen id.
- **Main is walked.** `MainBuilds.land` hands each build of main to Evidence under the trunk's path, with the
  repository's kept sign-in, so a pull request's walk has main's map to start from. The first is a full walk; later
  ones are seeded like any other. The every-tenth full walk of main is gone: a full walk is the first of a project, a
  settings change, a change `MapImpact` cannot place, or "Walk Everything Again".
- **A pull request row's head is fetched** into `refs/greenroom/pulls/N` (nothing is checked out), so its walk is
  filed in the history and compared with main's.
- **An engine update keeps the map.** A baseline walked by another engine no longer starts a full walk. The walk is
  seeded as usual (`WalkPlan.engineChanged`), and once it is filed its carried screens are verified
  (`verifyCarried(afterEngine:)`, `--max-actions 0`). A carried screen whose structure the new engine reads
  differently starts a full walk of that build, with the reason on the row; a capture that differs is kept as a miss
  and starts nothing (a screen reached with no control tried can look different for other reasons). Limits: captures
  carried from the old engine are compared with ones the new engine takes, so a rendering change in the engine can
  show as a visual change; and a verification that never ran (the app quit first) is not started again.
- **Measured** (`--map-impact-check DIR APK`, engine 0.62.0, its test app, one instance): full walk 144.9 s; one screen
  seeded 13.6 s; the same with `--diff-seed --diff-controls all` 13.8 s; with `changed` 2.2 s. All three gave the
  full walk's map.

## A branch against the base branch's map (the pull request diff)

Changes (⌘D, the row's "N changed") with the base branch chosen no longer needs a build of the merge base and never
walks the base: `ChangesRun.fromMain`.

1. **The map of the base branch** is `History.baseline` of the head's commit: the snapshot of its merge base, else of
   the nearest earlier commit of the base branch that has one (the header says how many commits before). It is looked
   for under the profiles the session's own walks can have (`Evidence.walkProfiles`: signed in or not).
2. **Held back until it is there.** With none, the sheet shows a card and compares nothing: "Walking main for the first
   time" with the count so far while main's walk is queued or running (the comparison starts by itself when it is
   filed), or what to do when it cannot start ("Keep main Built" off, walking off, the walk failed). Main's walk is the
   project's one full walk (`MainBuilds.land`).
3. **The head's map** is the session's own walk of that build, started if it has none: seeded from the base branch's
   map, so only the screens the branch's files reach are walked.
4. **The result** is `ChangeSet.fromHistory` of the two snapshots, with `walkedBecause` (the walk's reasons by screen)
   and `unplaced`.

A branch's build is not walked in full for a file that cannot be traced to screens (`MapImpact.decideLenient`): a
build file, app start, a source no screen recorded, a values line that names no resource. What can be traced is walked;
the rest is listed on the Summary tab under "Not traced to screens" and counted in the header, and "Walk Everything
Again" is the person's choice. Main's builds keep the strict rules. A baseline with other settings or no record of
dependencies is still a full walk.

The Screens tab groups its tiles (Added, Changed, Removed), and a screen's detail says how it is reached, why it was
walked again, and the texts and controls added or removed. A session row shows "N changed" against the base branch's
map once its walk is filed; a click opens the comparison.

A walk compared with its seed that fails in the engine is made once more without `--diff-seed` (aglose/apksim#639:
`shutil.SameFileError` when one seed screen is the base of two pairs; seen on 0.62.0 and 0.63.0 with the test app).

Checked end to end by `--changes-check DIR APK` (engine 0.63.0, its test app): with no map of main the comparison is
held and nothing is walked; with one (10 screens, 203 s), a branch that changes one Kotlin file walks the 3 screens that
file is on and the comparison names them, the reason and the text that changed. That walk took 348 s: the engine
failed at the end of its first attempt (the error above) and it was made again.

**In the whole app.** The comparison's map (the Changes sheet's Map tab, the Screen Map's timeline) opens folded to
the changed screens and what is one step from them. "N unchanged · show in the whole app" unfolds it: the base
branch's whole graph in its usual layout, where the screens that did not change step back (`MapSurface.spotlight`:
dimmed cards, dim tiles far away) and the view opens on the first place where screens changed instead of on the whole
map (`MapSurface.show(region:)`, never past 1x). Changed screens that stand within about three columns of each other
are one place (`MapSurface.regions`); with several, "Changes in N places · 1 of N ›" (R, Shift-R) goes round them,
and with one it brings the view back. A selection lights its own routes as before.

**Removed screens.** A walk compared with its seed says which carried screens the new build no longer leads to
(`compare` entries with status `gone`, apksim 0.63.0). `importWalk` leaves them and the transitions out of them out of
the snapshot, so the comparison with the base branch shows them as removed. Ones the engine calls `unknown` stay. A
walk made again without `--diff-seed` (the retry above) has no such list, and carries them.

Limits: a build with uncommitted changes has no place in the history, so it is compared as before (both builds
walked). A walk cut at a depth leaves its last screens with no record of what they depend on, and those are walked
again every time: the default is the whole app.

## Decisions the brief left open

- **Where the per-workspace state lives.** `Workspace` (Sessions.swift) is not this package's, so the full-walk
  patterns, the count of main walks and the misses are kept in `<state>/history/<repo>/impact.json` beside the
  workspace's snapshots (`MapImpact.Ledger`). A pattern ending in `/` is a directory; anything else is an `fnmatch` glob.
- **`carriedFrom` needs the seed.** crawl.json says only `"origin": "carried"`; the commit comes from the snapshot the
  walk was seeded from (`importWalk(..., seed:)`; `map-snapshot.py --seed-snapshot FILE`; `--map-import --seed-snapshot`).
  The seed entry's own `carriedFrom` wins (a screen carried twice keeps where it was really walked); without a seed it
  is `"unknown"`. A carried screen the engine wrote without `deps` keeps the seed entry's.
- **`"replaces"`** is not stored: the snapshot has no field for it, and the pairing already follows a screen whose id
  changed. Verification counts a carried id that does not come back as "its structure changed".
- **Renames** are read as a delete and an add (`--no-renames`), so both paths are judged.
- **Unknown files walk everything.** Ignored: docs (`*.md`, `*.txt`, `*.rst`, `*.adoc`, README/LICENSE/CHANGELOG...,
  `docs/`, `doc/`), tests (`src/test*`, `src/androidTest*`, `src/sharedTest`), CI and editor files (`.github/`,
  `.gitlab-ci.yml`, `.circleci/`, `Jenkinsfile`, `.idea/`, `*.iml`, `.gitignore`, `lint.xml`, `fastlane/`,
  `.greenroom/`...). Anything else that is not a Kotlin/Java source or a resource (jniLibs, `src/main/resources`, a
  `google-services.json`) is `.full("a changed file Greenroom cannot place (path)")`. `buildSrc/`, `build-logic/` and
  `gradle/` count as build files.
- **A changed resource no recorded screen uses selects nothing** (unlike an unmapped source file, which walks
  everything as the brief says): a new resource reaches the app only through code or another resource that does
  change, and those are judged on their own.
- **Values files.** Every added or removed line must name what it changes: `<string name=..>`, `<color>`, `<dimen>`,
  `<style>`, `<plurals>`, `<string-array>`/`<integer-array>`/`<array>` (as `array/`), `<declare-styleable>` (as
  `styleable/`), `<item type="id" name=..>`. A style's or array's `<item name=..>` has no name of its own on the line
  (its name is an attribute's), so it walks everything, as does the middle of a multi-line string; this is also the
  plan's "a theme or a style" rule. The XML header, `<resources>`, `</resources>`, blank lines and one-line comments
  are skipped. Names are compared with dots as underscores (`style/Theme.App` = `style/Theme_App`).
- **Screens with no deps** in an otherwise recorded baseline are always walked again ("no record of what it depends on").
- **Walking the same commit again** (its own snapshot is the baseline) is a full walk: a seeded walk of a commit
  against itself would redo nothing.
- **A main-branch walk** is a walk of a commit that is an ancestor of the workspace's base ref (`git merge-base
  --is-ancestor`). They are no longer counted: see "Comparing a walk with its seed".
- **A full walk replaces a quick snapshot of the same commit** (it is the more truthful of the two) after being
  compared with it. Before I2, the first snapshot of a commit was never replaced; that still holds for full snapshots.
- **Comparing with an earlier quick walk.** With no quick snapshot of its own commit, a full walk is compared with the
  nearest earlier snapshot only when that one is quick. A difference that the commits in between explain (`MapImpact`
  from the quick walk to the full one selects that screen) is not a miss; when those commits would walk everything,
  nothing is compared. A screen missing from a full walk that was cut short is not a miss.
- **What a miss records**: the screen, why ("its structure changed", "its capture changed" (both settled), "its text
  changed", "its routes changed"), the quick walk's commit, the commit it was carried from, and the files between
  those two that are not ignored. Each such file's directory becomes a pattern.
- **Verify carried screens** has no cheap mode in the engine, so it is a walk seeded from the map with `--max-actions
  0` over the carried ids, as the brief allowed; the row says "verified 209 carried screens: all as carried" or names
  the misses. Only the structure (the id) and the captures are compared. It uses the session's data when its walks do,
  so its profile, and so its snapshot, are the same. Its misses are kept and shown but add no full-walk pattern: on
  the engine's test app, screens whose text depends on what the full walk did before them ("background: job ran")
  look different when reached with no control tried, so a verification miss is a lead, not proof.
- **Seeded walks' unfinished lines.** The engine writes what the seed left unfinished as `seed: --max-depth ...`;
  the import drops the `seed: ` prefix (it is the same fact for the new walk), so a seeded walk is not taken as cut short.
- **Classes vary between walks** (a lambda of an earlier screen can still run); the rules read only sources and
  resources, which matched exactly between a full and a seeded walk of the test app.
- **Status words.** The row's label is "walked 3 of 212 screens" for a quick walk (as before for a full one); its
  detail says "Walked 3 of 212 screens (12 files changed); the other 209 were carried from the walk of 1a2b3c4." or
  "Full walk: build files changed." and, after an audit, "1 screen changed that the last quick walk did not redo; its
  folder now always gets a full walk." The note is kept as `greenroom-impact.json` in the map's folder.
- **`--events`** is detected but not used yet: the human lines still drive the row.

## Tested against what

The rules, the git reading, the seed's round trip, the audit, the plan and verification are checked headless, with a
stand-in `crawl.py` (written by the check) for the live steps. With `GREENROOM_ENGINE` set to an engine whose crawler
offers `--seed` and `--record-deps` and an APK, `--map-impact-check DIR APK` runs the live steps on it: on apksim
0.58.0-crawldeps and its test app, a full walk with deps took 200.8 s (10 screens, 7 with deps, 14 start sources), a
seeded walk naming one screen 13.9 s, with the same result apart from origin and one recorded class. Evidence's own
seeded walk (plan, seed, import, row) is wired but has not run end to end inside the app.
