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
  ones are seeded like any other. The every-tenth full walk of main is gone: a full walk is the first of a project, an
  engine or settings change, a change `MapImpact` cannot place, or "Walk Everything Again".
- **A pull request row's head is fetched** into `refs/greenroom/pulls/N` (nothing is checked out), so its walk is
  filed in the history and compared with main's.
- **Measured** (`--map-impact-check DIR APK`, engine 0.62.0, its test app, one instance): full walk 144.9 s; one screen
  seeded 13.6 s; the same with `--diff-seed --diff-controls all` 13.8 s; with `changed` 2.2 s. All three gave the
  full walk's map.

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
