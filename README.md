# Lathe

**An on-device media processing engine for Apple platforms.**

A lathe takes raw stock and turns it down to a target spec. That is the job here:
images, video, animation, PDFs, comic archives and audio, resized, recompressed
and re-encoded to a requested quality — entirely on the device, with no
subprocesses and no server round-trip.

> **Status: early.** The module structure, the public API surface and the
> progress/cancellation seam are real and tested, and so are the first nine
> capabilities: media probing, an ffprobe-compatible JSON shim, loudness and
> audibility analysis, frame extraction, still-image encoding, frame and
> animation inspection, video transcoding, document page counting, and
> searchable-PDF OCR. PDF recompression and animation recompression are not
> written yet — every unimplemented entry point throws a named
> `LatheError.notImplemented` rather than crashing or silently succeeding. See
> [What works today](#what-works-today).
>
> A tenth capability sits deliberately **outside** that surface: `LatheFetch`,
> an embedded CPython interpreter and a pure-Python package installer, shipped
> as its own product and excluded from the `Lathe` umbrella. It contains no
> downloader — it is the runtime one would be written in. See
> [Running Python on device](#running-python-on-device).

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
| **`LatheCore`** | Shared vocabulary: error taxonomy, progress and cancellation, job identity, resize arithmetic, metadata policy, quality targets, logging. No codecs, no I/O. | `BulkRun` runs many jobs at once inside a `ResourcePool` whose lanes are **per workload class**, not one number — a machine with 24 cores has no more video encoders than one with 4.
*Reads a plain URL as well as a file.* `MediaSource` accepts `file`, `http` and `https`. Video and audio are **streamed** — AVFoundation reads a remote container by range request, so probing a two-hour film costs kilobytes — and a remote comic archive is counted from its index with two range requests. Formats whose readers need a file (ImageIO, PDFKit) are staged to a bounded temporary download. This reads the URL it is given and never goes looking for one; discovering media inside a web page is `LatheFetch`, which a store build can leave out.
| **`LatheImage`** | Still images. The runtime capability probe lives here. Encode (including WebP, via vendored libwebp), aspect-fit downscale, metadata rewrite, frame/animation inspection, animation recompression. |
| **`LatheVideo`** | Probe, thumbnail and frame extraction, hardware transcode with a quality target. | Chapters are preserved, on the video track.
| **`LatheDoc`** | Documents. Page counting for PDF and CBZ, searchable-PDF OCR (Vision), page editing — reorder, remove, insert, merge — for both formats, and its own ZIP reader and writer; PDF image recompression, document attributes and archive recompression are still stubs. Builds on `LatheImage`. |
| **`LatheAudio`** | Audio. Inspection (duration, codec, bitrate, lossless-or-not), loudness and audibility analysis, and transcoding to AAC or Apple Lossless with a rule against pointless re-encoding. | Chapters are preserved through a transcode: a chapter list is a separate text track plus a track association, not metadata, so carrying it needs a second muxed input.
| **`LatheMeta`** | Metadata: reading and editing what a file *says about itself* — iTunes-style atoms (MP4/M4V/M4A/MOV), EXIF/IPTC/XMP stills, PDF document attributes — in one normalised model. Injection never re-encodes the media. ID3v2 is read (v2.2/2.3/2.4) and written (v2.4) by this module's own parser, so an MP3 tag edit copies the audio rather than re-muxing it. **Subtitles:** SubRip and WebVTT parsed from hostile input (BOM, CRLF, legacy encodings, bad timings), written into MP4/M4V/MOV as selectable `tx3g` tracks with language, title, forced and SDH flags — several languages per file, video and audio copied untouched — and extracted back to SubRip. Depends on `LatheCore` alone. |
| **`LatheLookup`** | Online metadata: TMDb for film and television, OpenSubtitles for subtitles, each with the **user's own API key** — none ships here. `SubtitleInstaller` searches for a film's subtitles, downloads the best per language, and writes them into the file. Includes the filename parser that turns a release name into a searchable title and year, which needs no key at all. Separate from `LatheFetch`: this fetches a synopsis for a file you already have, not the file. |
| **`LatheMP3`** | MP3 encoding, via vendored LAME. **LGPL — the only non-permissive code in Lathe**, which is why it is its own product and is not in the umbrella: naming it takes on the obligation, and not naming it proves you have not. Apple ships no MP3 encoder on any platform, so there is no permissive alternative. See `Sources/CLAME/VENDORING.md`. |
| **`Lathe`** | Umbrella. `import Lathe` re-exports all of the above. |
| **`LatheFetch`** | **Not in the umbrella.** An embedded CPython interpreter — lifecycle, the GIL, captured output, tracebacks as Swift errors — an installer for pure-Python packages the *user* acquires at run time, and a `yt-dlp` surface on top of both: format listing and selection, download with progress and cancellation, and an `AVAssetWriter` mux that stands in for the `ffmpeg` call iOS forbids. Network ingest, so it is opt-in by product. |

Import the umbrella for convenience, or a single module to keep your binary
small: `import LatheImage` links no PDF or video code. `import Lathe` links no
Python at all, and that is a standing guarantee rather than today's arrangement.

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

.product(name: "LatheFetch", package: "Lathe")   // embedded CPython — NOT in the umbrella
```

The `Lathe` umbrella product is **media processing only, permanently**. Modules
that ingest media from the network — downloaders, in-app browsers — will ship as
separate products and are deliberately excluded from it, so an app that wants
none of that code can guarantee it has none by choosing a product, rather than by
auditing a transitive import graph after every version bump.

**`LatheFetch` is the first of those, and it is the case the rule was written
for.** It is a `.library` product of its own; it is *not* among the `Lathe`
target's dependencies, and adding it there would hand an embedded interpreter to
every existing consumer of the umbrella in a routine version bump. The
consequences of depending on it are real and worth choosing deliberately:

- it binds a CPython interpreter, which your application supplies and embeds;
- it fetches from a package index on the user's behalf, which is network
  activity an App Store reviewer will ask about;
- it makes third-party Python code executable in your process.

None of that belongs to an app that recompresses photographs, and the product
list is how such an app proves it has none of it.

`LatheFetch` depends on `LatheCore` — for the logging subsystem, so one predicate
still filters the whole package out of a host's logs — and on nothing else in
this package. The dependency runs in that direction only: `import LatheCore`
links no Python.

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

### Audio inspection

`AudioInspector` answers "how long is this?" for audio, alongside `MediaProbe`
for video and `ImageInspector.totalPlaybackDuration` for animation — and reports
the facts a compression decision is actually made from:

```swift
let info = try await AudioInspector().inspect(url)
info.duration                       // seconds, exact rather than extrapolated
info.stream?.codecName              // "aac", "alac", "pcm", "mp3", "flac", "opus"
info.stream?.isLossless             // the decision everything else turns on
info.stream?.bitsPerSecond          // what a saving has to be measured against
info.chapterCount                   // non-zero means an audiobook, and see below
info.hasArtwork
```

It reads container headers only, so a nine-hour audiobook costs what a ringtone
costs. `isLossless` is matched against the CoreAudio format constants rather than
against a list of strings, and anything unrecognised is treated as *lossy* —
which is the safe direction to be wrong in, because it makes the transcoder more
cautious rather than less.

Duration is loaded with `AVURLAssetPreferPreciseDurationAndTimingKey`, which is
not a parameter: an MP3's headline duration is extrapolated from the first
frame's bitrate and is wrong by seconds on any VBR file, and a type whose job is
to be right about duration cannot offer being wrong as an option.

### Audio transcoding

`AudioTranscoder` re-encodes one audio file to AAC or Apple Lossless in an MPEG-4
container — the sibling of `ImageEncoder` and `VideoTranscoder`, with the same
`QualityTarget`, `MetadataPolicy`, `ProgressHandle` and never-leave-a-partial-file
rule.

```swift
let result = try await AudioTranscoder().transcode(
    source: flac, to: m4a, codec: .aac, quality: .quality(0.5)
)
switch result.outcome {
case .transcoded:       print(result.source.codecName, "→", result.destination!.codecName)
case let .skipped(why): print("left alone:", why)
}
```

#### It refuses to re-encode lossy audio for nothing

The headline, and the default. Transcoding a 128 kbit/s MP3 to 128 kbit/s AAC
stacks a second psychoacoustic model on the first one's artefacts and routinely
produces a *larger* file that sounds worse. An optimiser that does that across a
library has made every file worse, irreversibly.

So a **lossy** source is re-encoded only when the target bitrate is at most
three-quarters of the source's, and otherwise **nothing is written at all**: the
destination is untouched, `result.output` is `nil`, and `result.outcome` carries
both bitrates and the fraction it needed. A source whose bitrate cannot be
determined is skipped too — there is no proving a saving against an unknown
number. `LossySourceRule.allow` and `.never` are the two overrides, and
`AudioTranscoder.plan(for:)` gives the whole decision without touching the disk,
for a UI that wants to show it or a queue that wants to sort by it.

A **lossless** source is the opposite case and is never governed by that rule:
that is where re-encoding wins, and where it is defensible. Lossy → Apple
Lossless is refused by default in the same way, because ALAC cannot restore what
a lossy encoder discarded — it only buys a file three to five times larger that
sounds identical.

One last guard runs after the encode, because bitrate arithmetic is a prediction
and an encoder is entitled to disagree: an output that came out **larger than the
source** is discarded and the destination left alone.

#### It never upsamples

Output sample rate is `min(requested, source)` and output channel count is
`min(requested, source)`. A 22 kHz mono voice memo cannot come back as 48 kHz
stereo, which is what a fixed "everything at 48/stereo" preset does to a library
of voice memos — twice the bytes for exactly the same information. The rule holds
even against the codec: if a source's rate is below anything AAC can encode, the
transcode is refused rather than resampled upward.

#### Multi-channel is preserved, and any downmix is reported

`ChannelPolicy.preserve` is the default, so 5.1 stays 5.1 and keeps its channel
layout; `.downmixToStereo` and `.atMost(n)` are opt-in. Whatever happened comes
back as `result.channels`, and the case where preservation was impossible is its
own — a multi-channel source whose layout the encoder will not accept is
`downmixedForWantOfALayout`, not silently lumped in with a downmix somebody
asked for. (Reducing 7.1 to 5.1 is a mixing decision with no single right answer,
so `.atMost(6)` against an 8-channel source becomes the stereo downmix every
decoder agrees on, reported as one.)

**`AVAssetWriterInput` raises an Objective-C exception — not a Swift error — when
a channel layout is not one its encoder accepts**, and Swift cannot catch that:
it takes the host application down. AAC does not accept every
`kAudioChannelLayoutTag_*` that describes six channels, and the tag a WAV or CAF
carries for the same six speakers frequently is not one of them. So
`AudioEncodeSupport` asks CoreAudio which layouts, sample rates and bitrates the
encoder will take — `kAudioFormatProperty_AvailableEncode*`, the same tables the
encoder consults — and translates or clamps *before* anything reaches an output
settings dictionary. Runtime-probed, per format; there is no `#available` in it
and there must never be one.

#### Metadata is translated, not copied — artwork included

An MP3 carries ID3 frames, an M4A carries iTunes atoms, and `AVAssetWriter`
writes only what the destination understands: hand it an `id3/TIT2` while writing
an `.m4a` and it is dropped without a word. That is how a library ends up
transcoded, smaller and anonymous. So items already in the destination's keyspace
are passed through and everything else is reached through AVFoundation's
*common* keyspace — the one place an ID3 title and an iTunes title are the same
fact — and re-emitted under the destination's own identifier, with the cover art's
data type sniffed from its magic number so a PNG sleeve is not tagged as a JPEG.
`result.carriedArtwork` is reported separately from the item count, because it is
the one loss a user sees instantly across a whole library.

Audio artwork classifies as `MetadataClass.thumbnails`, so `.strip([.thumbnails])`
is the one policy that removes a cover; `.preserveAll` and every targeted strip
keep it.

#### Chapters are not preserved, and say so

An audiobook's chapters are a separate text track plus a track association, not
metadata items, and carrying them needs a second muxed input. **This transcoder
does not do it.** Rather than losing them quietly, chapters are counted before
the encode and reported as `result.droppedChapterCount`, with a log line;
`AudioInspector` reports the same count beforehand, so a library pass can skip
chaptered files instead of flattening them.

#### Opus is refused, not substituted

AVFoundation decodes Opus and has no encoder for it on any Apple platform. Naming
an `.opus` destination is refused **by name**, with a message saying why and what
to ask for instead. Quietly writing AAC into a file the caller asked to be Opus
would be worse than refusing — the request was made for a reason. MP3 and FLAC
destinations are refused the same way and for the same reason.

> **What AVFoundation does that a bitrate looks like it should predict:**
> `AVEncoderBitRateKey` is a target under AVFoundation's default *variable* rate
> strategy, not a promise. Asked for 128 kbit/s, its AAC encoder writes a 440 Hz
> sine wave at about 30 — which is correct behaviour and makes the request a
> ceiling. The lossy-source rule therefore compares the requested ceiling against
> the source's measured rate, which errs toward *not* re-encoding; what the file
> actually came out at is read back from it and reported as
> `result.destination`.

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

### Document page counting

`DocumentInspector` answers "how many pages is this" for a PDF and for a
ZIP-based comic archive, without decoding a page.

```swift
let pages = try DocumentInspector().pageCount(of: comic)   // 24, not 8_640
let info  = try DocumentInspector().inspect(comic)
info.kind                 // .pdf or .comicArchiveZIP, from the file's bytes
info.excludedEntryCount   // archive members that are not pages
```

**An animated page is one page**, and that rule is what the whole type is
arranged around. A comic archive of 30 animated GIFs counted by *frames* reports
900 pages, and 900 does not read as a counting bug to whoever sees it — it reads
as a corrupt file or a broken import, so it gets investigated in the decoder, the
download and the database, and not in the one line of arithmetic that produced
it. So archive **entries** are counted and never opened: nothing here calls
`ImageInspector` or any decoder. The happy side effect is cost — the answer comes
from the central directory at the end of the archive, so a 2 GB archive costs
what a 2 MB one costs — and the provable one is that a page whose bytes are
corrupt still counts, because the count is of pages the archive *claims*. For a
PDF the answer is `PDFDocument.pageCount`, and a page containing an animated
XObject is still one page precisely because nothing inspects page content.

What is excluded from an archive, in order of how quietly it goes wrong:

- **`__MACOSX/`** — the parallel AppleDouble tree macOS's own Archive Utility
  writes beside the real files. Its members carry the *same extensions* as the
  files they shadow, so an archive made on a Mac counts **double** without this
  exclusion, and a comic reporting 48 pages instead of 24 still looks like a
  comic. Members whose base name starts with `._` go the same way.
- `ComicInfo.xml`, `.DS_Store`, `Thumbs.db`, `desktop.ini`, and folder entries.
- Anything whose extension does not name an image format. That is an allowlist
  on purpose: a denylist answers "is this one of the junk files I have met", and
  the next reader-specific sidecar is a page under it.

**Zero and "not a document" are different answers.** An empty archive has 0
pages, which is correct and ordinary; a `.txt`, or a `.cbr` (which is RAR, not
ZIP), therefore throws rather than also returning 0 — "the comic is empty" and
"this is not a comic" lead to opposite recoveries. The type is decided from the
file's first bytes, never its extension, because a `.cbz` that is really a RAR is
common enough that every comic reader handles it.

The ZIP reader is Lathe's own, in 200 lines: Foundation has no public ZIP
*reader* on either platform — `NSFileCoordinator`'s `.forUploading` intent writes
one and does not read one — so the choice was this or a third-party package, and
the licence policy makes every dependency a decision. It walks the central
directory, handles ZIP64 (an archive of more than 65535 entries otherwise reports
its count modulo 65536, which is a wrong number rather than a failure, so it gets
believed), and decompresses an entry only when something actually asks for its
bytes — through the system Compression framework, whose `COMPRESSION_ZLIB` is
raw DEFLATE and is exactly what ZIP method 8 stores.

### Searchable PDFs

`PDFTextLayerWriter` runs Vision's on-device OCR over a PDF, an image, or a comic
archive and writes a PDF with an **invisible** text layer: the page looks
identical and selects, searches and copies.

```swift
let result = try await PDFTextLayerWriter().addTextLayer(source: scan, to: searchable)
print(result.pagesRecognised, result.pagesSkipped, result.textRunCount)
```

**The geometry is the part that goes wrong silently.** Vision reports normalised
coordinates with the origin at bottom-left; PDF user space is also bottom-left,
which makes the mapping look like a multiplication — and it is not, because a PDF
page carries a `/Rotate` that a viewer applies and a content stream does not, and
a MediaBox whose origin is legally non-zero. Get either wrong and the text lands
somewhere other than under its glyphs, which is *invisible by construction*: the
page still looks perfect, and the only symptom is somebody searching a document
months later and finding nothing.

So the problem is removed rather than compensated for. **Each output page is
emitted normalised** — MediaBox `(0, 0, w, h)` at the size a viewer sees — and
the source page is drawn into it through
`CGPDFPage.getDrawingTransform(_:rect:rotate:preserveAspectRatio:)`, the one API
that already knows about both the rotation and the box origin. The rotation is
baked into the content instead of carried as a key, and the text layer's
coordinates are then `normalised × pageSize`, against a frame both halves agree
on. The suite asserts this by rendering the finished page, finding the bounding
box of its *dark pixels*, and checking the word's selection rectangle lands
inside it — for `/Rotate` 0, 90, 180 and 270, on a page whose MediaBox origin is
`(36, 72)`.

Runs are drawn with `CGContext.setTextDrawingMode(.invisible)` — PDF render mode
3, `3 Tr` in the content stream, which the suite reads back out of the decoded
stream rather than taking on trust. Mode 3 is the one that renders nothing and
still leaves the glyphs available to extraction; a transparent fill would look
right and not survive a flatten, and white-on-white is visible the moment the
page behind it is not white. Each run is set in Helvetica at roughly its observed
box height and stretched horizontally to that box's width, so a reader's
selection rectangle lands on the glyphs.

Four more things it refuses to get wrong:

- **A born-digital PDF is skipped by default.** Re-OCR'ing one adds a *second*
  text layer that does not line up with the first: every search then finds each
  word twice and copy-paste comes out interleaved, and the page still looks
  perfect. The threshold is not zero characters, because a scan routinely carries
  a stamped page number that would otherwise count as "this page has text".
- **A cancelled run leaves no output.** The document is built in a sibling
  temporary file and moved into place only when complete, so a previous file at
  the destination survives — same rule as `ImageEncoder` and `VideoTranscoder`.
- **Words keep their spaces.** Each run is its own text object and PDF extraction
  invents no separator between two of them, so a per-word layer without a
  deliberate trailing space comes back out of `PDFDocument.string` as one
  unbroken word. The space is drawn but not measured, so the horizontal stretch
  still matches the word's own box.
- **Languages are probed, not assumed.** Handing `VNRecognizeTextRequest` one
  language this system does not know makes `perform` throw and takes the whole
  document with it, and the supported set varies by recognition level, by
  revision and on iOS by which assets the device has. `VisionTextSupport` asks
  and narrows the request to what will actually be accepted; a wish list that
  resolves to nothing becomes "let Vision choose" rather than a failure. There is
  no `#available` in that file, by the same rule `EncodeSupport` follows.

One cost, stated rather than discovered: **annotations do not survive.**
`CGContextDrawPDFPage` draws a page's content stream, and links, form fields and
comments are not content. For scans, photographs of pages and comic archives
there are none; for a born-digital PDF there often are, which is one more reason
the skip is on by default — but a document with annotations is not what this
writer is for.

### Running Python on device

**`LatheFetch` embeds a real CPython interpreter, and installs pure-Python
packages the user asks for.** It is a separate product; see
[Linking contract](#linking-contract) for why.

The premise is narrow and worth stating: some ecosystems are too large to
reimplement. A site-extraction library carries a couple of thousand
site-specific extractors and rewrites them as the sites change; porting that to
Swift means inheriting the churn permanently. Running the real thing does not.
Nothing in this module knows anything about downloading — it is the runtime such
a thing would run *in*.

```swift
import LatheFetch

let runtime = try PythonRuntime.bootstrap(.discovered())
print(runtime.platform.diagnosticReport)      // what this interpreter is, and cannot do

try runtime.evaluate("sum(range(10))").value.int           // 45
try await runtime.executeDetached("print('hi')")           // off the cooperative pool

let packages = PythonPackageInstaller(runtime: runtime, root: applicationSupport)
try runtime.useTrustStore(try await packages.installTrustStore())   // Python's TLS anchors

let plan = try await packages.plan(for: "gallery-dl")      // six packages; show it to someone
try await packages.install(requirement: "gallery-dl")      // and its whole dependency graph
try await packages.activate()                              // on sys.path
try runtime.importModule("gallery_dl")
```

Eight things in it are not obvious, and each is a trap that was hit:

**There is one interpreter per process, and it is never torn down.**
`Py_Initialize` runs once and `Py_Finalize` is not reliably re-entrant, so
`PythonRuntime` has **no public initialiser and no `shutdown()`** — only a static
`bootstrap` returning a shared instance. Calling it again with a different
`PYTHONHOME` throws rather than pretending to honour it. The constraint is in the
API's shape instead of in a comment someone has to find.

**Every entry point takes the GIL, and calls may arrive from anywhere.** No Swift
lock guards execution — serialising in Swift as well would defeat the
interpreter's own concurrency, since Python drops the GIL around blocking I/O,
which is exactly when a second caller should run. Concurrent calls therefore
genuinely interleave, which is why **captured output is thread-local**: two
callers printing at once must not harvest each other's lines. Only the short
hand-off of a call's source and arguments is serialised, and the lock ordering
there (handoff before GIL, never the reverse) is what keeps it from deadlocking
against a caller already inside Python.

**`PYTHONHOME` is validated before initialisation, not after.** CPython's answer
to an unfindable standard library is `Py_FatalError` and `abort()` — on a device
that is a crash report rather than an error anyone can catch. `PythonLayout`
therefore checks for the actual landmark (`lib/pythonX.Y/os.py`, the file
CPython's own path calculation looks for) and throws a catchable
`PythonError.invalidLayout` first. An empty `lib/python3.13` passes a
directory-exists check and still aborts, which is why the check is for the file.

**`sys.stdout` and `sys.stderr` are captured, not left on file descriptors 1 and
2.** Those descriptors go nowhere on a device, and print output is most of what
makes an embedded interpreter debuggable. `execute` returns what the call
printed; `drainBackgroundOutput()` returns what Python's *own* threads printed,
from a bounded buffer.

**Errors arrive as Swift errors carrying the Python traceback**, with Lathe's own
driver frame trimmed off so the trace starts at the caller's first line.
`PythonException` has `type`, `message`, the formatted `traceback`, and whatever
the code printed before it raised.

**Dependencies are resolved transitively, and markers are honoured.** "Install
gallery-dl" is six packages: it needs `requests`, which needs `urllib3`,
`certifi`, `idna` and `charset-normalizer`. `PythonDependencyResolver` walks that
graph from each wheel's own `METADATA`, picks a version satisfying every
constraint collected for each package, detects cycles, and **skips what is
already installed at a satisfying version** — reading that package's own
requirements off disk rather than assuming its subtree is fine. Environment
markers decide inclusion, which is not a detail: `requests` declares `PySocks`
and `chardet` only under extras, and a resolver that ignores `; extra == "socks"`
installs packages nobody asked for. A plan is produced **before anything is
written**, so a graph that cannot be satisfied fails with nothing installed
rather than leaving a half-set that imports until it does not. It is not a
backtracking solver and does not pretend to be: a conflict fails by name, with
the path that reached it — `nothing satisfies urllib3>=2,<2.1 (via gallery-dl →
requests → urllib3)` — because the alternative to a clear failure is a silent
wrong install.

**A compiled dependency is named, not merely detected.** The refusal below
applies to the whole graph, and it says *which* package in it was the compiled
one and how the graph got there. "A wheel was compiled" cannot be acted on;
"gallery-dl needs X, which is compiled" can.

**Python's TLS has no anchors until something gives it some.** The OpenSSL inside
an embedded CPython was built against paths that do not exist in an application
sandbox, so every Python-side HTTPS request fails certificate verification — a
safe failure, and a total one. `PythonTrustStore` solves the apparent
chicken-and-egg (fetching a CA bundle needs TLS) by noting that there isn't one:
**Swift fetches it and Python never does.** `URLSession` uses the system trust
store, so the `certifi` wheel is downloaded and hash-verified by Swift, and the
interpreter is then pointed at the bundle through `SSL_CERT_FILE`. Nothing is
vendored — a CA bundle shipped inside a library would go stale on the library's
release schedule rather than on Mozilla's. The suite asserts the part that is
easy to fake: with the store configured, an **untrusted certificate is still
rejected**, against a TLS server the tests start themselves.

**There are two calling surfaces, and which to use is a real decision.**
`execute`/`evaluate` are synchronous and block the calling thread — right when
the caller is already on a thread of its own. `executeDetached`/`evaluateDetached`
run the interpreter on a dedicated queue and are right from anything `async`,
because a long Python call on a cooperative thread starves the pool exactly as a
long encode does. Cancelling the enclosing `Task` asks CPython to raise
`KeyboardInterrupt` in the thread running the call. That request is
**cooperative and lands at a bytecode boundary**, which is documented rather than
glossed: a pure-Python loop stops in milliseconds, a C extension blocked in a
syscall does not stop at all, and Python that catches `BaseException` broadly
swallows it exactly as it swallows a user's ^C.

#### PEP 730: what does not work on iOS, and is not papered over

iOS does not let a process spawn another. `os.fork` and `subprocess` raise, and a
great deal of published Python shells out — to `ffmpeg`, to `curl`, to itself.
`LatheFetch` **does not shim any of that**. What it does is make the failure
legible: `PythonException.isPlatformRestriction` is true for those cases, and the
error text says the call site has to be replaced rather than retried. An
unadorned `OSError` reads like a bug in the Python being run, and it is not one.
`PythonRuntime.platform` reports `hasFork`, `subprocessIsImportable` and
`canSpawnProcesses`, read out of the live interpreter rather than inferred from a
version.

#### The installer refuses compiled wheels, on purpose

A wheel containing a `.so` is rejected at install time with the offending members
named. This is not a missing feature: iOS cannot load a dynamic library that was
not inside the signed application bundle, so a compiled extension downloaded at
run time can never be imported, by any installer. Saying so at install time
beats an `ImportError` three screens later that reads like an application bug.

`install`, `installed()`, `update` and `remove` operate on a directory laid out
exactly like `pip install --target`, so the result is legible to anyone who knows
Python packaging and nothing about Lathe. Downloads are checked against the
index's published SHA-256 **at the transport boundary**, so unverified bytes
never reach the installer at all, and a file published without a hash is refused
rather than trusted.

**Nothing installed this way is distributed by Lathe.** No wheel, no mirror, no
default set, no install-on-first-use. The user, at run time, on their own device,
from an index they chose. That distinction is the whole reason the installer
exists rather than a `Resources/` directory with some wheels in it, and it is
what keeps the licence policy below true whatever a user installs.

#### Acquisition

There is no CPython in this repository and none is downloaded to build or test
it. `LatheFetch` resolves fifteen stable-ABI symbols with `dlsym` against
whatever CPython the process has — the `Python.framework` an iOS app embeds, or
the host's framework build on macOS. `Sources/LatheFetch/VENDORING.md` records
the pinned upstream release and its SHA-256, why this route rather than a SwiftPM
`binaryTarget` (the short version: the standard library lives *beside* the
xcframework's slices, and a binary target cannot deliver it), the refresh steps,
and exactly what a consumer has to do.

### Downloading media with yt-dlp

**`LatheFetch` runs `yt-dlp` on device.** Not a reimplementation and not a
bundled copy: the real project, installed at run time by the installer above,
driven through a Swift surface shaped like the rest of the package.

```swift
let fetcher = MediaFetcher(runtime: runtime, installer: packages)

try await fetcher.install()                       // yt-dlp + yt-dlp-ejs, two pure wheels
let readiness = try await fetcher.prepare()       // wires up the JS solver
print(readiness.report)                           // and says what works here

let listing = try await fetcher.listing(for: url) // every rendition the extractor found
let selection = try FormatSelector.select(from: listing, policy: .upTo(height: 1080))
let media = try await fetcher.download(selection, from: listing,
                                       to: destination, progress: handle)
media.wasMuxed          // whether two streams were joined to make this
```

Three things make this harder than running a gallery downloader, and each has a
specific answer.

#### 1. `ffmpeg` cannot be called, so the merge happens in Swift

YouTube serves high-quality video and audio as separate streams. `yt-dlp` merges
them by shelling out to `ffmpeg`, and PEP 730 removes process spawning on iOS.

The cheap answer is to constrain format selection to renditions that are already
muxed. **It is a much worse answer than it sounds, and the measurement is worth
having:** against `yt-dlp` 2026.8.19, a 4K test video returned **53 renditions
from the default client set, not one of which carried both tracks**. Forcing an
older client shape surfaces exactly one — format `18`, 360p H.264/AAC — and that
is the entire pre-muxed catalogue. The 720p progressive format this fallback used
to be worth having is gone.

So it is the floor, not the answer. `FormatPolicy.preMuxedOnly` selects it, and
`MediaFetcher.preMuxedCapableYouTubeClients` names the clients that still publish
one, because against the *default* clients a pre-muxed policy finds nothing at
all.

The real path is `StreamMuxer`: `yt-dlp` downloads the two streams separately —
one concrete format id per call, never a `+` expression, which is what keeps
`yt-dlp`'s merger unreachable — and `AVAssetWriter` joins them. **Nothing is
re-encoded.** Reader and writer are both in passthrough (`outputSettings: nil`),
so the encoded samples are written through unchanged; re-encoding a stream that
was downloaded thirty seconds ago costs time and a generation of quality in
exchange for nothing. The test asserts the codec four-character code *and the
total encoded byte count* survive, because a transcode can land on the same codec
and cannot land on the same sample sizes.

Two hazards are worth naming. Driving a two-input `AVAssetWriter` by polling
`isReadyForMoreMediaData` **deadlocks silently** — one input goes not-ready and
never returns, the writer stays `.writing` and reports no error; the fix is one
`requestMediaDataWhenReady` pump per input, as in `LatheVideo`. And an MPEG-4
file will not hold VP9 or Opus, so the pair is chosen from codecs it will hold —
otherwise the failure arrives *after* both streams have been downloaded.

#### 2. YouTube needs a JavaScript runtime, and gets JavaScriptCore

Since late 2025 `yt-dlp` solves YouTube's player challenges by running a
JavaScript program in `deno`, `node`, `bun` or `quickjs` — discovered on `PATH`
and started as a subprocess. All four are unavailable here.

`JavaScriptCore` is a system framework on both platforms, needs no subprocess and
no entitlement. `LatheFetch` registers a challenge provider backed by it, so the
solver runs in a `JSContext` with a `console.log` shim and nothing else — which
is all the program wants, since it stubs its own browser globals.

**The measurement, because the JIT is not available to an ordinary iOS app.** A
~3.0 MB YouTube player plus a batch of `n` and signature challenges, on an Apple
silicon Mac:

| | |
|---|---|
| JIT enabled | ≈0.24 s |
| interpreter only | ≈1.6 s |

Seven times slower and still fine: this runs once per player per session, and
`yt-dlp` batches every challenge for an item into a single solve.
`JavaScriptEngine.benchmark` exists so the claim can be re-checked on a real
device rather than inherited from this table.

**This is the most fragile joint in the feature, and it is pinned and named.**
The provider subclasses `EJSBaseJCP`, which lives under `yt_dlp.extractor.youtube
.jsc._builtin` — a **private** module; `yt-dlp`'s own `jsc/README.md` names only
`…jsc.provider` as public. Using solely public API would mean reimplementing
several hundred lines of script sourcing, version checking, hash verification and
caching, which would go stale *silently*; subclassing the private base goes stale
**loudly, at import**. `MediaFetcherDriver.developedAgainstVersion` records the
release it was written against, and when it breaks `readiness()` reports the
solver as unavailable with the reason while everything except
signature-protected YouTube keeps working.

#### 3. `pycryptodomex` is a C extension, and is never installed

`yt-dlp` prefers it for AES and falls back to its own pure-Python implementation
when it is absent — `yt_dlp/aes.py` branches on `Cryptodome.AES` and nothing hard
-requires the C module. Since iOS can never load a run-time-installed extension,
the fallback is the permanent state, and `Readiness.cryptographyBackend` reports
it so a slow AES-128 HLS decrypt is a known property rather than a mystery. The
cost beyond speed is the handful of extractors that want RSA or CMAC rather than
AES.

Note that `yt-dlp`'s own packaging already excludes `brotli` on
`sys_platform == "ios"`, and that its base `dependencies` array is **empty** —
everything is an extra. So the install is two pure-Python wheels with no
transitive graph at all.

#### Installed, not bundled — and the reason is maintenance, not licence

`yt-dlp` is public domain (the Unlicense), so bundling it would be legally
unencumbered. It is installed anyway because **`yt-dlp` breaks weekly**: sites
change their players and their token schemes, and a copy inside an application is
stale the day it ships and staler every day after — with an App Store review
cycle standing between a user and a fix that was not the application's.
Installing it means the fix is thirty seconds away, through the same code path
that installed it.

Bundling remains legitimate for an offline-first consumer, and is supported:
`PythonPackageInstaller.install(wheel:named:verifying:)` takes bytes already in
memory, so an application can ship a wheel in its bundle and install it with no
network. What it buys is a first launch that works on a plane; what it costs is
that the copy goes stale, and on these sites stale means broken. **This is the one
place the treatment differs from `gallery-dl`, and the difference is maintenance,
not licence.**

#### What a download guarantees

Every byte goes into a working directory beside the destination, and the
destination is written exactly once — by a move, or by the muxer. A cancellation,
a network failure or a crashed extractor leaves the destination as it was found:
absent, or, when retrying over an existing file, intact rather than truncated.
Cancellation is carried on the progress callback's return value, the same
contract `ProgressSink` already has, which makes `yt-dlp` raise its own
`DownloadCancelled` and unwind through the paths it already has for a user
pressing `^C`.

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

Everything else — PDF *image recompression*, comic archive recompression,
animation recompression, the lossless metadata rewrite — is an API surface with
throwing stubs. That is deliberate: the shapes are reviewable now, and filling
them in does not move anyone's call sites.

### Tests

**No binary media is committed to this repository.** Every clip the suite needs —
solid-colour and split-colour video at a known size and frame rate, tracks of
silence, of a continuous tone, and of 0.2 s of tone inside a minute of silence,
AAC files at a known bitrate with iTunes tags and cover art, multi-channel PCM
with a real channel layout, plus audio-only and deliberately-not-media files — is
synthesised at run time by `AVAssetWriter` and `AVAudioFile`. Fixture properties are therefore known by
construction rather than measured from a file somebody once made, and there is
nothing whose provenance has to be explained. A machine that cannot generate a
given clip records a known issue naming the reason instead of quietly passing.

Anything asserting about **size** uses deterministic white noise rather than a
tone, and the reason is a bug this caught: a sine wave is the easiest signal a
psychoacoustic model will ever meet, so AVFoundation's AAC encoder writes one at
a quarter of the bitrate it was asked for. A size test built on a tone measures
the encoder's opinion of sine waves. The AAC fixtures also pin
`AVEncoderBitRateStrategyKey` to constant, so a fixture's bitrate is what it was
told to be rather than a ceiling it may come nowhere near.

The document fixtures go one step further and write their **ZIP archives by
hand**, stored-method, with a real CRC per entry. Asking the system to zip a
folder cannot reliably produce the members that matter — a `__MACOSX/._page.jpg`
resource fork, a bare directory entry, a deliberately corrupt page — and those
are exactly what the page-counting rules are about, so the archives contain
precisely what each test claims they contain. The same goes for the PDFs: a
`/Rotate` of 90 on a page whose MediaBox origin is `(36, 72)` is not something
`CGPDFContext` can even express, so those pages are written with Core Graphics
and rotated with PDFKit.

The Python suite follows the same rule with the same reasoning. **No wheel is
committed either**: the archives it needs — a pure one, one with a `.so` in it
whose filename claims otherwise, one with a `../` member, one that is ZIP64 by
its sentinel — are assembled byte by byte at run time, stored-method, with a real
CRC per entry. No packaging tool will produce those on request, and they are
precisely what the installer's refusals are about. The interpreter tests need no
fixture at all; they need a CPython, and say so when there is none.

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

**What is bound but not linked: CPython.** `LatheFetch` embeds a Python
interpreter, and there is no CPython in this repository — fifteen stable-ABI
symbols are resolved at run time against a framework the *application* supplies.
CPython is PSF-2.0 and the Apple build scripts are BSD-3-Clause, both permissive
and GPL-compatible. An application that embeds the framework is distributing
CPython and inherits the notice obligation; one that uses the host's interpreter
on macOS is not. `Sources/LatheFetch/VENDORING.md` has the pinned release, the
checksum and the reasoning.

**Packages a user installs at run time are outside this policy, by
construction.** `PythonPackageInstaller` distributes nothing: no wheel is
bundled, mirrored, cached or defaulted, and every install is something a user
asked for from an index they chose. Their licences bind that user, not this
package — which is exactly why the installer exists rather than a `Resources/`
directory with some wheels in it, and why the no-GPL rule above survives contact
with an ecosystem this package has no control over.

**Anything that ingests media from a URL stays out of the `Lathe` umbrella.**
Downloaders bring both licence complexity and app-store policy problems, so the
boundary is the **product list**, and `Package.swift` enforces it: such modules
are separate `.library` products and never dependencies of the `Lathe` target, so
the line cannot be crossed by accident during a refactor. `LatheFetch` is the
first module on that side of it — it is the runtime a downloader would be
written in, and contains no downloader itself.

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

Nothing has to be fetched or installed first — including for `LatheFetch`, which
binds CPython at run time rather than at build time. Two environment variables
change what the suite covers:

```sh
LATHE_FETCH_NETWORK_TESTS=1 swift test     # also exercise PyPI. Off by default.
LATHE_PYTHON_HOME=/path/to/framework/Versions/3.13 \
LATHE_PYTHON_LIBRARY=/path/to/libpython3.13.dylib swift test   # pin an interpreter
```

The interpreter tests run against whatever CPython the machine has — Xcode's own
`Python3.framework` is the last-resort fallback, so in practice they run
everywhere — and record a **known issue naming the reason** when there is none,
rather than failing or quietly passing.

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
3. **A third-party dependency comes with a `VENDORING.md`** — whether it is
   vendored as source, linked, or bound at run time: the pinned version, how it
   is acquired and why that route, what a consumer has to do, a refresh script,
   and its licence reproduced in `THIRD-PARTY-NOTICES.md`.
4. **Network ingest gets its own product** and never joins the `Lathe` umbrella.
   See [Linking contract](#linking-contract).

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).
