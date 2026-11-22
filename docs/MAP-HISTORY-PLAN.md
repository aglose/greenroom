# Map history: the screen map over time, and what a change did to it

Status (2026-11-22): every package of the table below is built and merged, each with its check, except what "Not
yet" lists. The engine half (E1, E2) shipped in apksim 0.58.0, which `engine.lock` names, so incremental walks are
live.

Not yet:

- The GitHub Action (`action/`) has never run on GitHub (spike MS6); only its script is checked.
- A real app with hundreds of screens. See "What the first real apps showed".

## What the first real apps showed (2026-11-22)

Two open-source apps from apksim's corpus list, walked with a local build of the engine before 0.58.0 was released; `Greenroom --map-walks` put the
walks through import, pairing, the diff and the export.

- **Markor** stops at its introduction: each page of the pager has the same structure, so "Next" reads as staying on
  the screen, and the walk ends with one screen. An app behind a paged introduction needs a start past it: a deep
  link, or a script as a sign-in uses.
- **Wikipedia** needs data taken past its onboarding (the last page's "Skip" is text the tree does not mark as
  clickable; and once onboarding is done a restart no longer shows it, so routes through it stop replaying). From
  there a walk reaches 10 screens and 42 transitions in about 130 s and meets 7 crashes, an `IllegalAccessError` in
  the engine's translated code, not the app's own fault.
- **The same build twice is the same map**: two walks, each on its own clone of the same data, gave the same 10
  screen ids and 42 edges, and the diff reported nothing added, removed or modified. Walking twice on one data slot
  without cloning it gave 5 ids in common of 11 and 15, because the first walk changes what the second starts from:
  the clone per walk that Evidence makes is what keeps a history comparable.
- **Most of its screens never settle** (7 of 10: a feed that keeps loading), so their pixels are not compared, and
  only 4 of 10 screens had a capture that replayed. On an app like this the map and its routes are trustworthy and
  the picture comparison says little.
- **A release build names no source files** (R8 strips them unless `-keepattributes SourceFile` is kept): the engine
  says so (`deps_unreliable`) and incremental walks fall back to full walks. They pay off on debug builds.
- Size was never tested by a real app: thousands of screens are covered by the generated maps only.

The screen map today is one walk of one build, kept in a folder that is pruned after five runs, and Changes walks
two builds side by side every time it is asked. This plan turns the map into a record: a snapshot of the app's
screens for every commit that matters, a clear difference between any two of them (a PR against main, one release
candidate against another), walks that only redo what a change could have touched, a canvas that stays fast and
readable at a thousand screens, and a way to hand the result to QA and designers.

## What exists, and what is missing

| Have (file) | Missing for this plan |
| --- | --- |
| The walk: `CrawlRun` runs the engine's `crawl.py`; `crawl.json` has screens, edges, routes, captures | Every walk starts from nothing; cost is about 1.3 s per transition, so a large app is many minutes |
| Changes: `crawl.py HEAD --base BASE` walks both builds and pairs them (`ChangeSet`, `MapMark`) | The base is walked again for every comparison; pairing replays routes on a running base build, so two stored walks cannot be compared |
| Cache by build: `evidence/<build key>/map`, `changes/<head>-<base>` (`Evidence`) | Keyed by APK hash, local to one Mac, pruned by size; no commit, no history, nothing shared |
| `MapCanvas`: a card per screen (about 8 layers each), a column per depth, 420 px thumbnails all loaded at once, zoom 0.3 to 2 | No culling, no levels of detail, no grouping or search; a few hundred screens is a wall, and zoomed in a capture is blurry |
| Screen identity: `Activity-HASH` of the structure (engine, `docs/crawl.md`) | A screen whose structure changes gets a new id; nothing follows one screen across commits |
| `affected.py` and the `-Dapksim.deps` probes: changed files to classes to tests (engine) | Not recorded per screen, not available to a walk; resources are not attributed at all |
| Export: a Markdown summary, the crawler's `report.html` | Nothing a designer can open that shows the map with the differences |

## The shape

```
walk (crawl.py) ──> crawl.json ──> MapSnapshot ──> history store ──> git refs (shared)
                                        │                │
                    changed files ──> impact            MapDiff(a, b) ──> canvas, export, agents
                                        │
                              next walk redoes only these
```

1. **Snapshot** (`MapSnapshot`): one commit's map in a fixed, sorted JSON form with its captures named by content
   hash. Made from any `crawl.json`. Carries the commit and its git tree hash, the walk profile, the engine version,
   what the walk did not finish, and per screen where its data came from (walked at this commit, or carried from an
   earlier one).
2. **Profile**: the walk's settings (depth, starts, capture matrix, sign-in script by name, offline), in
   `.greenroom/map.json` in the repository so the team walks the same way. Two snapshots are compared only when
   their profiles match; a different profile is a different history.
3. **Lineage**: a screen keeps one lineage id for as long as it can be paired with its predecessor, so "this screen
   over time" is a list of captures, and a structural change is a modification, not a removal and an addition.
4. **Diff** (`MapDiff`): a pure function of two snapshots. No simulator, no walk, milliseconds.
5. **Baseline**: for a branch or PR, the snapshot of its merge base with main; if that commit has none, the nearest
   ancestor on main that has one, and the header says how many commits behind it is. Main's snapshots come from
   three places, cheapest first: a PR's snapshot whose tree is the same as the merged commit's (no walk), the CI
   walk of main, and the evidence queue when a main build arrives on someone's Mac.
6. **Incremental walk**: the baseline snapshot seeds the walk; only screens the change could have touched are
   explored again.

## The diff

Pairing two stored snapshots, in order: the same screen id; else the same position in the graph (the paired
parent's same control leads to it); else the same route from a start; what is left on one side only is added or
removed. Pairing by position is what lets a restructured screen read as modified without replaying anything.

| Screen | Means | Shown |
| --- | --- | --- |
| added | no predecessor in the base | green |
| removed | in the base, no successor | red, drawn in the base's place |
| modified | paired, and something differs; reasons listed: `visual` (pixels, with the difference image and share), `structure` (the tree changed), `text` (visible strings added or removed), `routes` (a control added, removed, or leading somewhere else) | amber, with the reasons as small marks |
| same | paired, nothing differs | plain |
| not compared | never settles (an animation), flaky, or a walk on either side did not reach it | grey, never counted as changed |

Edges get the same treatment (added, removed, retargeted), and crashes are listed as new, fixed or still there.
Pixels are compared by content hash first (free), and only captures whose hashes differ are diffed
(`ScreenComparison.pixels`, already in `Comparison.swift`). The existing `ChangeStatus` and `MapMark` grow the
reasons; `ChangeSet` becomes a view over a `MapDiff`, so the Changes sheet, the tour and the `changes` agent tool
keep working and stop walking the base twice.

## The store, and git

Local, under the app's state folder, content-addressed so a capture that did not change is stored once:

```
history/<repo id>/snapshots/<profile>/<commit sha>.json
history/<repo id>/blobs/<sha256>.png          captures (APFS clones of the walk's files)
history/<repo id>/pyramid/<sha256>-<size>.jpg thumbnails for the canvas, made once, never shared
history/<repo id>/layout/<profile>.json       where each lineage sits on the canvas
```

Shared through git, without touching the working tree, the index or any branch:

- One ref per walked commit: `refs/greenroom/maps/<profile>/<commit sha>`, pointing at a commit whose tree is
  `map.json` and `screens/<lineage>/<combination>.png`. Written with plumbing (`hash-object -w`, `mktree`,
  `commit-tree`, `update-ref`).
- Git is already a content-addressed store: an unchanged capture is the same blob in every snapshot and costs
  nothing. A snapshot adds only what changed, so the history of a screen is the history of its blob.
- One ref per commit means two people walking different commits never conflict. A normal clone does not fetch
  these refs, so nobody's checkout grows; Greenroom fetches `refs/greenroom/maps/*` for the workspaces it shows.
- A ref is written once and never edited: it describes one commit, and a commit does not change. Nothing is part
  of a pull request, and there is nothing to keep in step with a branch.
- **The same tree is the same app.** A second ref, `refs/greenroom/maps/<profile>/tree/<tree hash>`, points at the
  same snapshot, and a commit with no ref of its own is looked up by its tree. A squash merge gives main a new
  commit whose tree is the PR head's (when the branch was up to date with main), so the snapshot made while the
  PR was reviewed is main's baseline the moment it merges, with no build and no walk. A branch merged while
  behind main has a tree nobody walked: that commit waits for the CI walk, or is compared from its nearest
  ancestor.
- **The CI walk keeps main current.** A GitHub Action on pushes to main skips a commit whose tree already has a
  snapshot, and otherwise builds the app, walks it in the engine's Linux image with the repository's profile and
  pushes the ref. The baseline then depends on nobody's Mac. It writes the same snapshot bytes as Greenroom
  does, from a script in this repository that the Action and a check share.
- Pushing is a choice per workspace, off until turned on, and a walk made on signed-in data is never pushed
  unless that workspace says so (its captures can show a person's account). PRIVACY.md says this in those words.
- Kept: main's snapshots, tags, open PR heads. Refs of merged or closed branches are deleted after 30 days.

Cost to say plainly: a capture is about 250 KB (822 x 1782 PNG). A 300-screen app in light and dark is about
150 MB for the first snapshot, then roughly 250 KB per changed capture per commit. Captures stay lossless PNG so a
pixel difference means something.

## Walking only what changed

Three levels, each safe to fall back from:

1. **Nothing to do**: the commit already has a snapshot (made here, or fetched), its tree is the same as a
   commit's that has one, or the APK is byte-identical to one that has. No walk.
2. **Impact-guided**: every screen in a snapshot records what it depends on: the app classes whose code ran while
   it was reached and shown (the engine's probes, read and reset per screen), and the resources it resolved. The
   changed files between the baseline's commit and this one map to classes (`affected.py`'s class to source map,
   Kotlin's inlined files included) and to resources; the screens that depend on any of them are *affected*.
   - Affected screens are reached by their stored routes and explored in full: structure, every control, captures.
   - A control on an affected screen that now leads somewhere unknown opens a normal breadth-first walk from there.
   - Every other screen is *carried* from the baseline, and its snapshot entry says from which commit.
   - Affected screens go first, so a walk cut short by its time budget has still covered the change.
3. **Full walk** whenever the change is something the record cannot see: the manifest, Gradle files, assets, the
   Application class, a theme or a style, a changed file that maps to no recorded class, a new engine version, a
   new profile. The header says "full walk: build files changed".

Keeping it honest: a full walk of main runs on a schedule (every tenth main build, or nightly). Its result is
compared with what incremental walks carried; a carried screen that turns out to differ is a *miss*, shown in
the header and logged with the files that caused it, and misses for a path pattern turn that pattern into a
full-walk trigger for the workspace. A "Verify carried screens" pass (reach each, compare structure and capture
hash, try no controls: one replay per screen instead of one per control) is offered for release candidates.

Engine work this needs (`aglose/apksim`, released, then `engine.lock` moves):

- `crawl.py --seed RUN --only ID,...`: start from a stored walk, re-explore only these screens, write the merged
  result with each screen marked walked or carried.
- `crawl.py --record-deps`: per screen, the classes that ran and the resources resolved, in `crawl.json`.
- Progress as a line of JSON per finished screen, so the canvas fills in as the walk goes.

The history and the diff need none of this: they work on today's `crawl.json`.

## The canvas at scale

Target: 2,000 screens and 10,000 edges open in under 300 ms from a cached layout, pan and zoom at 60 frames a
second, under 300 MB, and a capture sharp at any zoom.

- **Culling and pooling**: layers exist only for what is in view, taken from a pool. Edges are a handful of shape
  layers (one path per style: dim, focused, added, removed), not two layers per route.
- **Levels of detail** by zoom: a coloured dot per screen (status only); a small thumbnail; the card with title;
  the full capture. Thumbnails come from a pyramid on disk keyed by blob hash (96, 384 px), decoded off the main
  thread, held in a cache with a byte limit. Zoom goes to 8x, where the visible cards swap to the original PNG.
- **Layout** off the main thread, cached, and *stable*: a lineage keeps its place from one snapshot to the next,
  and a new screen is put beside its parent. Scrubbing through history or switching base and head never
  reshuffles the map.
- **Groups**: screens gather by section (the start or tab they hang from, then activity). A group collapses to one
  tile with its counts ("Settings: 41 screens, 2 changed"). Large maps open collapsed.
- **Changes first**: with a base chosen, the default view is what changed and its neighbours one step away; the
  rest folds into "184 unchanged". Filters: all, added, removed, modified, crashes, not reached.
- **Finding things**: search over titles, on-screen text and activity names; a minimap; the arrow keys as now.
- **Detail**: base, head and difference side by side or under the wipe slider (the Changes sheet's, reused); a
  filmstrip of the screen's lineage over time; "Go there" as now.
- **History**: a timeline strip across the top (main's snapshots, tags marked). Picking any two points sets base
  and head; a release candidate against another is two tags.

The Screen Map sheet becomes the one place for this: `[head] compared with [base]` in its header. The Changes
sheet's Map tab uses the same canvas.

## Sharing

1. Teammates with Greenroom: the git refs. Opening a PR row shows its map against main with no walk if anyone
   pushed that commit's snapshot.
2. Everyone else (QA, design): "Export" writes one folder with a single `index.html`: the map, zoomable, changes
   first, each changed screen with base, head and difference. No server, no Greenroom, opens from a link or a zip.
3. The Markdown summary gains the reasons ("~ Trips: visual 0.35%, 1 route added") for PR descriptions.
4. Agents: `changes` answers from the history when both snapshots exist; a `history` tool lists a screen's
   lineage.
5. The CI walk of main (The store, and git) ships with the git milestone, so the baseline is there for everyone.
   Walking every PR in CI too waits for incremental walks, which make it cheap; until then a PR is walked by
   whoever opens it in Greenroom, once, and pushed.

## Milestones

Each ships by itself and is useful alone.

| | Ships | Needs the engine |
| --- | --- | --- |
| M0 | The contract: `MapSnapshot` and `MapDiff` types, the JSON schema, fixtures, this document | no |
| M1 | History and diff: every walk files a snapshot; a PR's map is compared with main's stored baseline; the Changes sheet stops walking the base | no |
| M2 | The canvas at scale: culling, levels of detail, stable layout, groups, changes-first, search, deep zoom | no |
| M3 | Git: snapshots pushed and fetched, found by commit or by tree; the CI walk of main; the timeline; any two commits or tags compared | no (the Linux image and `crawl.py` as they are) |
| M4 | Incremental walks, with the miss report | yes (0.58 or later) |
| M5 | The HTML export, the richer summary, the agent tools | no |

M1 and M2 touch different files and run side by side. M4's engine work starts at the same time as M1 in the
engine's repository, since a release and a lock bump stand between it and Greenroom.

## Work packages

One pull request each, from its own worktree, with a check that needs no person and (except where said) no
simulator: `Greenroom --<name>-check DIR`, printing one `[greenroom] <name>: ok|FAIL` line per step, as
`MapCheck.swift` does. New code goes into new files; `ScreenMap.swift`, `ChangesSheet.swift` and `Evidence.swift`
are each edited by one package only.

| | Work | Files (new unless said) | Done when | Model |
| --- | --- | --- | --- | --- |
| P0 (done) | Types and schema for snapshot, diff, profile; `MapDiff.compare`, the difference of two snapshots whose screens carry lineages; a generator of synthetic maps (N screens, a seed, a mutation list: add, remove, restyle, retext, restructure, retarget) and five golden pairs with their expected difference | `MapSnapshot.swift`, `MapFixtures.swift`, this document | `--map-contract-check` passes: the fixtures round-trip byte for byte, each pair differs in exactly its mutations, and the bytes match the digests named in the check | the planning session |
| H1 | The store: import a `crawl.json` folder, blobs by hash, lookup by commit and profile, prune | `MapStore.swift`, `MapStoreCheck.swift` | importing one walk twice writes nothing the second time; two walks sharing 6 of 7 captures store 8 blobs | Sonnet |
| H2 | The pairing: give a head snapshot's screens their lineages from a base snapshot (id, then position, then route; a new lineage for what is left), then `MapDiff.compare` | `MapPairing.swift`, `MapPairingCheck.swift` | for every golden pair, the head with its lineages blanked is paired and compared to exactly the pair's expected difference, and the 2,000-screen pair takes under 100 ms | Opus, reviewed by the planning session |
| H3 | Wire it: Evidence files a snapshot per walk and walks main's builds; the baseline rule; `ChangeSet` reads a `MapDiff` | edits `Evidence.swift`, `Changes.swift`, `Bases.swift` | `--changes-check` passes unchanged, and a second comparison against the same base starts no walk | Sonnet |
| C1 | Layout: layers by depth, ordering, groups, stability from a previous layout; off the main thread | `MapLayout.swift`, `MapLayoutCheck.swift` | 2,000 screens laid out in under 200 ms; adding 20 screens moves no existing one | Sonnet |
| C2 | The renderer: culling, the layer pool, batched edges, levels of detail, the thumbnail pyramid, zoom to 8x | `MapSurface.swift`, `MapPyramid.swift`, `MapSurfaceCheck.swift` | the 2,000-screen fixture: under 300 layers alive at any zoom, a scripted pan and zoom with no frame over 16 ms | Opus, design pass by the planning session |
| C3 | Getting around: filters, changes-first, groups collapsing, search, minimap, keys | `MapNavigator.swift` | in a 500-screen fixture with 6 changes, opening shows those 6 and their neighbours; search finds a screen by its text | Sonnet |
| C4 | Detail and time: compare slider, lineage filmstrip, timeline strip, base and head pickers | `MapDetail.swift`, `MapTimeline.swift` | picking two snapshots redraws without moving unchanged cards | Sonnet |
| C5 | Adopt it: the Screen Map sheet and the Changes Map tab on the new surface; `MapCanvas.swift` goes | edits `ScreenMap.swift`, `ChangesSheet.swift`, `MapCheck.swift` | `--map-check` and `--changes-check` pass on the bundled test app (simulators) | Sonnet, screenshots reviewed by the planning session |
| G1 | Git refs: write a snapshot as a tree, read one with `cat-file`, lookup by commit then by tree, push, fetch, prune, the per-workspace switch | `MapGit.swift`, `MapGitCheck.swift` | two temporary clones of one bare repository: a snapshot pushed from one is read in the other, and no branch or working file changed in either; a squash-merged commit with the PR head's tree finds the PR's snapshot | Sonnet |
| G2 | The CI walk: a script that turns a `crawl.json` folder into a snapshot and its refs without Greenroom, and the Action that builds, walks in the engine's image and pushes on main, skipping a tree that has one | `scripts/map-snapshot.py`, `action/action.yml`, `scripts/map-snapshot-check.sh` | for a fixture walk the script's snapshot is byte for byte what `MapStore` writes; run twice on one tree, the second run walks nothing | Sonnet |
| E1 | (apksim) `--seed`, `--only`, JSON progress lines | `scripts/crawl.py`, `docs/crawl.md`, `crawl-check.py` | seeded with its own full walk and `--only` one screen, the result equals the full walk and took under a fifth of the time | Opus, in an apksim session |
| E2 | (apksim) `--record-deps`: classes and resources per screen | `scripts/crawl.py`, the runtime's probes | on the test app, changing one screen's Kotlin file selects that screen and its dialogs only | Opus, in an apksim session |
| I1 | Impact: changed files to affected screens, the full-walk triggers, the seeded walk, carried and walked marks | `MapImpact.swift`, `MapImpactCheck.swift`, edits `CrawlRun.swift` | a fixture repository with three commits: a one-file change walks 2 of 15 screens; a manifest change walks all | Sonnet |
| I2 | The scheduled full walk, the miss report, "Verify carried screens" | edits `Evidence.swift`, `MapImpact.swift` | a planted miss is reported and its path becomes a full-walk trigger | Sonnet |
| S1 | The HTML export | `MapExport.swift`, `Resources/map-export/` | the exported folder of a golden pair opens offline in a browser and shows each mutation | Sonnet, design pass by the planning session |
| S2 | Summary reasons, `changes` from history, the `history` tool, AGENTS-INTERFACE.md | edits `AgentSessionTools.swift`, `Changes.swift` | `scripts/mcp-check.py` gets a diff with no walk started | Sonnet |
| D | README, PRIVACY.md, palette entries, PLAN.md rows, inside each PR | | | Haiku |

Order: P0, then H1, H2, C1, C2, G1 and (in apksim) E1, E2 together; then H3, C3, C4, G2; then C5; then I1, I2;
then S1, S2. G2 follows H1 and G1 because it must write exactly what they write.

## How the agents stay cheap

- **The contract comes first and is small.** P0 fixes the types and the fixtures before anyone else starts. A
  package's brief is: its row of the table, the contract file, the two or three files it must read (with line
  ranges), and its check command. No agent is asked to understand the app.
- **Fixtures instead of walks.** A real walk is one to ten minutes of waiting and megabytes of output. Every
  package but C5, E1 and E2 runs against generated maps, so a loop of edit, build, check is seconds, and the
  check's answer is a dozen lines.
- **Files of their own.** Packages in one wave share no file, so they run in parallel worktrees and merge
  without anyone resolving conflicts. The three large existing files each have one owner.
- **Checks that answer in a line.** A package is done when its check prints PASS; the agent reports that line
  and the diff's size, not a narrative. Pictures are looked at only in C2, C5 and S1, by the planning session.
- **The model fits the work.** Opus where a wrong design is expensive (pairing, the renderer, the crawler);
  Sonnet for modules with a written contract; Haiku for wording. One fresh reviewer per pull request, given the
  diff and the contract, not the author's reasoning.
- **Spikes before streams.** Each unknown below is an hour of one agent with a yes or no answer, run before the
  package that depends on it, so no package discovers halfway that its premise was wrong.

## Spikes

- MS1 (before E2): reading and resetting the class probes per screen over the control channel during a walk, and
  what the probes cost in walk time.
- MS2 (before E2): whether the engine can name the resources a screen resolved (layouts, drawables, strings,
  colours). If not, a changed resource falls under "full walk" until it can.
- MS3 (before H2, I1): a real mid-sized app at two commits a week apart: screens, edges, walk time, how many ids
  survive, how many captures are byte-identical. This sets the pairing's priorities and says how much
  incremental walking is worth.
- MS4 (before C2): 2,000 synthetic cards with culled, pooled layers: does it hold 60 frames a second, or do the
  far zoom levels need to be drawn into tiles instead.
- MS5 (before G1): pushing and fetching `refs/greenroom/maps/*` on GitHub, the size of a 300-screen snapshot,
  and the time to write it through plumbing.
- MS6 (before G2): an Action pushing a ref outside `refs/heads` with the workflow's own token, and a walk of a
  real app in the engine's Linux image on a hosted runner: its time, and whether it fits the runner's memory.
  How often squash merges on the measured repository keep the PR head's tree (MS3's repository).

## Open decisions

1. Where the shared history lives. Proposed: hidden refs in the app's own repository (above). The alternative is
   a separate repository just for maps, which keeps the app's repository small on the server at the price of a
   second remote to set up.
2. Whether pushing snapshots is automatic once a workspace turns it on, or always a button. Proposed: automatic
   for fresh walks, a button for signed-in ones.
3. The baseline for a PR. Proposed: the merge base (what the PR itself changed), with main's tip as a choice.
4. Which real app MS3 measures.
5. The CI walk covers main (decided: it ships with M3). Open: whether it needs a signed-in start. A fresh walk
   sees only what is in front of the sign-in; a signed-in one needs a test account's secrets in the Action and a
   sign-in script that runs there. Proposed: fresh first, signed-in when a workspace supplies the script.
