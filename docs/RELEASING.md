# Releasing

A release is a signed, notarized `Greenroom-VERSION.dmg` attached to a GitHub release. Pushing a `v*` tag makes a
draft one; publishing the draft is by hand.

```bash
git tag v0.1.0 && git push origin v0.1.0
```

## One-time setup

Apple will only notarize an app signed with a **Developer ID Application** certificate (an "Apple Development" one,
which Xcode makes by itself, is not enough). The account holder of the Apple Developer team creates it.

1. **Certificate.** Xcode > Settings > Accounts > the team > Manage Certificates > + > Developer ID Application.
   Then in Keychain Access, under My Certificates, export it with its private key as a `.p12` with a password.
2. **Notary key.** App Store Connect > Users and Access > Integrations > App Store Connect API > Team Keys > +
   (access: Developer). Download the `.p8` once; note the Key ID and the Issuer ID on that page.
3. **Repository secrets** (Settings > Secrets and variables > Actions, or `gh secret set`):

   | Secret | Value |
   | --- | --- |
   | `DEVELOPER_ID_P12` | the `.p12`, base64: `base64 -i DeveloperID.p12 \| gh secret set DEVELOPER_ID_P12` |
   | `DEVELOPER_ID_P12_PASSWORD` | the password it was exported with |
   | `NOTARY_KEY_P8` | the `.p8`, base64: `base64 -i AuthKey_XXXX.p8 \| gh secret set NOTARY_KEY_P8` |
   | `NOTARY_KEY_ID` | the key's ID |
   | `NOTARY_ISSUER_ID` | the issuer ID |
   | `SPARKLE_ED_PRIVATE_KEY` | the update-signing key: `generate_keys --account greenroom -x key.txt`, then `gh secret set SPARKLE_ED_PRIVATE_KEY < key.txt` |

4. **Update-signing key.** Sparkle's `generate_keys` (in `.build/artifacts/sparkle/Sparkle/bin` after a build) made
   it once and keeps it in the login keychain under the account `greenroom`; its public half is `SUPublicEDKey` in
   `Resources/Info.plist`. Every update must be signed with it: lose it and installed copies can no longer update
   (a new key needs a release signed with both). Export it for the secret above and keep a copy somewhere safe.

Keep the `.p12`, `.p8` and the exported key out of the repository; delete the exported copies once the secrets are set.

## Releasing from a Mac instead

With the certificate in the login keychain and notary credentials stored once
(`xcrun notarytool store-credentials greenroom --key AuthKey_XXXX.p8 --key-id ID --issuer ISSUER`):

```bash
scripts/bundle.sh --identity "Developer ID Application" --version 0.1.0 --check
NOTARY_PROFILE=greenroom scripts/dmg.sh --identity "Developer ID Application" --notarize
```

## What the pipeline does

1. `scripts/bundle.sh`: builds the app, puts the apksim release named in `engine.lock` inside it (hash-checked),
   signs every binary, the libraries inside jars included, with the hardened runtime and a secure timestamp, then
   the app; verifies the signatures and runs the bundled test app headless through the app.
2. `scripts/dmg.sh --notarize`: sends the app to Apple's notary service and staples the ticket to it, builds the
   disk image with the app and a link to /Applications, signs the image, notarizes and staples it too (so it opens
   on a Mac that is offline), and writes its SHA-256 beside it.

## Updates

Installed copies read `https://github.com/aglose/greenroom/releases/latest/download/appcast.xml`: the appcast of the
newest *published* release, which the release job builds with `generate_appcast` and attaches. A draft is invisible
to them until it is published. `scripts/update-check.sh IDENTITY` runs an update end to end on this Mac (an old build
installed, a new one offered by a local appcast, downloaded, verified and installed on quit).

## Updating the engine

Edit `engine.lock`: the apksim version and the two SHA-256 values from that release's `SHA256SUMS`. CI runs the
new engine through the smoke test.

## Not yet

A background image for the disk image's window, the engine's startup cache trained with
progress shown in the app at first run.
