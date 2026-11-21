# Privacy

## The promise

**Your APKs never leave your Mac, and nothing about them is collected.**

An APK you open is read, translated and run on your Mac by the bundled engine. Greenroom does not send, to us or to
anyone, an APK or anything derived from one: its file name or path, package name, classes, resources, screens,
recordings, logs, or the network traffic it makes.

## What Greenroom itself sends

Today: nothing. The app makes no network connection of its own. There is no analytics, no crash reporting and no
update check in this version, and the engine's one download (a test app it trains its startup cache with) ships
inside the app instead.

Network traffic you will see comes from the Android app you are running, which reaches the network as it would on
a phone.

## Agents

If you connect a coding agent ([docs/AGENTS-INTERFACE.md](docs/AGENTS-INTERFACE.md)), it reads the screens and logs
of the apps you run and acts on them, on this Mac, through a connection only programs running as you can open (a
token in a file only you can read; web pages are refused). What the agent's own provider receives is between you
and that agent; Greenroom sends it nothing by itself.

## What will be added, and how

- **Update checks**, when the app can update itself: a request for the list of versions, with no identifier, which
  you can turn off.
- **Crash reports and usage analytics**, opt-in: off until you turn them on, asked once, changeable in Settings.
  A report will hold Greenroom's own state only (app and macOS version, a stack trace cut to Greenroom's and the
  engine's own code, which feature was in use) and never anything from an APK, as listed above. Settings will show
  the exact report before the first one is sent.

This file changes in the same commit as any change to what the app sends.

## What stays on your Mac

`~/Library/Application Support/Greenroom`, readable only by your user: the engine's caches, the data of the apps you
ran (as a phone would keep it), and logs. The recent-APKs list is in the app's preferences. Deleting that folder
removes all of it.

## Checking this yourself

Greenroom and its engine are open source. The app's only code that starts a process or touches the network is in
`Sources/Greenroom/Engine.swift`, and you can watch the app's connections with any network monitor: with no APK
running there are none.

CI checks it on every change: `scripts/network-check.sh` captures every packet leaving the Mac, tagged with the
process that sent it (or asked for the DNS lookup), while the app launches the engine, trains its startup cache,
streams a simulator, serves an agent and shows every pane, and fails if one came from Greenroom or its engine. You
can run it yourself (`sudo -v && scripts/network-check.sh`).
