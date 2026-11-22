# Greenroom

A Mac app for building and testing Android apps: drop an APK on it and the app is running in under a second, as an
ordinary Mac process. No emulator, no virtual machine.

Greenroom is the app around [apksim](https://github.com/aglose/apksim), the open-source engine that runs unmodified
APKs on Apple Silicon. apksim stays a command-line tool with every switch it has; Greenroom bundles a released
version of it and adds the workbench.

**Status: early.** Today:

- Open APKs (drop, ⌘O, double-click in Finder, recent list); each runs as a simulator inside the Greenroom window.
- The mouse is the finger, the scroll wheel scrolls, the keyboard types, ⌘V pastes.
- Toolbar: Back, Home, Rotate, light/dark, the device (phone, foldable, tablet, desktop, TV, switched while the app
  runs), Screenshot, Restart, Close.
- **Side by Side** (⌘\\) shows every running simulator at once, sized so a phone and a tablet get about the same
  area. Device > Open Beside As starts the same APK again as another device. Drag a device by its body to move it
  (it snaps to the stage's edges and the other devices), by the grip at its corner to resize it (its shape kept, never
  too small to use), or close it from the button at its other corner; VoiceOver has the same as actions. Moved
  devices keep their places, also across launches, until Tidy Up (⌥⌘\\) tiles them again.
- **Memory**: once the simulators and Greenroom together take 2 GB (or a fifth of the Mac's memory if that is less),
  the stage's top left says how much.
- **Mirror Input** (⇧⌘M) sends each touch, key and toolbar command to every simulator, at the same place on each
  screen whatever its size.

- **Compare** (⇧⌘D, or File > Compare With APK… for a second build) marks what differs between the chosen
  simulator and the others as you use them: boxes around content that is only on one side or has moved, shading
  over pixels that differ, and a summary under the pictures. With Mirror Input, two builds are driven as one.
- **Changes** (⌘D, "Changes…" in a session row's menu, or the command palette) shows what a session's build did to the
  app, against a base you pick: the repository's base branch, another session, a pull request, a branch or commit, or
  an APK file. Greenroom walks both builds on hidden devices and shows, in tabs, **Summary** (screens new, changed
  and gone, crashes on either side, what the walk did not finish), **Screens** (base, head and a difference map side
  by side or under a wipe slider, and "Go there" to open the screen on the session's simulator), **Map** (the head's
  screen map with new screens green, changed amber and gone red), **Video** (a recorded tour: both builds taken to
  each screen that differs, played together with a chapter per screen) and **Live** (both builds side by side with
  mirrored input). "Copy summary" puts a Markdown summary on the clipboard and "Open report" opens the crawler's own
  report. The base is never built for you: with no build of it stored or on CI the sheet says so and offers to check
  the commit out as a worktree, and you build it from its row. Closing the sheet does not stop a comparison that
  is running; reopen it to see the result. A tour is recorded on this Mac by two hidden simulators and kept with
  the comparison; nothing leaves the Mac.
- **App data per device**: an app opened plainly keeps its data (sign-ins, databases, settings) per device kind, so
  sign in once on a phone and every later phone of that app is signed in, across restarts of the simulator and of
  Greenroom; a tablet has its own. A second copy on the same device while the first runs starts from a copy of the
  first one's data, dropped when it closes. A fresh launch never touches it. A session's simulator keeps its own.
- **Variables and scripts** for sign-ins and test set-up: add variables (LOGIN_EMAIL, LOGIN_PASSWORD...) in Settings,
  kept in your login Keychain, secret ones masked as `••••` in any output; Device > Run Script (or ⌘K) runs a script
  of yours on the chosen simulator with them in its environment and `gr` on its PATH to drive it
  (`gr tap-text "Sign in"`, `gr type "$LOGIN_PASSWORD"`, `gr wait "Welcome"`). Scripts live in
  `~/Library/Application Support/Greenroom/scripts` (and a session's `.greenroom/scripts`); New Script… writes an
  example. A variable can also be a 1Password reference (`op://Private/My App/password`): it is read with the 1Password
  CLI each time a script starts, after you approve in 1Password, so credentials never leave your vault for Greenroom's
  Keychain (needs `brew install 1password-cli` with 1Password > Settings > Developer > Integrate with 1Password CLI;
  Test in Settings checks a reference). Build recipes get the other variables too. An agent can run a script you have switched on for agents in
  Settings, as it was then, and never sees a value.
- **Secure sign in**: when the chosen device shows a sign-in screen (a password field), a **Sign in** button appears
  in the bar (also Device > Secure Sign In…, ⌥⌘L). Its panel runs one of your sign-in scripts, or fills the fields on
  screen from your variables (plain, secret or 1Password: each field's variable is guessed and then remembered per
  app) and taps the button you pick, such as Connect. Values are typed into the app and never shown, not even in the
  panel. Save as Script… writes the same steps as a script, for the Screen Map's signed-in walk or for agents.
- **Signed-in screen map**: in the Screen Map, pick "Sign in with <script>" and the walk first runs that script on a
  hidden device of its own, then walks the whole app on that device's signed-in data (one device, as the crawler
  walks kept data). Your own devices' data is never used or changed, and the walk's copy is removed when it ends.
  A script that fails stops the walk with its last line.
- **Inspector** (⌥⌘I): the nodes on the chosen simulator's screen in a pane; point at the picture to pick one and
  see its text, kind, size and the box that takes its tap. While it is open, clicks pick instead of tapping.
- **Log** (⇧⌘L): the chosen simulator's log as it is written, with a filter.
- **Record** (⌥⌘R) turns the engine's flight recorder on: input, log, network, database and screen for the last
  minutes. File > Save Recording writes a `.apkrec` bundle; Save Recording and Open Timeline shows it in the
  engine's trace viewer, as does opening a `.apkrec` file. Bundles replay with `apksim replay`.
- **Agents** drive the same simulators over the Model Context Protocol: the screen as compact text with stable
  references, every action answered with what changed, checks and waits in one call
  ([docs/AGENTS-INTERFACE.md](docs/AGENTS-INTERFACE.md)). The toolbar's Agent button shows what an agent did and
  can pause it. For Claude Code there is a plugin, with the tools and a skill that verifies a change with them:
  `/plugin marketplace add aglose/greenroom`, then `/plugin install greenroom@greenroom`.

Still to come: the timeline and network inspector inside the window, replay and bisect from the app, differences in network calls and frame timings.

How a simulator gets on screen: the engine runs headless, sends its screen as H.264 over a loopback connection, and
the app shows it with `AVSampleBufferDisplayLayer`; input goes back over the engine's control channel
(`Simulator.swift`, `Control.swift`, `VideoDecoder.swift`).

## Your APKs stay on your Mac

Greenroom never uploads an APK, and collects nothing about one: not its name, package, contents, screens, network
traffic or logs. Analytics and crash reports do not exist yet; when they do they will be off until you turn them
on. [PRIVACY.md](PRIVACY.md) has the details and how to check them.

## Requirements

An Apple Silicon Mac, macOS 14 or later.

## Building

Xcode 26 (or its command-line tools) is all that is needed.

```bash
scripts/bundle.sh --check
```

This downloads the apksim release named in `engine.lock` (checked against the SHA-256 there), builds
`build/Greenroom.app` with the engine inside, signs it ad hoc and runs a bundled test app headless through it.

| Option | |
| --- | --- |
| `--identity NAME` | sign with a real identity (library validation on, secure timestamp) instead of ad hoc |
| `--engine DIR --testapp APK` | bundle an unpacked apksim release of your own |
| `--version X.Y.Z` | the app's version |
| `--check` | verify the signatures and run the smoke test |
| `--variant debug` | build `build/Greenroom Debug.app` instead: a copy to keep beside the release, with its own name and bundle id, an orange icon and an orange line along the top of its window, its own state folder (`~/Library/Application Support/Greenroom Debug`, so both run at once without sharing simulators, data or the agent endpoint) and no in-app updates |

A release is cut by pushing a `v*` tag: [docs/RELEASING.md](docs/RELEASING.md) has the certificate and secrets it needs.

`swift build` alone gives the bare executable; run it with `GREENROOM_ENGINE=/path/to/an/apksim/release`.

## How it is put together

- `Sources/Greenroom`: the app (Swift, AppKit). `Engine.swift` is the only place that starts the engine.
- `Contents/Resources/engine` in the built app: the apksim release, unchanged, with its own Java runtime.
- Signing: every binary has the hardened runtime. Only the engine's `java` has entitlements (JIT, executable
  memory for the Android libraries it loads, and dyld variables for apksim's `--no-network`); the app itself has none.
- State: `~/Library/Application Support/Greenroom`, readable by you alone.
- [docs/PLAN.md](docs/PLAN.md) is the plan: what is built, what is next, and what was measured on the way.
