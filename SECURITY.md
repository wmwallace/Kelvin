# Security policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** Use GitHub's private vulnerability
reporting on this repository (Security → Report a vulnerability), which is visible only to the
maintainer. If you can't use GitHub, email `contact@usekelvin.app`.

Expect an acknowledgement within a week. This is a one-person project, so there is no formal SLA
beyond that, and there is no bounty.

## What is in scope

This application runs entirely on your machine and has no server, no account and no telemetry, which
removes most of the usual categories. What remains is worth reporting:

- **Anything that writes to a user's original photographs.** Every edit is parametric and stored in
  Kelvin's own folder in Application Support, keyed to the photograph — nothing is ever written next
  to an original, and the originals are read-only by design. A path where that is not true is the most serious
  bug this project can have — it destroys data that cannot be recovered.
- **Malformed-input crashes or memory-safety problems** reachable by opening a crafted image file.
  RAW decoding goes through Apple's Core Image, so many such issues belong to Apple; report them
  anyway and they will be forwarded.
- **Any network activity beyond the update check and place names.** No perception model ships and
  none is downloaded: since 0.9 (D27, D33) scenes are read by Apple's Vision framework and, on a Mac
  with Apple Intelligence, Apple's on-device Foundation Model — both part of macOS, and the language
  model is asked for on-device inference only, never Private Cloud Compute. A release build is
  allowed exactly two kinds of outbound traffic: Sparkle's update check against
  `https://usekelvin.app/appcast.xml` — on by default, turned off in Settings ▸ General, and it
  fetches the appcast and nothing else — and, for a photograph that carries GPS coordinates, Apple's
  geocoding and map-snapshot services, which receive that coordinate rounded to about 110 m so the
  filmstrip can name and map the place (on by default, turned off in Settings ▸ Perception, and the
  coordinate is all that goes — never pixels, a filename, or an identifier). Any other packet
  leaving a release build is a bug by definition, and a serious one given what the project claims.
  A build from source has no update feed, so it makes only the place-name requests.
- **Metadata leaking into exported files** beyond what the export settings say. Exports carry the
  source photograph's metadata by default, including its GPS position — that is documented and
  toggleable in the export panel. A case where the toggle does not take effect, or where data
  survives that the toggle claims to remove, is in scope.
- **Anything that sends a photograph, a file path, or EXIF data off the machine.**

## What is not in scope

- Traffic that macOS itself generates on Kelvin's behalf and that Kelvin does not initiate — for
  example, the system downloading or updating Apple Intelligence's model assets.
- Gatekeeper warnings on a build you assembled yourself without a signing identity. Published
  releases are signed and notarised; an unsigned local build warning is expected behaviour, not a
  vulnerability.
- Findings from an automated scanner with no demonstrated impact.

## Supply chain

Dependencies are pinned via committed `Package.resolved`, and CI uses only GitHub's own actions. If
you find a compromised or typosquatted dependency in the graph, that is in scope and urgent.
