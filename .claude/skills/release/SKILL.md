---
name: release
description: Merge Greenroom's open pull requests, refresh the docs for what landed, tag the next version, let CI build the signed notarized DMG, then publish the release. Use when the owner says "release", "cut a release", "ship it", or "merge everything and publish".
---

# Greenroom release

One run: merge ready PRs, update stale docs, tag, wait for CI, publish. Do not stop to ask between steps; stop only at
a **stop condition**. All the gh and git plumbing is in `scripts/release.sh` (read its header, not its body): call it
instead of composing your own commands, and keep its output as the only thing you read.

Rules:
- `main` changes only through PRs whose `build` check passes. Never `--auto`, never a plain merge commit.
- Nothing personal in anything pushed or in release notes (no emails but the noreply one, hostnames, secrets), and no
  AI-attribution line in release notes.
- Do git work for docs in a worktree (`git worktree add ../greenroom-release-docs -b docs-VERSION origin/main`);
  never switch branches or reset in a shared checkout. Tagging needs no checkout: the script tags `origin/main`.

## 1. Survey
```bash
scripts/release.sh survey
```
Prints the last tag, open PRs with check state, what is on main since the tag, and the diffstat. Drafts are skipped
(list them in the report). If nothing is on main since the last tag and no PR is ready, say so and stop.

## 2. Merge
```bash
scripts/release.sh merge N M ...        # oldest number first; waits for checks, squash-merges with the owner's noreply email
```
Before merging a PR skim its diff (`gh pr diff N --stat`, then only what looks risky); fix confirmed bugs on its
branch, ignore nits. A PR with a conflict is rebased on `origin/main` in a worktree and force-pushed with lease.
**Stop** (leave the PR open, merge the rest, say why) if: checks fail for a reason you cannot fix, a conflict needs a
product decision, a PR adds personal info, or one touches `.github/workflows/release.yml`, signing, secrets or
`engine.lock` unexpectedly.

## 3. Version and notes
```bash
scripts/release.sh version patch|minor|X.Y.Z
scripts/release.sh notes > SCRATCHPAD/notes.md
```
Semver on the last tag, judged from the merged PRs: new features or options -> minor; only fixes, docs, CI ->
patch; below 1.0 a breaking change is a minor bump, and say so. Fix VERSION now. Then edit the notes: replace the
TODO with a short headline paragraph and group the bullets under Added / Changed / Fixed. Keep the PR links.

## 4. Docs
Only if what landed made docs stale: README.md (features, options, build table), `docs/` (RELEASING.md, PLAN
files), `PRIVACY.md` if network behaviour changed. Match the existing style; do not invent measurements. Use the diffstat
from step 1 to decide, read only the files a change touches. Commit in the docs worktree, open a PR "Docs for VERSION:
...", merge it with `scripts/release.sh merge N`. Skip the step (and the PR) when nothing is stale.

## 5. Tag and build
```bash
scripts/release.sh tag VERSION
```
It waits for CI on main, creates the annotated tag `vVERSION` on `origin/main`, pushes it and watches `release.yml`
(sign, notarize, DMG, appcast, draft release; about 15-30 min). It exits 75 after ~9 minutes with the run still going:
run `scripts/release.sh wait VERSION` (foreground, 10-minute timeout) until it reports success. **Never end the turn
while the run is in progress**: a background watch would leave the draft unpublished.
**Stop** if the run fails: the script prints the failing log tail. Fix on a branch via PR if it is code or workflow;
if it is a missing secret, tell the owner which (docs/RELEASING.md). Move the tag only after the fix is on main, and
say you are moving an unpublished tag (`gh release delete vX.Y.Z` if a partial draft exists, then delete and re-push
the tag).

## 6. Publish
```bash
scripts/release.sh publish VERSION notes.md
```
Checks the draft has the DMG, its SHA-256, the dSYM zip and a signed appcast carrying VERSION, publishes it with the
notes, and checks the live update feed (`releases/latest/download/appcast.xml`) now serves VERSION. Installed copies
update from that feed. Re-read the notes against the privacy rule before running.

## 7. Report
Version and release URL; PRs merged (links); PRs left open and why; docs changed; whether the feed serves the new
version; what was not verified (no Mac-side install or update was run; `scripts/update-check.sh IDENTITY` does that).
Remove the temporary worktrees.
