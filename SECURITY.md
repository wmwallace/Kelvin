# Security policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** Use GitHub's private vulnerability
reporting on this repository (Security → Report a vulnerability), which is visible only to the
maintainer.

Expect an acknowledgement within a week. This is a one-person project, so there is no formal SLA
beyond that, and there is no bounty.

## What is in scope

This application runs entirely on your machine and has no server, no account and no telemetry, which
removes most of the usual categories. What remains is worth reporting:

- **Anything that writes to a user's original photographs.** Every edit is parametric and stored in a
  sidecar; the originals are read-only by design. A path where that is not true is the most serious
  bug this project can have — it destroys data that cannot be recovered.
- **Malformed-input crashes or memory-safety problems** reachable by opening a crafted image file.
  RAW decoding goes through Apple's Core Image, so many such issues belong to Apple; report them
  anyway and they will be forwarded.
- **Unexpected network activity.** The application makes exactly one kind of outbound request: a
  one-time download of the perception model's weights from Hugging Face, and not at all when the
  weights are bundled or staged locally. Any other outbound connection is a bug, and a serious one
  given what the project claims.
- **Metadata leaking into exported files** beyond what the export settings say. Exports carry the
  source photograph's metadata by default, including its GPS position — that is documented and
  toggleable in the export panel. A case where the toggle does not take effect, or where data
  survives that the toggle claims to remove, is in scope.
- **Anything that sends a photograph, a file path, or EXIF data off the machine.**

## What is not in scope

- The one-time model download itself. It is documented, it fetches weights and nothing else, and it
  can be avoided entirely with a local copy (`make stage-model`).
- Gatekeeper warnings on an unsigned build. Until releases are notarised, these are expected; see the
  README.
- Findings from an automated scanner with no demonstrated impact.

## Supply chain

Dependencies are pinned via committed `Package.resolved`, and CI uses only GitHub's own actions. If
you find a compromised or typosquatted dependency in the graph, that is in scope and urgent.
