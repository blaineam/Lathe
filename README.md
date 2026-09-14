# Lathe

**An on-device media processing engine for Apple platforms.**

A lathe takes raw stock and turns it down to a target spec. That is the job here:
images, video, animation, PDFs, comic archives and audio, resized, recompressed
and re-encoded to a requested quality — entirely on the device, with no
subprocesses and no server round-trip.

> **Status: early.** The module structure, the public API surface and the
> progress/cancellation seam are real and tested, and so are the first six
> capabilities: media probing, an ffprobe-compatible JSON shim, loudness and
> audibility analysis, frame extraction, still-image encoding, and video
> transcoding. PDF and animation are not written yet — every unimplemented entry
> point throws a named `LatheError.notImplemented` rather than crashing or
> silently succeeding. See [What works today](#what-works-today).

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
significant one is **WebP encode**, which ImageIO genuinely cannot do. That gap
is closed: `LatheImage` vendors libwebp's encoder as C source and writes WebP
itself, lossy and lossless. It is the only third-party code in the package; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

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
| **`LatheImage`** | Still images. The runtime capability probe lives here. Encode (including WebP, via vendored libwebp), aspect-fit downscale, metadata rewrite, frame/animation inspection, animation recompression. |
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

### Still-image encoding

`ImageEncoder` re-encodes one still: format, quality, aspect-fit downscale and
metadata policy, in a single pass.

```swift
let result = try await ImageEncoder().encode(
    source: heic, to: jpeg,
    format: .jpeg, quality: .quality(0.7),
    resize: .longestSide(2048), metadata: .stripLocation
)
```

Four things it refuses to get wrong, each of which is a way this goes wrong in
practice rather than in theory:

**It never enlarges.** The obvious implementation sets
`kCGImageDestinationImageMaxPixelSize`, which upsamples without complaint when
the number exceeds the image — so a "cap the longest edge at 2048" batch turns a
300-pixel avatar into a blurry 2048-pixel one and reports success. That key is
not used anywhere in this package. The size is resolved through
`ResizeTarget.resolve(from:)`, which clamps to the source, and the scaling path
is entered only when the result is strictly smaller.

**It never leaves a 0-byte file.** The format is checked against `EncodeSupport`
before anything is created, and the encode runs into a temporary file that is
moved into place only after `Finalize` succeeds. An unsupported format, a
cancellation or a codec failure therefore leaves the destination exactly as it
was — including leaving a *previous* file intact, which an in-place encode does
not.

**It never silently rotates a photo.** Re-encoding is the classic way to do that,
in two directions: drop the tag and the picture lands on its side, apply it *and*
keep it and the picture is rotated twice. `OrientationStrategy` makes the choice
explicit and implements both — and whether a destination format can carry the tag
at all is **probed at runtime**, not assumed. That is not a stylistic echo of the
capability probe; the first version of this code had a hand-written table saying
PNG could not carry an orientation, and current ImageIO writes one into the
`eXIf` chunk and reads it straight back. A format that turns out not to keep the
tag gets the rotation baked into its pixels instead of losing it.

Size arithmetic runs against the **displayed** size, not the stored one. A
portrait photo stored landscape with a rotation tag is the everyday case, and
fitting a box against the stored axes gives a differently *shaped* result from
the one the caller drew on screen.

**Metadata is written, not inherited.** `CGImageDestinationAddImageFromSource`
carries the source's metadata across implicitly, which makes a strip policy a
list of things somebody remembered to delete — and anything the source carried
that nobody thought of travels by default. For a feature whose whole purpose is
removing data, that is the wrong default. `CGImageDestinationAddImage` writes only
what it is handed, so `.stripAll` is provable by construction. (The other call,
`CGImageDestinationCopyImageSource`, copies encoded data through *without*
re-encoding. That is the right tool for "strip GPS and touch nothing else", and
it belongs to `ImageMetadataRewriter` — which is still a stub. Asking this
encoder for `QualityTarget.lossless` is refused rather than reinterpreted —
**except for WebP**, where libwebp has a genuine lossless coder and `.lossless`
selects it.)

One thing no policy may remove is the orientation: dropping it does not
anonymise a picture, it rotates it.

Two platform findings the suite pins, both of which are the reason quality 1.0
deserves suspicion:

- **Quality 1.0 is not lossless.** On HEIC it still quantises, and re-encoding an
  already-compressed source at 1.0 routinely produces a *larger* file. The
  encoder honours the request, logs when the output grew, and reports both byte
  counts so a caller can keep the smaller file.
- **ImageIO's AVIF encoder rejects a quality of exactly 1.0** — `Finalize`
  returns false and writes nothing, while 0.999 encodes fine and every other
  lossy format accepts 1.0. Lathe does not clamp it silently; it fails, with an
  error that names the cause, and leaves no file.

#### WebP, written by Lathe rather than ImageIO

ImageIO reads WebP and cannot write it. `EncodeSupport` proves that rather than
asserting it — `org.webmproject.webp` *is* advertised by
`CGImageDestinationCopyTypeIdentifiers()` and then refuses to produce a
destination, which is the whole reason the probe attempts an encode instead of
reading the advertised list. So `LatheImage` writes WebP itself, through libwebp
vendored as C source (see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and
`Sources/CWebP/VENDORING.md`).

It is the same call — same `QualityTarget`, `ResizeTarget`, `MetadataPolicy`,
progress, result type, and the same never-enlarge and never-a-partial-file rules:

```swift
try await ImageEncoder().encode(source: png, to: webp, format: .webp, quality: .lossless)
```

The probe was not taught to lie to make this work. `imageIOEncodableFormats` is
still exactly what ImageIO demonstrated and `destinationTypeIdentifier(for:)` is
still nil for WebP; `canEncode` answers "will this package write me one" and
`backend(for:)` says which encoder would. ImageIO wins ties, so the day it gains
a WebP encoder the routing switches on its own.

Two consequences worth knowing before you choose WebP as an output format:

- **`.lossless` is real**, and round-trips every pixel. It is also frequently
  *smaller* than lossy on synthetic images — a generated gradient measures 92
  bytes lossless against 702 lossy — so "lossless costs bytes" is a fact about
  photographs, not about WebP.
- **A WebP written here carries no metadata at all.** EXIF, XMP and ICC live in
  WebP's extended `VP8X` container, which only libwebp's muxer writes, and the
  muxer is deliberately not vendored. Orientation is therefore baked into the
  pixels rather than dropped — the same rule that already covers every format
  with nowhere to put a tag — so a rotated photo comes out upright. Animated
  WebP cannot be written for the same reason; it can be *read*, by ImageIO.

### Frame and animation inspection

`ImageInspector` answers "how many frames, does it play, and for how long" from
a file's headers, without decoding anything.

```swift
let info = try ImageInspector().inspect(url)
info.isAnimated      // true only if the frames carry timing
info.frameCount      // every frame, animated or not
info.duration        // seconds, ONE pass, nil for a still
info.frameDelays     // per frame, in order
info.loopCount       // 0 means forever; nil means the container does not say
```

**`isAnimated` is not `frameCount > 1`**, and that is the whole point. A
multi-page TIFF reports a count above one and does not play; so does a HEIC
burst. A one-frame GIF sits in an animated container and is a still. So the test
is *more than one frame **and** the frames carry per-frame delay metadata* —
each animated format keeps its delay under its own key, and a container with
none has no notion of when to show the next frame. A present-but-zero delay
still counts as timing: zero is a real GIF idiom meaning "as fast as possible".

Three things that produce a wrong *number* rather than an error, each handled:

- **A zero delay is not zero time.** Summing zeros reports 0.0 seconds for a file
  that visibly plays. Delays at or under 11 ms become 100 ms — the classic
  browser rule. The clamp is applied here rather than taken from ImageIO because
  ImageIO's own clamp is not uniform: its GIF and WebP floors are 100 ms and its
  APNG floor is 50 ms, so the same animation would change duration on transcode.
- **Loop count is not duration.** `duration` is one pass, which is what "how long
  is this clip" means and what `MediaProbe` means by a duration for video and
  audio. `totalPlaybackDuration` multiplies, and is nil for a forever loop.
- **Delays are per frame.** They are returned as an array, because dividing a
  total by a count assumes a uniform frame rate that animations do not have.

Nothing is decoded: `kCGImageSourceShouldCache: false` on every read, so asking
about a 200 MB file costs the price of its headers. And "not an image" is an
error, never `false` — a corrupt file and a still are different answers.

### Video transcoding

`VideoTranscoder` re-encodes one video: codec, quality target, aspect-fit
downscale, metadata policy and audio disposition, in a single pass.

```swift
let result = try await VideoTranscoder().transcode(
    source: clip, to: smaller,
    codec: .hevc, quality: .quality(0.55),
    resize: .longestSide(1080), metadata: .stripLocation
)
print(result.usedHardwareAcceleration, result.rateControl, result.audio)
```

`AVAssetReader` decodes, VideoToolbox encodes, `AVAssetWriter` muxes — and the
encoder is driven **directly** rather than through `AVAssetWriterInput`'s output
settings. That is the decision the rest follows from: an
`AVVideoCompressionProperties` dictionary cannot set a constant quality on every
codec, cannot reach a property newer than AVFoundation's convenience keys, and —
the decisive one — offers no way to read back whether a hardware encoder was
actually used. Owning the `VTCompressionSession` makes all three available, and
the result type reports them instead of asserting them.

**Quality is a quality, not a bitrate.** `QualityTarget.quality(0...1)` maps to
`kVTCompressionPropertyKey_Quality`, which is `API_AVAILABLE(macos(10.8),
ios(8.0))` — constant-quality video encoding is reachable at this package's
deployment floor and needs no recent OS.
`QualityTarget.constantQualityFactor(_:)` maps to the newer
`kVTCompressionPropertyKey_ConstantQualityFactor`, which is **probed rather than
version-gated**: the session is asked, through
`VTSessionCopySupportedPropertyDictionary`, whether it knows the key, and where
it does not the same number is applied to `Quality` instead. Either way
`VideoTranscodeResult.rateControl` says which one ran, so a fallback is visible
rather than silent. `QualityTarget.lossless` is refused outright — VideoToolbox
has no lossless H.264 or HEVC mode, and quietly re-reading "do not re-encode" as
"re-encode at maximum quality" would be the worst possible answer.

**B-frames stay on.** `kVTCompressionPropertyKey_AllowFrameReordering` is true by
Apple's default and is set explicitly here anyway, in both directions, because
the well-known failure is a transcoder that turns it off and never mentions it —
a double-digit bitrate cost at equal quality that reads as "VideoToolbox is just
worse". What the session actually negotiated is read back and reported.

**No `AVVideoComposition`, for anything.** Not for rotation and not for
resizing. A composition is the obvious way to scale through a reader/writer pair
and it routes every frame through the compositor, which flattens the source and
drops Dolby Vision's per-frame metadata before the encoder is ever reached. A
`VTPixelTransferSession` between decode and encode does the scale instead, and
the track's rotation is *carried* as the writer input's `transform` rather than
baked into pixels — so a portrait video stays portrait without a pixel moving.
Colour primaries, transfer function and matrix travel from the source's format
description onto the encoder, and an HDR source is decoded into a 10-bit buffer
rather than an 8-bit one. None of that makes this a Dolby Vision-preserving
transcode; a re-encode regenerates the bitstream. The claim is narrower and
checkable: nothing in this path throws the colour information away before the
encoder sees it.

**It never enlarges, and it never leaves a partial file.** The size comes from
`ResizeTarget.resolve(from:)` — clamped to the source, resolved against the
*displayed* size and mapped back onto the stored axes — and is then rounded down
to even dimensions, because 4:2:0 chroma cannot represent an odd one. The whole
transcode is written to a sibling temporary file that is moved into place only
after the writer reports `.completed` and the file is non-empty, so a
cancellation or a codec failure leaves the destination exactly as it was.

**Audio is passed through, not re-encoded.** Where the destination container
accepts the source's audio as it stands — asked of the writer, not looked up in
a table — the encoded samples are copied across untouched. Re-encoding AAC to
AAC is a second generation of loss bought for nothing when what was asked for is
a smaller *video* track. Where the container refuses it, the track is decoded and
re-encoded to AAC rather than dropped, and `VideoTranscodeResult.audio` says
which happened.

Progress is measured rather than animated: the fraction is the current frame's
presentation time over the asset's duration, reported from the pump that reads
the frames, so cancel latency is one frame rather than one file.

Two platform findings the suite pins:

- **`ConstantQualityFactor` is not CRF.** The name suggests the inverted 0–51
  scale of the familiar command-line encoders; Apple's key is `0.0...1.0` with
  1.0 the *best* quality, per its own header. Lathe's `QualityTarget` documents
  it as CRF semantics and that wording is now wrong; the mapping here follows
  the header, not the name.
- **Driving two writer inputs by polling `isReadyForMoreMediaData` deadlocks.**
  The video input goes not-ready part way through and never recovers, while the
  writer's status stays `.writing` and reports no error at all. One
  `requestMediaDataWhenReady` pump per input is the shape that works, and the
  failure it replaces is worth naming because it is completely silent.

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

Everything else — PDF and comic archives, animation, the lossless metadata
rewrite — is an API surface with throwing stubs. That is deliberate: the shapes
are reviewable now, and filling them in does not move anyone's call sites.

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

**What is actually linked today: libwebp** (BSD-3-Clause, plus a patent grant),
vendored as source under `Sources/CWebP/upstream/` and compiled by SwiftPM — no
binary artifact, no `.xcframework`, no release pipeline. `Sources/CWebP/VENDORING.md`
records the pinned tag and commit, exactly which files were taken and which were
not, and the script that refreshes them. Every vendored file is byte-for-byte
upstream. `LatheImage` is the only module that links it, so a consumer that
depends on `LatheCore` or `LatheAudio` alone ships none of it.

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
3. **A vendored dependency comes with a `VENDORING.md`**: the pinned tag and
   commit, what was taken and left out, a refresh script, and its licence
   reproduced in `THIRD-PARTY-NOTICES.md`.

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).
