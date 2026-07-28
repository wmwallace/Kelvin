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

## Version scheme

Decided before the first tag, so it never has to be re-decided under release pressure:

- **Marketing version** (`CFBundleShortVersionString`, set by `KELVIN_VERSION`, default `0.1.0`):
  `MAJOR.MINOR.PATCH`. Pre-1.0, a MINOR bump means features, a PATCH bump means fixes only.
- **Build number** (`CFBundleVersion`): the commit count, emitted by the packaging script —
  monotonic by construction, which is what Sparkle requires, and nothing has to remember to bump it.
- **Tags**: `vX.Y.Z` on the exact commit the release was built from. Cut the tag when the DMG is
  uploaded, not before. Never reuse a tag, never move one — Sparkle, GitHub Releases and anyone's
  clone all treat a tag as permanent.

## Updates (Sparkle)

The app carries Sparkle; a released copy checks `Branding.appcastURL`
(`https://usekelvin.app/appcast.xml`) — only after the user consents, and that URL is frozen the
moment the first binary ships. The plumbing:

- **Key pair**: generated 26 July 2026 with Sparkle's `generate_keys` (it lives in the build
  artifacts: `.build/artifacts/sparkle/Sparkle/bin/`). The private half lives in the login
  Keychain ("Private key for signing Sparkle updates") — never in the repository. Back it up
  with the release identity; losing it means shipped copies refuse all future updates.
- **Public key**: baked into the packaging script (it is what shipped copies verify against, and
  it is not a secret); `KELVIN_SPARKLE_PUBKEY` overrides it if the pair is ever regenerated.
- **Appcast**: served from the domain (a few KB, permanent URL); the DMG itself is a GitHub
  release asset. Each release's appcast entry is signed with `sign_update` (same artifacts
  directory). Pass the key as a *file* — `sign_update -f "<backup>/sparkle_private_key"`. Reading it
  from the login Keychain raises an authorisation dialog, and with nobody to answer it the command
  simply hangs rather than failing.
- **Binary deltas**: required from the second release onwards, because with the weights inside a
  full update is a 1.4 GB download. `scripts/make-delta.sh` builds one; see the next section.

## Binary deltas

A release ships 1.4 GB to deliver, usually, a few kilobytes of changed code — the rest is the same
4-bit weights the user already has. A delta patch is how that stops being true, and it is the
difference between an update people accept and one they learn to dismiss.

```sh
gh release download v0.1.0 --pattern '*.dmg' --dir /tmp        # the copy users actually installed
scripts/make-delta.sh /tmp/Kelvin-0.1.0.dmg dist/Kelvin.app    # after the new app is stapled
```

That writes `dist/Kelvin-<version>-from-<oldbuild>.delta`, signs it, and prints the
`<sparkle:deltas>` block to paste into `appcast.xml`. In between it applies the patch to a scratch
copy and refuses to give you a delta whose result is not byte-identical to the new app *and* still
passes `codesign` — a patch rewrites part of a signed bundle, which is exactly the operation that
can leave a signature covering contents that no longer match.

Measured, 0.1.0 → a rebuild of the same source: **87 KB**, produced and verified in 23 seconds, in
place of a 1.4 GB download. That is the floor rather than the figure to quote — a release with real
code in it is bounded by the compressed diff of the 45 MB executable, so expect single-digit
megabytes. The weights, which are all the rest of it, do not change between releases and cost
nothing.

What is easy to get wrong:

- **`sparkle:deltaFrom` is the build number, not the marketing version.** Sparkle looks a delta up by
  the installed app's `CFBundleVersion` — `appcastItem.deltaUpdates[hostVersion]`, where
  `hostVersion` is `SUHost.version`. For the 0.1.0 release that key is `191`. Write `0.1.0` there and
  the appcast still validates, still publishes, and matches nobody; every user quietly takes the full
  download. The script reads the number out of the old bundle so it cannot be typed wrongly.
- **The patch must be built from the bundle that actually shipped**, which is why the recipe starts
  by downloading the previous release rather than trusting whatever is left in `dist/`. Mounting the
  image also sidesteps extended attributes: a `.app` that has been launched accumulates
  `com.apple.macl` and `com.apple.provenance`, and Sparkle documents delta creation as rejecting
  code-signing-related attributes. A copy read out of a read-only image carries none of them.
- **One delta per predecessor.** A patch is a pair of versions, not a version. Someone two releases
  behind matches no `deltaFrom` and takes the full download, so list a delta from every release still
  plausibly installed inside the same `<sparkle:deltas>`.
- **Do not raise `BinaryDelta --version`** past what the *older* app understands. The patch is read
  by the Sparkle already on the user's disk, not the one being installed. Today the default is
  right: the tool and the shipped framework come from the same pinned Sparkle, and
  `BinaryDelta info` reports the result as version 4.2, LZMA.

The `.delta` is not notarised, and does not need to be: it is not a bundle, it is authenticated by
its EdDSA signature, and the app it reconstructs was stapled before the patch was made — the ticket
is a file inside `Contents`, so it travels through the patch like everything else.

And the reassuring part: if a delta is missing, mis-keyed, unsigned or fails to apply, Sparkle logs
"Failed to download delta update. Falling back to regular update…" and downloads the full image.
Getting this wrong costs bandwidth, not installs.

## Cutting a release

In order, because several of these are irreversible:

1. `make test` green, and the version decided (see the version scheme above).
2. `make stage-model`, then `scripts/package-app.sh` with `KELVIN_SIGN_IDENTITY`,
   `KELVIN_NOTARY_PROFILE` and `KELVIN_VERSION` set. Two notarisation waits, ~35 min total.
3. Run the first-run checks below on the DMG, not just the app.
4. `scripts/make-delta.sh` against every still-installed predecessor.
5. Tag `vX.Y.Z` on the exact commit that was built, and push it.
6. `gh release create vX.Y.Z dist/Kelvin-X.Y.Z.dmg dist/*.delta` with notes that say what changed
   and what still does not work.
7. Add the item to `appcast.xml` — `sparkle:version` is the `CFBundleVersion` of the build you just
   made, which the packaging script printed into its `Info.plist` — and **commit it to `main`**. The
   feed at `usekelvin.app/appcast.xml` redirects to the file on `main`, so a release is published by
   a commit and the website is never touched.
8. Watch an installed copy of the previous release actually take the update.

## Sizes

The app is about 1.7 GB with the weights inside; the DMG about 1.4 GB. **GitHub caps a release asset
at 2 GB.** The packaging script warns if the bundle crosses it. A larger perception model would not
fit, and would force a split-asset design.

## Before the FIRST published release

Three things need doing before a binary leaves this machine, and none can be done later:

- ~~Generate the Sparkle EdDSA key pair~~ — done 26 July 2026 (see Updates above). The private
  half is in the login Keychain and still needs backing up with the release identity.
- ~~Check what the app says about the network once an update check exists.~~ Done with the
  Sparkle integration: SECURITY.md scopes the appcast check as the one allowed request, the
  README says a release asks before it ever checks, and Sparkle's standard permission prompt
  gates automatic checking (`SUEnableAutomaticChecks` is deliberately not set — writing `false`
  would suppress the prompt rather than defer to it).
- **Back up the `.p12` and the `.p8` somewhere other than this Mac.** Apple lets you download a
  `.p8` once, ever. Back up the Sparkle private key alongside them.

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
