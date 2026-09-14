# Lathe

**An on-device media processing engine for Apple platforms.**

A lathe takes raw stock and turns it down to a target spec. That is the job here:
images, video, animation, PDFs, comic archives and audio, resized, recompressed
and re-encoded to a requested quality — entirely on the device, with no
subprocesses and no server round-trip.

> **Status: early.** The module structure, the public API surface and the
> progress/cancellation seam are real and tested, and so are the first four
> capabilities: media probing, an ffprobe-compatible JSON shim, loudness and
> audibility analysis, and frame extraction. The encoders behind the rest are not
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

### Linking contract

**Every module is its own product.** Depend on the ones you use:

```swift
.product(name: "LatheImage", package: "Lathe")   // stills only
.product(name: "LatheVideo", package: "Lathe")   // probing, thumbnails, transcode
.product(name: "Lathe",      package: "Lathe")   // all five, via one import
```

The `Lathe` umbrella product is **media processing only, permanently**. Modules
that ingest media from the network — downloaders, in-app browsers — will ship as
separate products and are deliberately excluded from it, so an app that wants
none of that code can guarantee it has none by choosing a product, rather than by
auditing a transitive import graph after every version bump.

---

## What works today

### Media probing

`MediaProbe` reads a file's container headers through `AVURLAsset` and returns a
structured `MediaInfo` — duration, per-track codec, coded *and* display
dimensions, frame rate, bit rate, sample rate, channel count — with no
subprocess and no decoding, so probing a four-hour film costs what probing a
four-second clip costs.

```swift
let info = try await MediaProbe().probe(url: url)
if info.hasVideoTrack, !info.isEmptyAsset { … }
```

Two things it refuses to do: guess a frame count (counting frames is not free,
and an estimate presented as a measurement is worse than nothing), and treat
"the asset opened" as "this is media". A still image or an empty container comes
back as a `MediaInfo` with `isEmptyAsset` set, which is a fact to branch on
rather than an error to catch.

`MediaInfo.ffprobeJSON()` re-emits the same facts in the shape
`ffprobe -show_format -show_streams -of json` produces. It is a **compatibility
shim**, for replacing a subprocess prober as one reviewable change without also
rewriting whatever already parses its output. The numeric-looking fields that
ffprobe emits as JSON *strings* — `duration`, `bit_rate`, `size`, `sample_rate` —
are strings here too, because every parser written against ffprobe expects them
to be, and "helpfully" emitting numbers is a breaking change in somebody else's
decoder.

### Loudness and audibility

`LoudnessProbe` decodes PCM through `AVAssetReader` and answers two questions
that are easy to mistake for one:

```swift
let volume = try await LoudnessProbe().meanVolumeDB(url: url)      // a measurement
let audible = try await LoudnessProbe().hasAudibleAudio(url: url)  // a decision
```

`meanVolumeDB` reports `10·log₁₀(mean(s²))` — the same statistic the familiar
command-line volume filter prints, so existing thresholds keep working. **Do not
build new logic on it.** Whole-file mean volume has a false-negative cliff on
sparse audio: ten minutes containing two seconds of speech averages about
−45 dBFS and is indistinguishable, by that number, from a file with nothing in
it. That is not a corner case — it is an ordinary phone video with one spoken
sentence in it.

`hasAudibleAudio` therefore averages nothing. It walks short windows and returns
at the first one that clears both a peak and an RMS threshold, which makes it
correct on sparse audio *and* cheaper on ordinary audio: a file with sound near
its start is decided after a fraction of a second. Only genuinely silent files
pay for a full scan, and they must, because sound can begin at 9:58.

The result type is an enum, not a `Float`, because *no audio track*, *digital
silence* and *a measurement* are three different answers and a single number can
only carry one.

### Frame extraction

`FrameExtractor` pulls one frame out for a person to look at, or as numbers for
an algorithm:

```swift
try await FrameExtractor().thumbnail(from: video, to: jpeg, atSeconds: 5, maxWidth: 512)
let hashInput = try await FrameExtractor().grayscaleFrame(from: video, atSeconds: 5, size: 32)
```

The thumbnail path applies the track's rotation, never upsamples, picks its
format from the destination's extension and checks that format against the
capability probe **before** creating anything — so an unwritable format fails as
`encodeUnavailable` instead of leaving a 0-byte file that looks like a success.

The grayscale path returns exactly `size * size` bytes with no row padding,
verified before it returns. That check is there because a `vImage_Buffer`'s
`rowBytes` is padded more often than not, and an extractor that copies
`rowBytes × height` looks correct, passes a smoke test on a conveniently-sized
frame, and returns garbage on everything else.

### The capability probe

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

### Tests

**No binary media is committed to this repository.** Every clip the suite needs —
solid-colour and split-colour video at a known size and frame rate, tracks of
silence, of a continuous tone, and of 0.2 s of tone inside a minute of silence,
plus audio-only and deliberately-not-media files — is synthesised at run time by
`AVAssetWriter` and `AVAudioFile`. Fixture properties are therefore known by
construction rather than measured from a file somebody once made, and there is
nothing whose provenance has to be explained. A machine that cannot generate a
given clip records a known issue naming the reason instead of quietly passing.

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

Two things in it are resolved at run time rather than hard-coded, for the same
reason: both rot. The simulator destination is chosen from
`xcrun simctl list devices available`, and the Xcode scheme from
`xcodebuild -list -json` — preferring a `-Package` scheme, falling back to the
package's own name. The raw scheme listing is printed unconditionally, so a
failure on a future runner image can be diagnosed from the log without a rerun.

`.github/workflows/release.yml` cuts a signed, notarized DMG on a `v*` tag. It is
**deliberately inert today**: there is no application target in this repository
yet, and the workflow's first step says so and stops, rather than letting
`xcodebuild` fail confusingly several minutes later. The signing and notarization
path is there now so it can be reviewed and fixed independently of the app,
instead of being written under pressure on the day there is something to ship.

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
