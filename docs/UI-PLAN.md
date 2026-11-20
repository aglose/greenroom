# Greenroom's interface: plan

The interface is the product. The engine already does the hard part (an APK on screen in 0.3 s, 120 fps, every
device control a command); what a customer sees today is a functional window with a 12-item toolbar and three
animations in 3,700 lines. This plan is how it becomes something people want to keep open.

## What it should feel like

1. **The device is the hero.** Chrome is quiet and gets out of the way: a window that opens showing only the device
   on a calm stage; every panel is asked for, and remembered per project.
2. **Everything answers in the frame it was asked.** A click, a drop or a shortcut shows a response within one
   display refresh, even when the engine's answer takes longer (a placeholder that the real thing lands in).
3. **Motion explains.** Every animation says where something came from, where it went or what changed. Nothing
   moves for decoration, nothing blocks input, and everything can be interrupted mid-flight.
4. **One place for each thing.** Device state lives in one drawer, not spread over menus and toolbar items.
5. **Native.** Standard sidebar, toolbar and inspector, so macOS 26 gives the system materials and macOS 14 still
   looks right; light and dark; Reduce Motion, Increase Contrast and VoiceOver honoured.

## Layout

```
┌──────────┬───────────────────────────────────────────┬─────────────┐
│ Library  │  toolbar: device ▾ · rotate · appearance   │  Controls   │
│  Apps    │           · capture ▾ · ⌘K search          │  (drawer)   │
│  Running │ ───────────────────────────────────────── │  Display    │
│  Records │                                           │  Environment│
│          │        the stage: one device, or many     │  Hardware   │
│          │        on a canvas, each in its frame     │  Network    │
│          │                                           │  App state  │
│          │ ───────────────────────────────────────── │─────────────│
│          │  bottom panel: Log · Network · Timeline   │  Inspector  │
└──────────┴───────────────────────────────────────────┴─────────────┘
```

- **Stage.** Devices sit on a neutral canvas with a soft shadow, drawn in a frame: the engine's skins where one
  exists, else a generic body with the device's corner radius. One device is centred at actual size or fit; several
  tile as today. A caption under each (app, device, a status dot) replaces the title strip. Double-click a device in
  a grid and it grows to fill the stage (focus), Escape puts it back.
- **Toolbar: six items.** Device picker, Rotate, Appearance, Capture (screenshot / record / save recording), the
  layout switch (single, grid, compare), and the search field that is the command palette. Everything else moves to
  the Controls drawer or the palette.
- **Controls drawer** (right, ⌥⌘0). Every device control the engine has, grouped, each a direct manipulation with
  the current value shown: Display (appearance, font scale slider, locale, time zone, clock, bars, fold slider,
  skin); Environment (location with presets, network profile, thermal, Bluetooth); Hardware (a tilt pad for the
  sensors, shake, biometrics match / no match, camera source); App state (permissions, deep link field, push,
  recreate, process death, memory warning, clipboard); Debug (layout bounds, accessibility audit, animation speed,
  frame-rate cap). In a grid a control applies to the selected device, or to all with Mirror on.
- **Inspector** shares the right side as a second tab: the node tree, the picked node's properties, bounds overlay.
- **Bottom panel** (tabs): Log, Network (requests live; conditions and rules later), Timeline (the recorder's ring,
  scrubbable). Slides up from the edge; height remembered.
- **Command palette** (⌘K): every command, app, device, recording and setting, fuzzy-matched, with the shortcut
  shown; the last few commands first. It is also the quickest way to teach the shortcuts.
- **Empty state.** No app open: a drop target that says so, the recent apps as cards with their icon (read from the
  APK), and "Open the sample app". First run shows the engine warming up as progress, once.
- **Agent presence.** While an agent drives, the device it is on has a thin accent ring and its actions show as a
  pointer that glides to each tap; the Agent feed is a bottom-panel tab with a pause button.

## Motion

All of it on the compositor (Core Animation layer transforms and opacity; never layout per frame), spring-based so
it is interruptible, at the display's rate. Three curves cover everything, defined once in `Design.swift`:

| Name | Use | Feel |
| --- | --- | --- |
| `snap` | hovers, presses, selection, chips | ~150 ms, critically damped |
| `move` | panels, re-tiling, focus, rotation | spring, ~300 ms settle, slight overshoot off for large surfaces |
| `arrive` | things appearing or leaving | 220 ms in (scale 0.96 → 1, fade), 160 ms out |

| Moment | What moves |
| --- | --- |
| Drop an APK | The stage shows a drop outline under the pointer; on drop a device frame grows from the drop point (`arrive`), its screen a soft pulsing placeholder with the app's icon; the first real frame cross-fades in (120 ms). |
| Open a second device | Existing devices glide to their new places (`move`) as the new one arrives: positions are animated between layouts, never jumped. |
| Close | The device shrinks and fades toward its sidebar row; the others close the gap. |
| Focus / unfocus | The chosen device scales up from its cell to the stage; the rest fade back and blur slightly. |
| Rotate | The frame turns 90° with `move` while the old picture is held; the new orientation's first frame cross-fades in at the end. |
| Device or fold change | The frame morphs between sizes (bounds and corner radius animated); a fold uses the hinge slider, the picture following live. |
| Appearance | A quick cross-fade of the picture between the last light frame and the first dark one, so the switch reads as one change. |
| Touch | A ring at each touch-down that expands and fades (exists); mirrored devices show it too, slightly dimmer. |
| Agent action | A pointer glides to the target, presses (ring), and a small label names the action for a second. |
| Compare | Differing regions outline, pulse twice, then stay; a slider wipes between A and B; counts tick up in the bar. |
| Panels | Drawer, inspector and bottom panel slide with `move`; the stage re-fits during the slide, not after. |
| Recording | The Capture item turns into a red dot with a timer; the device's caption gets the same dot. |
| Something failed | The device's caption shakes once and shows the engine's one-line reason; nothing modal. |
| Palette | Drops from the toolbar (`arrive`); results reflow with `snap`. |

Rules: no animation delays input (the engine gets the command at once, the animation runs beside it); a second
command during an animation retargets it; with Reduce Motion every `move` and `arrive` becomes a 120 ms cross-fade;
video frames keep arriving through every animation (the frame layer is a sublayer of what moves).

## How it is built

- **Stage and devices stay AppKit and Core Animation** (`SimulatorView`, `SimulatorGrid`): the frame layer, bezels,
  overlays and all of the motion above are layers. The grid becomes a layout engine that returns frames, and one
  place animates between two layouts.
- **Forms are SwiftUI** hosted in the split view: the Controls drawer, Settings, the palette's list, the empty
  state. They are lists of bound controls, which SwiftUI does in a tenth of the code.
- **`Design.swift`**: the only place colours, spacing (4-pt grid), radii, type sizes and the three motion curves are
  defined. No literal in a view.
- **`DeviceState`**: one observable model per simulator (appearance, locale, font scale, rotation, network...),
  read from the engine's `config` and written through commands, so the drawer, the palette, the menus and the agent
  tools all show the same truth.
- `Workbench.swift` (836 lines) is split along those lines first; no behaviour change in that step.

## Order of work

Each step ends in a build you can open.

| Step | What you get | Size |
| --- | --- | --- |
| U0. Design pass | Static mock-ups of the window (single, grid, compare, drawer open, empty state, dark and light) to agree the look before code | 1 day |
| U1. Foundations | `Design.swift`, the Workbench split, the layout engine with animated re-tiling, six-item toolbar | 2 days |
| U2. The stage | Device frames and shadows, placeholder-to-first-frame, open / close / focus / rotate / device-change motion, empty state with app cards | 3 days |
| U3. Controls drawer | `DeviceState` and every device control, grouped; tilt pad; location presets | 3 days |
| U4. Palette | ⌘K over commands, apps, devices, recordings | 1-2 days |
| U5. Bottom panel | Log restyled, Network tab (live requests), Agent feed with the gliding pointer and pause | 3 days |
| U6. Compare, redone | Wipe slider, pulsing regions, counts; grid status chips | 2 days |
| U7. Polish | Reduce Motion, VoiceOver labels, contrast, keyboard-only pass, idle at 0% CPU, window in under 0.4 s | 2 days |

## How it is checked

- Still pictures: `--visual-check` captures of each state, light and dark, compared by eye and kept as references.
- Motion: an off-screen render of each animation as a strip of frames (as the engine does for the fold), so a
  change in timing or a jump shows up in a picture; and the owner's eye at the end of each step, which is the real
  test: a build is installed after every step.
- Budgets in the scripted checks: frames keep arriving during every animation; nothing animates while idle; the
  window's first paint and an APK drop to first frame are timed.
