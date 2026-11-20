# Greenroom (the Mac app): plan

A native Mac app, shipped as a signed and notarized DMG, that hosts many simulators in one workbench and is as
usable by an LLM agent as by a person. The app is **Greenroom**, in its own public repository
(https://github.com/aglose/greenroom), bundling a released apksim; "Apksim.app" below means it.

Status 2026-11-19: phase 0's S0 done; phase 1 begun in the app's repository (the app opens APKs in the bundled
engine's own window; `scripts/bundle.sh` embeds a pinned release, signs all 81 binaries with the hardened runtime
and smoke-tests it; state in a 700 folder; the training app bundled, so no first-run download). Also there: an icon, `scripts/dmg.sh` (a 339 MB image for engine 0.53.0, which mounts and runs the app read-only;
`--notarize` written, not run: the Mac has no Developer ID certificate yet), CI and a tag-driven release workflow.
Left in phase 1: the Developer ID certificate and notary secrets (the owner's, steps in the app's
docs/RELEASING.md), a first notarized release, Sparkle, first-run training shown in the app.
Later the same day, in the app's repository: the first notarized image (0.1.0: Developer ID, app and image
accepted and stapled); the workbench (phase 2's start: simulators inside the app's window on the H.264 stream,
input over the control channel, sidebar, device toolbar; Side by Side and Mirror Input); the agent interface
(phase 3: MCP served by the app behind a token, `Greenroom --mcp` as the stdio shim, 16 tools with stable
references and change reports; a scripted session passes locally and in CI; no real agent client has used it yet);
Compare (phase 4's start: node and pixel differences between simulators, marked in the window and as an agent
tool). The engine's control channel: apksim's pull request 552 refuses a web page's POST and adds `--control-token-file`;
the app uses a token per simulator when its engine has the option (the bundled 0.53.0 does not yet). Not started:
shared surfaces (S1), hot swap (S2), the inspector, the timeline, network and frame-timing differences, Sparkle.
Found on the way, in apksim: two launches started together (a first launch and the background training it starts)
race on `ln -sfn` of the class-path link in `$TMPDIR` and one dies with "File exists".

Items marked *(unverified)* come from
research that was not confirmed against a primary source or a test; each has a spike below.

## What the research found

**In the code (read, with line references, by a survey of this checkout):**
- Every instance is its own Cocoa app: `simwindow.m` (2,378 lines) runs `[NSApp run]` in the JVM, owns 3 BGRA
  IOSurfaces and sets one as a layer's contents per frame. Nothing shares a picture across processes today; `beam`
  and `serve` send H.264 over the control socket (`FrameStream`: 24-byte header, Annex B, SPS/PPS on keyframes).
- `--headless` is first class, and every input and device control already has a control-channel command, so a host
  app needs no new input path.
- The control channel is one line in, one line out, text only. No JSON form of `nodes`, `stats`, `windows`, `frames`;
  no general event stream (activity changed, crash, exit, log): clients poll.
- `scripts/mcp.py` (913 lines) is stdio only, 15 tools, and already answers each action with the node changes.
- Nothing is signed. No Info.plist, entitlements, icon or bundle exists; the Dock shows `java`.
- `elfloader.c` never asks for write+execute at once and uses no MAP_JIT: it writes, then `mprotect`s to
  read+execute (file-backed first, anonymous copy as fallback).

**Distribution:**
- Notarization needs every Mach-O (the jlink'ed JRE's too) signed with the hardened runtime and a timestamp.
  Likely entitlements on `java`: `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`,
  `allow-dyld-environment-variables`. Notarization accepts them *(unverified, but JVM and emulator apps ship so)*.
- **The one release blocker nobody could confirm:** whether the loader's write-then-`mprotect(RX)` of an unsigned
  `.so`'s pages is allowed under the hardened runtime, and with which entitlement. Spike S0.
- `sandbox-exec` still works on macOS 15 and 26 from a notarized app, but is deprecated and undocumented.
- The AOT cache is tied to the install path; an update or a move of the app invalidates it. Key it by version and
  retrain in the background (the launcher already does the background part).
- Sparkle 2 (EdDSA appcast, delta updates) for updates, appcast on GitHub Releases/Pages. DMG with `dmgbuild`
  (no Finder scripting, so it runs on CI), then sign, notarize and staple the DMG itself.

**Competition and agents (mostly unverified recollection; the Android CLI and RocketSim facts were checked):**
- Google's `android` CLI gives agents a JSON layout tree, `layout --diff` and annotated screenshots. RocketSim sells
  capture with bezels, network monitoring, deep-link and push shortcuts, environment toggles, and now a CLI with an
  agent skill. Nobody offers deterministic replay of a failure, cheap fan-out, or diffs beyond pixels.
- What makes UI tools work for agents: a pruned text tree with stable refs, a diff after each action, waiting on idle
  rather than sleeping, an annotated screenshot as fallback, short structured assertions, and artifacts per step.
  apksim has most of the parts (`nodes`, `settle`, the flight recorder); they are not yet one surface.

## Architecture

```
Apksim.app (Swift; AppKit panes, SwiftUI chrome)
 ├─ Workbench UI        instances as tabs/grid, inspector, timeline, palette
 ├─ InstanceManager     starts instances through the existing launcher + standby
 ├─ ControlClient       one async client per instance (commands + event stream)
 ├─ FrameView           per instance: shared IOSurface, or H.264 stream fallback
 ├─ AgentServer         MCP over loopback HTTP; `apksim mcp` is a stdio shim to it
 └─ Resources/apksim/   the release tree as it is today (launcher, jar, lib, runtime, jre)

instance JVM (unchanged process model, sandbox-exec, warm launch)
 └─ `--window hosted`: no NSApp, no menus; frames to shared surfaces; events out
```

Decisions and why:
1. **Keep one process per instance.** It is what makes launches 0.3 s, crashes contained and the sandbox per app.
   The app is a host, not a new runtime. The CLI, serve, beam and CI keep working from the same tree.
2. **Shell in Swift, AppKit where it is heavy.** `NSSplitViewController` panes, `NSTableView`/`NSOutlineView` for
   logs, network and node trees, a layer-backed `NSView` for frames; SwiftUI for settings, sheets, toolbars. Built
   with the macOS 26 SDK so standard sidebars and toolbars take the system look; minimum macOS 14.
3. **Frames: stream first, shared surface second.** The H.264 stream into `AVSampleBufferDisplayLayer` works
   today and gets a workbench on screen in days. Target is zero-copy: the instance's IOSurfaces handed to the app
   over XPC (`IOSurfaceCreateXPCObject`), a tiny "frame N ready" message per present, the app's display link
   feeding `vsync` back as serve's page already does. Spike S1 decides how the two processes meet (a Mach service
   the app registers; the sandbox profile must allow the lookup).
4. **One verb set for people and agents.** Every menu item, palette command and MCP tool is the same control
   command. The app adds a JSON form and an event stream to the control channel rather than a second API.
5. **State stays outside the bundle** (`~/Library/Application Support/Apksim`, with `APKSIM_HOME` still honoured
   and `~/.apksim` migrated or shared), so updates replace only the app.

## Phases

Each phase ends in something shippable. Sizes are rough working days for one focused session.

### Phase 0: spikes (2-3 days, before anything else)
- **S0 hardened runtime: done 2026-11-19, no loader change needed.** Releases have run under the hardened runtime
  all along: Temurin's `java` is signed with it (and with jit, unsigned-executable-memory, disable-library-validation,
  dyld-environment-variables and debugger entitlements), and jlink copies it. Tested on the 0.37.0 release tree
  (macOS 26.1), every Mach-O re-signed with a local development identity and `--options runtime`, then the test app
  headless under the default sandbox plus `NativeLoaderTest` and `NativeBitmapTest` (20 run, 4 skipped by assumption,
  as on the unmodified tree):

  | Entitlements on `java` | App runs | Native tests | Note |
  | --- | --- | --- | --- |
  | jit, unsigned-exec-memory, disable-library-validation, dyld-env | yes | 20 pass | Temurin's set less debugger |
  | jit, unsigned-exec-memory, dyld-env | yes | 20 pass | library validation on; `--no-network`'s shim loads |
  | jit, disable-library-validation, dyld-env | yes | 20 pass | |
  | jit only | yes | killed (SIGKILL) at the first ELF library | the loader needs one of the two above |
  | **jit, unsigned-exec-memory** | yes | 20 pass | shim not loaded under `--no-network` |

  Ship **allow-jit + allow-unsigned-executable-memory + allow-dyld-environment-variables, library validation on**
  (so only libraries signed by our team load, the inserted shim included); drop dyld-env once `--no-network` no
  longer needs `DYLD_INSERT_LIBRARIES`. Library validation on requires the libraries packed inside jars to be signed
  in the jar (Conscrypt's, sqlite4java's: unsigned, Conscrypt fails to load, silently at launch); notarization wants
  that anyway. Warm launches through a standby time the same on the re-signed and the original tree. Not tested:
  a Developer ID identity (the Mac has only a development one; the kernel's rules are the same), beam's sandbox, the
  AOT cache trained on a re-signed tree, the owner's app, allow-jit dropped.
- **S1 shared surface.** 200-line prototype: headless instance exports its surfaces, a stub app shows them; measure
  present-to-screen latency against the H.264 path at 120 Hz.
- **S2 hot swap.** On the bundled JDK: retranslate one changed class from a rebuilt APK and `RedefineClasses` it
  (stock HotSpot: method bodies only). Measure, and list what falls back to `recreate` or a 0.3 s relaunch.

### Phase 1: a real Mac app in a DMG (4-6 days)
The current simulator, properly packaged; no new UI yet.
- `macapp/`: Swift package, `Info.plist`, icon, entitlements, document types (`.apk`, `.apkrec`), URL scheme.
- The app launches instances with today's window; dropping an APK on the Dock icon or window runs it. Instances get
  the app's name and icon instead of `java`.
- `scripts/package-app.sh`: sign inner to outer (script finds every Mach-O), notarize, staple, `dmgbuild`, sign and
  notarize the DMG. `release.yml` gains the job; the tarball and cask stay (the cask can later point at the DMG and
  drop the quarantine step).
- Sparkle 2 with an appcast generated in the release job. AOT cache keyed by version; first-run training shown as
  progress in the app instead of a silent background job.
- "Install Command Line Tool" (symlink into `/usr/local/bin` or `~/.local/bin`).
- Needs from the owner: Apple Developer Program membership, a Developer ID certificate, CI secrets.

### Phase 2: the workbench (8-12 days)
- `--window hosted` in `SimWindow`/`simwindow.m` (no NSApp; pickers, sheets, share, web sign-in and clipboard asked
  of the app over the control channel, as `hostwatch` already does for links).
- Window: sidebar (apps, running instances, recordings), centre (one device or a grid), inspector on the right,
  a bottom panel (logcat, network, events). Opens showing only the device; panels on demand; layout kept per project.
- App library: drop APKs, or watch a Gradle output folder and relaunch on change (state kept through the existing
  process-death save and restore).
- Device toolbar: device, skin, rotation, fold, appearance, locale, font scale, network profile, location, sensors,
  permissions: all existing commands.
- Command palette (Cmd+K) over every control command, app, device and recording.
- Inspector: click a pixel to select its node (`nodes tree`, `viewtree`), bounds overlay, accessibility audit.
- Capture: screenshot and recording with the skin's frame, copied to the clipboard or dragged out.
- Control channel additions this needs: `--json` answers for `nodes`, `windows`, `stats`, `frames`, `config`; an
  `events` stream (activity, window, crash, exit, settle, log line, network entry).

### Phase 3: the agent surface (5-8 days; can overlap phase 2)
- MCP served by the app over loopback HTTP (token, Origin check), with `apksim mcp` as the stdio shim to the
  running app and today's standalone mode kept for CI. An agent and the person see and drive the same instances.
- Tool surface rebuilt on the lessons above: `snapshot` (pruned tree, stable refs), act by ref, every action
  returning the diff once `settle` answers, `screenshot --annotated` with refs drawn on, `assert` (text/visible/
  absent/pixel-match with a one-line reason), `wait_for`, `logs` and `network` since the last call, `gaps`.
- Verification artifacts: `verify start|end` wraps a task and returns a folder with before/after pictures, the
  tree diff, log and network slices, and a `.apkrec` the agent or reviewer can replay.
- Fan-out tools: `matrix` (run these steps on N devices/locales/font scales at once and report where results
  differ) and `compare` (two builds, same steps).
- An "Agent" panel: a live feed of what the agent did, each step linked to its frame; a pause button.
- One-click setup: writes `.mcp.json`, runs `claude mcp add`, ships a Claude Code skill and an `.mcpb` bundle.

### Phase 4: many at once and differentials (8-10 days)
- Grid of instances with mirrored input (one touch to all); status chip per instance (fps, MB, device).
- Matrix wall: one build over device x appearance x locale x font scale, live. Each cell is a headless instance at
  a low `--max-fps`; the one under the pointer runs at full rate.
- Build A against build B (PR against main): same input, differences in pixels, accessibility tree, network calls
  and frame timings, exported as an HTML report (`compare.html`'s logic, moved native).
- Snapshot review: `snapshot.py` results as golden / actual / difference with slider and overlay, accept per image.
- Scenes (`scene.py`) as panes, one per role, with the step list alongside.

### Phase 5: time and tests (8-10 days)
- Timeline for the flight recorder: tracks for input, frames, network, logs, database; scrubbing shows the frame
  and tree at that moment; select a range to save or file as an issue.
- Network inspector, three panes (hosts, requests, detail) on `netwatch`, with mock, patch and forward rules,
  conditions, and save as HAR for replay. No certificate or proxy to set up.
- Replay and bisect: open a `.apkrec`, replay it on any build, or point at a folder of builds and get the first one
  that diverges (`bisect-rec.py`).
- Test runner: pick androidTest APKs; tree of tests live, failure bundles and movies inline, rerun failed, shards.
- Crawl map (`crawl.py`): the screen graph, click a screen to open an instance there by its replayable path.

### Phase 6: hot swap and polish (open-ended)
- Watch the build, swap changed classes in place where S2 showed it is safe, else `recreate`, else relaunch; the UI
  says which happened.
- Extensions: user scripts that register palette commands and panels over the control channel.
- Performance budget, enforced in CI where it can be: app window in under 0.4 s; APK drop to first frame under
  0.5 s warm; hosted frame on screen within one vsync of present; 0% CPU with everything idle; shell under 100 MB.

## Security and privacy (requirements, checked before the first DMG)

Signing: the DMG is signed with a Developer ID and notarized. An unsigned DMG can be hosted on GitHub, but
Gatekeeper refuses it (since macOS 15 only System Settings > Privacy & Security > Open Anyway, or removing the
quarantine flag, gets past that), nothing proves the download is the build CI made, and updates could not be
verified against a signer.

Scope (owner, 2026-11-19): apksim stays the open-source engine with its flexibility and defaults as they are. The
promise below is the app's, to its customers, and the app keeps it by how it runs apksim, not by changing apksim
for everyone. Of the audit's fixes, only those the promise needs are done, and as options the app turns on.

The promise: **your APKs never leave your Mac and nothing about them is collected.** An APK is read, translated and
run locally; its name, package, contents, screens, traffic and logs are never sent anywhere by the app.

No data leaves the Mac on the app's account:
- Analytics and crash reports are off until the customer opts in (asked once, changeable in Settings, off if the
  question is dismissed). Opted in, a report holds the app's own state only (app and macOS version, the shell's or
  runtime's stack, which feature was used): never an APK's package name, file name or path, class or method names
  from the tested app, screen content, logs, URLs or recordings. Stacks are cut to apksim's and the JDK's own
  frames before sending, and Settings shows the exact report before the first one goes.
- Crash reports, logs and recordings otherwise stay in the state folder.
- The app's own network use is exactly: the update check (Sparkle with system profiling off, HTTPS, EdDSA-signed,
  can be turned off) and the first run's training download of the test app (hash-checked; bundle it in the DMG
  instead if size allows, so first run needs no network). Everything else on the wire is the Android app's.
- Recordings, HARs and failure bundles hold the tested app's traffic and logs: local only, redaction on by default
  for credentials, never shared without an explicit export.
- An agent sees screens and logs only when the user connects one; the Agent panel shows what it read and did.
- `PRIVACY.md` states this, and a CI check runs the packaged app with outbound network denied except an allow-list
  and fails on any other connection attempt by apksim's own code.

An APK is untrusted native code running as the user, not inside a VM:
- Instances always run under the sandbox in the app (no `--no-sandbox` switch in the UI). An APK the user did not
  build (downloaded, opened from a link) gets a profile close to beam's: no reads of the home folder, writes to its
  own slot only. The current default profile (deny a list of secret folders) stays for the user's own builds.
- The entitlements that weaken the hardened runtime go on the instance's `java` binary only; the Swift shell has none.
- Local channels need a credential: the control channel, adb port and MCP endpoint are loopback only today and the
  first two take any local client. In the app, a per-launch token (or a Unix socket in a 0700 folder), and
  Origin/Host checks on the MCP endpoint as serve has.
- The app asks for no privacy permissions (screen recording, accessibility, contacts, files outside what is opened).
- Releases are built by CI from the public source, with SHA-256 sums and third-party notices published.

### Audit of today's code (2026-11-19)

A read of the code, nothing exploited; `Serve`, `Beam` and the shadows were not read in full. Each finding needs a
check that fails before its fix.

Holds today: no telemetry, analytics, crash upload or update check anywhere; the simulated serial and ANDROID_ID are
hashes of the slot name, the Wi-Fi MAC is fixed; no host identifier is read. No camera, microphone, location or
Bluetooth hardware is touched.

Does not hold, most serious first:
1. **A web page can drive an instance that has a control port.** `Control` runs every line it reads and never
   checks for HTTP, so a page's `fetch` POST to `127.0.0.1:PORT` with a text body has each body line run as a command
   (blind: it cannot read answers). Confirmed on 0.37.0: a `curl` POST with an `Origin` header and the body
   `clipboard set ...` changed the app's clipboard. No token; any local process can connect, and commands such as `shot FILE`,
   `viewtree FILE`, `record`, `rec save`, `pick`, `camera image` write or read host paths the sandbox allows.
   Only launches with `--control`; serve's sessions and the tools use it. The adb port has no auth either (a browser
   cannot speak it), and its `tcp:HOST:PORT` forward reaches the LAN.
2. **State is readable by other users of the Mac.** Nothing sets a umask or modes: `~/.apksim` is 755 and its files
   644, including apps' data slots, recordings, port files and `autofill/*.properties` (documented as mode 600, not
   enforced).
3. **The default sandbox is a deny-list.** A hosted APK's native code can read most of the home folder (Downloads,
   much of `~/Library`, `~/.netrc`, `~/.kube`, shell history, other apps' slots, the autofill files), read the
   pasteboard, spawn processes, signal the user's processes, write outside the home folder (`/tmp`, a Homebrew
   install of apksim itself) and reach loopback and the LAN. Beam's profile is the allow-list to start from.
4. **The standby trusts whoever connects**: no peer-uid check, and every `-D` in the launch message is applied
   (the allow-list is in the client). `$TMPDIR/apksim-<hash>`, the class path's folder link, is predictable and used
   if it already exists. Both are reachable from a hosted APK under the default profile, and from other users when
   `TMPDIR` is unset (`/tmp`).
5. **Caches are shared and writable by hosted apps** (translated classes, extracted `.so` files, the AOT cache), so
   one app could plant code another launch loads.
6. **The clipboard is bridged both ways automatically**: whatever is copied on the Mac is readable by the hosted app.
   The app also sees the host's real interface names and addresses (`HostNetworks`).
7. **One automatic download**: the training app, from GitHub on first launch and after each upgrade (hash-checked).
8. Supply chain: Gradle dependencies pinned by version, not hash; release workflow actions pinned by tag; recordings
   redact four headers but not bodies or query strings.

What the app does about them (apksim's defaults unchanged):
1. Its state folder is its own (`~/Library/Application Support/<App>`, created 700 by the app), so customers' APK
   data and recordings are not readable by other users. Needs nothing from apksim.
2. Its instances are not reachable from a browser: finding 1 lets any web page a customer visits send commands to
   their running app, which the promise cannot live with. One opt-in addition to apksim, a control channel on a
   Unix socket (or a `--control-token`), which the app always uses; `--control PORT` stays as it is for scripts.
3. The training app ships inside the DMG, so the app makes no download of its own at first run.
4. The "no connections of our own" CI check on the packaged app, with analytics off and with it on (then only the
   reporting host, and the report's fields checked against the list above).

Left as they are, by decision: the default sandbox's deny-list, the standby's trust in local connectors, shared
caches, the automatic clipboard bridge, dependency pinning. They concern what a hostile APK or another local process
could do, not what we collect; customers run their own builds. Revisit if the app is ever pointed at APKs from
strangers.

## How to execute it cheaply

Parallel workstreams once phase 0 is in, each in its own worktree and PR:

| Stream | Touches | Model |
| --- | --- | --- |
| A. Packaging, signing, DMG, Sparkle, CI | `scripts/`, `macapp/` resources, `release.yml` | Sonnet; Haiku for plists and docs |
| B. Hosted window mode, shared surfaces | `native/simwindow.m`, `SimWindow.java` | strongest model: native, timing-sensitive |
| C. Control JSON + events | `Control`, `Host`, `Nodes`, `DeviceControls` | Sonnet |
| D. Swift shell and panes | `macapp/` only | Sonnet, with a design pass first |
| E. MCP v2 and agent tools | `scripts/mcp.py`, AgentServer | Sonnet |
| Hot swap (after S2) | `dex/`, `AppClasses`, a JVMTI agent | strongest model |

A and D never touch the runtime, so they cannot regress launch time or tests; B and C go through the usual gates
(`startup-gate`, `linux-smoke`). Reviews stay on Sonnet as the repo already requires.

## Decisions for the owner
1. Apple Developer Program membership and a Developer ID (needed for phase 1's release, not for the spikes).
2. Minimum macOS: 14 proposed (display link on views, current SwiftUI); 26 only would simplify the design work.
3. App name and bundle identifier: open (not "Android ..." in the name: Google's brand rules allow only "for Android").
4. Decided 2026-11-19: the app lives in a separate public repository under the owner's GitHub account and bundles a
   released apksim; what it needs from the runtime (hosted window, control socket, JSON and events) lands in apksim.
5. Build system: Swift Package plus a bundling script (proposed: scriptable, no project file to merge) or Xcode project.
6. Whether the standalone window stays for CLI launches (proposed: yes; the app is additive).

## Risks
1. ~~Hardened runtime against the ELF loader~~: settled by S0, two entitlements. The audit's findings are now the
   first risk: the sandbox and local-channel fixes above change behaviour scripts and CI rely on.
2. A missed unsigned Mach-O in the JRE: notarization lists them; the signing script must find them all.
3. `sandbox-exec` changing in a future macOS: keep the launch working, loudly, without it.
4. Cross-process surfaces under the instance's sandbox (S1); the stream path is the fallback and already exists.
5. Hot swap on stock HotSpot is body-only; structural edits need a relaunch, which at 0.3 s is an acceptable floor.
