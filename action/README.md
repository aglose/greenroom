# Greenroom map snapshot (Action)

Keeps main's screen map current without anybody's Mac: on a push to the default branch it skips a tree that already
has a map, otherwise walks the app in the engine's Linux image and pushes `refs/greenroom/maps/*` (never forced,
nothing else). The files are written by `scripts/map-snapshot.py`, which `scripts/map-snapshot-check.sh` proves
byte for byte equal to what Greenroom writes.

**Unverified.** This was written without running on GitHub. Spike MS6 in `docs/MAP-HISTORY-PLAN.md` must confirm: the
workflow token may push a ref outside `refs/heads` (and branch protection or rulesets don't refuse it); `actions/checkout`
with `fetch-depth: 0` leaves a repository `--has` can read; the engine image's name, its `/engine/scripts/crawl.py`
path and the `--matrix` flags; the walk's time and memory on a hosted runner (KVM or not); `$GITHUB_SHA` is the pushed commit.

```yaml
on: { push: { branches: [main] } }
permissions: { contents: write }          # the push of refs/greenroom/maps/* needs it
jobs:
  map:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - run: ./gradlew assembleDebug
      - uses: OWNER/greenroom/action@vX
        with: { apk: app/build/outputs/apk/debug/app-debug.apk, engine-image: "ghcr.io/OWNER/greenroom-engine:1.2.3" }
```

The profile is `.greenroom/map.json` (`depth`, `seconds`, `starts`, `combos`, `signIn`, `offline`; all optional). With no
`depth` and `seconds` the walk covers the whole app, as the app's own walks do; give the job the time for it.
Other profiles are other histories, so the people on the team need the same file.

**Signed in.** A profile with `signIn` needs credentials on the runner: a sign-in script the engine can run headless,
with the account's secrets in GitHub Secrets, and an account made only for this. The captures can show that account's
data, and the refs are readable by everyone who can read the repository: decide that first. Until then the Action
walks signed-out profiles only.
