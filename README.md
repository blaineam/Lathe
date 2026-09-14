# Lathe

**An on-device media processing engine for Apple platforms.**

A lathe takes raw stock and turns it down to a target spec. That is the job here:
images, video, animation, PDFs, comic archives and audio, resized, recompressed
and re-encoded to a requested quality — entirely on the device, with no
subprocesses and no server round-trip.

> **Status: scaffold.** The module structure, the public API surface and the
> progress/cancellation seam are real and tested. The codecs behind them are not
> written yet — every unimplemented entry point throws a named
> `LatheError.notImplemented` rather than crashing or silently succeeding. See
> [What works today](#what-works-today).

---

## Why it exists

Most media tooling on Apple platforms is a command-line binary wrapped in a
process spawn. That is fine on a desktop and impossible on iOS, where `fork`/
`exec` is not available at all. The usual answer is to port the C tools. That
answer is mostly wrong: the system frameworks already do most of the work, in
hardware, with no licence exposure — ImageIO encodes HEIC, AVIF, JPEG, PNG, GIF,
TIFF, JPEG 2000 and PDF; AVFoundation probes and thumbnails; VideoToolbox encodes
H.264 and HEVC with constant-quality control; Vision does OCR.

Lathe is the thin, well-tested layer over those frameworks, plus a small number
of permissively licensed native libraries for the gaps they leave — of which the
significant one is **WebP encode**, which ImageIO genuinely cannot do.

It is designed for two kinds of consumer:

- **A media-processing app** — batch recompression and format conversion over a
  large personal library, running unattended.
- **A media-archival app** — user-facing, one file at a time, where the result is
  inspected immediately and quality matters more than throughput.

Neither is assumed. Lathe knows nothing about libraries, sync, downloads or
storage; it takes a file and a target and gives you a file back.

---

## Module map

| Module | Contents |
|---|---|
| **`LatheCore`** | Shared vocabulary: error taxonomy, progress and cancellation, job identity, resize arithmetic, metadata policy, quality targets, logging. No codecs, no I/O. |
| **`LatheImage`** | Still images. The runtime capability probe lives here. Encode, aspect-fit downscale, metadata rewrite, animation recompression. |
| **`LatheVideo`** | Probe, thumbnail and frame extraction, hardware transcode with a quality target. |
| **`LatheDoc`** | PDF image recompression, document attributes, OCR text layers, comic archives (CBZ/CBR). Builds on `LatheImage`. |
| **`LatheAudio`** | Loudness and audibility analysis — peak, true peak, integrated LUFS, loudness range, silence ranges. |
| **`Lathe`** | Umbrella. `import Lathe` re-exports all of the above. |

Import the umbrella for convenience, or a single module to keep your binary
small: `import LatheImage` links no PDF or video code.

```swift
import Lathe

print(Lathe.capabilityReport)   // what this system can actually encode
```

---

## What works today

**The capability probe is real, and it is the piece everything else depends on.**

```swift
if EncodeSupport.shared.canEncode(.avif) {
    // encode AVIF
} else if let fallback = EncodeSupport.shared.firstSupported(of: [.heic, .jpeg]) {
    // degrade
}
```

Two things make it worth reading the source of:

**It never branches on OS version.** Not once, and the rule is enforced by
convention rather than by hope — there is no `#available` anywhere in
`EncodeSupport.swift`. Which OS first shipped encode support for a given format
is hard to establish from documentation, differs between device and simulator,
and rots. AVIF is the sharp case: it has no `UTTypeAVIF` constant in any Apple
SDK, so it can only be named by the raw string `"public.avif"`, and its
availability floor is not discoverable from headers at all. Asking the system is
cheaper and cannot be wrong.

**It asks by attempting, not by reading a list.** The obvious implementation is
`CGImageDestinationCopyTypeIdentifiers()`. That list is advisory: it has been
observed to advertise types that then fail at destination creation. So the probe
calls `CGImageDestinationCreateWithData` against a scratch buffer for each
candidate — the same call the real encode path makes — and caches the result.
Where the advertised list and reality disagree, the gap is exposed as
`overReportedTypeIdentifiers` and printed by the test suite.

The other finished piece is **progress and cancellation** (`LatheCore`), built on
one primitive: a callback whose **return value is the cancellation signal**.

```swift
let result = try await LatheWork.run(reporting: sink) { progress in
    for (index, unit) in units.enumerated() {
        try progress.checkpoint(LatheProgress(stage: "encode",
                                              unitIndex: UInt64(index),
                                              unitCount: UInt64(units.count)))
        try encode(unit)
    }
    return output
}
```

No separate cancel token, no shared atomic at the call site — every progress tick
is automatically a cancellation checkpoint. `Task` cancellation is wired into it,
and the work body runs on a dedicated queue rather than the cooperative pool,
because a long blocking encode on a cooperative thread starves the pool and can
deadlock unrelated actors.

Cancel latency is **one work unit**, stated rather than hidden: most native media
libraries do not poll for cancellation internally, so a unit boundary is the
honest granularity.

Everything else is an API surface with throwing stubs. That is deliberate — the
shapes are reviewable now, and filling them in does not move anyone's call sites.

---

## Licence policy

**Lathe is Apache-2.0, and every dependency it will ever take is permissive:
BSD, MIT, Apache-2.0 or MPL-2.0. No GPL. No AGPL. Ever.**

This is not a preference, it is a constraint that shapes the design, and it is
worth being explicit about because several obvious implementation choices are
ruled out by it:

- The best-known GIF optimizer is GPL-2.0-only with no library API. Lathe adds a
  quantizer in front of the system GIF writer instead.
- Several widely used metadata and PDF libraries are GPL or AGPL. Lathe uses
  system frameworks plus permissive alternatives.
- Popular video encoders are GPL. Lathe uses VideoToolbox.

A permissively licensed library may be vendored or linked statically. An
LGPL component, if one is ever added, must be dynamically linked and kept in a
separate repository — it does not go in this one.

**Anything that ingests media from a URL deliberately lives outside Lathe.**
Downloaders bring both licence complexity and app-store policy problems, and
keeping them structurally outside this package means the boundary cannot be
crossed by accident during a refactor.

---

## Requirements

- iOS 17+ / macOS 14+
- Swift 6.0 toolchain (Xcode 16+)

### Toolchain

The package declares `swift-tools-version: 6.0` rather than the 5.9 minimum, so
it builds in the **Swift 6 language mode**. `Sendable` correctness across the
progress and cancellation seam is the whole point of that seam, and having the
compiler check it beats having a reviewer check it.

Tests use **Swift Testing** (`import Testing`) rather than XCTest: parameterised
cases via `arguments:` are a much better fit for "assert this property for every
image format", and the capability suite leans on it heavily.

### Building

```sh
swift build
swift test
```

> If your checkout lives on a network or synced volume, codesigning the test
> bundles can fail with `resource fork, Finder information, or similar detritus
> not allowed`. Build to local disk instead:
> `swift build --scratch-path /tmp/lathe-build`.

---

## Continuous integration

`.github/workflows/ci.yml` builds and tests for macOS and the iOS Simulator, and
prints the discovered capability table for each — so the encode-support matrix is
regenerated per platform on every run instead of being maintained by hand.

**The workflow has never executed.** It was written against current runner images
and action versions and is correct as far as review can establish, but until this
repository exists on a CI host, treat it as unverified. Expect to iterate on the
simulator destination string in particular.

---

## Contributing

The stubs are the roadmap. Each one throws
`LatheError.notImplemented(feature:)` naming itself, so:

```sh
grep -rn "LatheError.todo" Sources/
```

is an accurate and self-updating list of what is missing.

Two rules for anything that lands here:

1. **No version gating for codec capability.** Probe at runtime and degrade.
2. **No GPL or AGPL dependencies**, direct or transitive.

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).
