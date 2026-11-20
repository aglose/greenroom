# Greenroom

A Mac app for building and testing Android apps: drop an APK on it and the app is running in under a second, as an
ordinary Mac process. No emulator, no virtual machine.

Greenroom is the app around [apksim](https://github.com/aglose/apksim), the open-source engine that runs unmodified
APKs on Apple Silicon. apksim stays a command-line tool with every switch it has; Greenroom bundles a released
version of it and adds the workbench.

**Status: early.** Today: open APKs (drop, ⌘O, double-click in Finder, recent list) and each runs as a simulator
inside the Greenroom window, several at once, switched from the sidebar. The mouse is the finger, the scroll wheel
scrolls, the keyboard types, ⌘V pastes. The toolbar has Back, Home, Rotate, light/dark, the device (phone, foldable,
tablet, desktop, TV, switched while the app runs), Screenshot, Restart and Close. Still to come: several simulators
side by side, an inspector, a timeline, build comparisons, an agent interface.

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

A release is cut by pushing a `v*` tag: [docs/RELEASING.md](docs/RELEASING.md) has the certificate and secrets it needs.

`swift build` alone gives the bare executable; run it with `GREENROOM_ENGINE=/path/to/an/apksim/release`.

## How it is put together

- `Sources/Greenroom`: the app (Swift, AppKit). `Engine.swift` is the only place that starts the engine.
- `Contents/Resources/engine` in the built app: the apksim release, unchanged, with its own Java runtime.
- Signing: every binary has the hardened runtime. Only the engine's `java` has entitlements (JIT, executable
  memory for the Android libraries it loads, and dyld variables for apksim's `--no-network`); the app itself has none.
- State: `~/Library/Application Support/Greenroom`, readable by you alone.
