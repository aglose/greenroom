# mapgen: a generated Compose app for screen maps at scale

`mapgen.py` writes a real Jetpack Compose application with as many screens as you ask for, and optionally builds it.
It exists to test map history (walks, pairing, diffs, the map, the export) on an app far larger and more varied than
the engine's test app, with a second build whose differences are known exactly.

```bash
testapps/mapgen/mapgen.py --out /tmp/mapgen-a --seed 7 --screens 300 --sections 5 --build
testapps/mapgen/mapgen.py --out /tmp/mapgen-b --seed 7 --screens 300 --sections 5 --build --version 2 \
  --mutate restyle=4,retext=4,restructure=3,relink=3,add=3,remove=3 --mutation-seed 11
```

| Option | |
| --- | --- |
| `--seed N` | everything else comes from it: the same arguments give the same sources, byte for byte |
| `--screens N` | screens in all, section roots included (default 150) |
| `--sections N` | bottom-bar sections, 1 to 5 (default 4) |
| `--depth N`, `--fanout N` | deepest screen below a section root (5), most children of one screen (4) |
| `--list-items MIN-MAX` | rows of a list screen (20-80) |
| `--images N` | distinct generated pictures (24) |
| `--links F` | share of screens with a button to a screen elsewhere (0.15) |
| `--animated N` | screens with an endless animation, which a walk cannot settle (0) |
| `--keep-section-state` | a tab reopens its section where it was left, as many apps do. Off by default: then a tab always opens the section's root, so where it leads does not depend on what a walk visited before (with it on, two walks of one build disagree on most screens' routes) |
| `--mutate KIND=N,...` | a second build: `restyle` (pixels), `retext` (words), `restructure` (blocks of controls), `relink` (a button's target), `add`, `remove` (a leaf screen) |
| `--mutation-seed N` | which screens the mutations pick |
| `--package ID`, `--version N` | application id (`dev.greenroom.mapgen`) and versionCode |
| `--build` | `./gradlew assembleDebug` and copy the APK to `OUT/app.apk` (JDK 17, Android SDK in `ANDROID_HOME` or `~/Library/Android/sdk`) |

The app is a bottom bar of sections, each a tree of screens reached by tapping (navigation-compose). Screens come in
twelve kinds, each with seeded variation: long lists with avatars, grids of pictures, forms (text fields, switch,
slider, radio buttons, checkbox), tabs, pagers of pictures, dashboards with cards, a bar chart and progress
indicators, settings lists, dialogs with an alert, a bottom sheet and a dropdown menu, rows of horizontal lists,
detail pages with chips, articles, and filter chips. A list row with no child screen opens a shared item page.
Every screen has a unique title in its top bar. No generated word is one the crawler skips (delete, share, send...).

`OUT/model.json` describes every screen (kind, title, parent, children, links). `OUT/mutations.json` lists what a
mutated build changed, with each screen's title and what a comparison should call it (added, removed, modified with
its reason). `score.py` checks a comparison against it:

```bash
Greenroom --map-walks /tmp/cmp WALK_A WALK_B > /tmp/cmp.txt
testapps/mapgen/score.py /tmp/mapgen-b/mutations.json /tmp/cmp.txt
```

`template/` holds the Gradle wrapper the generated project uses (Gradle 9.1.0, checked by its SHA-256). The versions
(AGP 9.0.1, Kotlin 2.3.20, Compose BOM 2026.03.01) are those of apksim's own Compose test app.
