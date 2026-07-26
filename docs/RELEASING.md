# Releasing

How to build a copy of Kelvin that opens on someone else's Mac.

## What you need once

- **Apple Developer Program** membership ($99/year). Not for the App Store — for the certificate.
- A **Developer ID Application** certificate, made in Keychain Access (Certificate Assistant →
  Request a Certificate) and downloaded from the developer portal.
- A **notarytool profile**, stored once:

  ```sh
  xcrun notarytool store-credentials "kelvin-notary" \
    --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <uuid>
  ```

Back up the certificate (export it as `.p12`) and the `.p8`. Apple lets you download the `.p8` once,
ever, and losing the certificate's private key means revoking and reissuing.

## Building a release

```sh
make stage-model                       # copies the weights + their licence into Vendor/
KELVIN_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
KELVIN_NOTARY_PROFILE=kelvin-notary \
  scripts/package-app.sh
```

That produces `dist/Kelvin.app` and `dist/Kelvin-<version>.dmg`, both signed, notarised and stapled.

Leave out `KELVIN_NOTARY_PROFILE` for a local build you only need to run yourself. Leave out both for
an ad-hoc build; it will run on your Mac and nowhere else.

## What the script does, and why in that order

1. **Builds** into its own scratch directory, so packaging doesn't take the SwiftPM lock away from
   `swift run`.
2. **Assembles the bundle.** Resource bundles go in `Contents/Resources`, not `Contents/MacOS` —
   MLX looks for `default.metallib` inside each bundle's `resourceURL`, and getting this wrong
   produces an app that launches fine and then dies on the first photo.
3. **Bundles the weights** from `Vendor/PerceptionModel`, and refuses to make a *signed* build
   without them. A release must not depend on a download.
4. **Signs inside out** — nested bundles first, the app last, with the hardened runtime and a secure
   timestamp. Never `--deep`, which Apple documents as unsuitable for signing.
5. **Notarises the app, then staples it.** Stapling matters: a stapled app validates with no network,
   so it works for someone offline.
6. **Builds the DMG** from the stapled app, with an `/Applications` symlink, then signs, notarises
   and staples the image too.

The app is notarised *before* the image is built. A mounted disk image is read-only, so an app placed
inside one can never receive its own ticket afterwards.

## Timings

Measured on a release with the weights inside:

| Step | |
|---|---|
| Build + assemble + sign | ~5 min |
| Notarise the app | ~15 min |
| Build the DMG | ~1 min |
| Notarise the DMG | ~15 min |

Two notarisation submissions is unavoidable: the app's ticket can't cover an image that didn't exist
when it was issued.

## Version numbers

`KELVIN_VERSION` sets the version string (default `0.1.0`). The build number comes from the commit
count, so it always increases — which Sparkle requires and which nothing else has to remember.

## Sizes

The app is about 1.7 GB with the weights inside; the DMG about 1.4 GB. **GitHub caps a release asset
at 2 GB.** The packaging script warns if the bundle crosses it. A larger perception model would not
fit, and would force a split-asset design.

## Before the FIRST published release

Two things freeze the moment a binary leaves this machine, and neither can be added later:

- **Generate the Sparkle EdDSA key pair**, and keep the private half out of the repository. The
  appcast URL is compiled into every build; ship one without it and that build can never update
  itself.
- **Adding Sparkle makes two published claims false, and both must change in the same commit.**
  The README's Privacy section says released builds "make no network requests at all", and the
  Settings ▸ Perception pane says the same to the user's face. An update check is a network
  request. Say what it actually is — a version check that sends no data about the photographs —
  rather than leaving a sentence that a packet capture disproves.
- **Back up the `.p12` and the `.p8` somewhere other than this Mac.** Apple lets you download a
  `.p8` once, ever.

## First-run check

Check the app, then check the thing a stranger actually downloads — they are not the same artifact,
and only the second one has been through the image:

```sh
xcrun stapler validate dist/Kelvin.app     # works offline?
spctl -a -vvv -t exec dist/Kelvin.app      # accepted, source=Notarized Developer ID

MP=$(hdiutil attach dist/Kelvin-*.dmg -nobrowse -readonly | tail -1 | awk '{print $NF}')
spctl -a -vvv -t exec "$MP/Kelvin.app"     # the copy a user drags to /Applications
xcrun stapler validate "$MP/Kelvin.app"
hdiutil detach "$MP"
```

Then launch the bundled binary directly, so its stderr is visible, and give it a photograph:

```sh
KELVIN_DEMO_IMAGE=~/somewhere/a-photo.jpg dist/Kelvin.app/Contents/MacOS/kelvin-app
```

Watch it read the scene. The failure this catches — resource bundles in the wrong place — lets the
app launch, show its empty state and its icon, and then die on the first photo. Opening the `.app`
by double-clicking hides the one line of stderr that says why.

## Troubleshooting

**`codesign` hangs, then fails.** The first use of a newly installed private key raises a Keychain
dialog. Find it and choose *Always Allow*. In CI there is nobody to click it — import the `.p12` into
a temporary keychain and run `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k
<pw> <keychain>`, which is the step everyone misses.

**Notarisation rejected.** `xcrun notarytool log <submission-id> --keychain-profile kelvin-notary`
returns a JSON report naming the file and the reason.

**The app launches but dies on the first photo.** Almost certainly the resource bundles are in the
wrong place; see step 2.
