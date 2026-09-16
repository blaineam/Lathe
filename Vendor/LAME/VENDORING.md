# LAME — vendored as source, shipped as a dynamic framework

**This is the only non-permissive code in Lathe.** Everything else in this
package is Apache-2.0 or permissively licensed and can be linked by anything.
LAME is **LGPL**, and this document exists so that depending on it is a decision
somebody made on purpose.

| | |
|---|---|
| Upstream | LAME 3.100 |
| Source | `https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz` |
| SHA-256 | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` |
| Licence | GNU **Library** General Public License, version 2 or (at your option) any later version — see `upstream/COPYING` |
| Vendored by | `./refresh-upstream.sh` |
| Built by | `Scripts/build-lame-xcframework.sh` → `lame.xcframework.zip` |
| Linked as | `lame.framework`, dynamic, through the `LAME` binary target |

## Why there is an LGPL library in here at all

**Apple ships no MP3 encoder.** Every Apple platform decodes MP3; none of them
encodes it. It is the one audio capability in this package that cannot come from
the system, and every usable MP3 encoder in existence is LGPL — LAME, Shine, and
the rest. There is no permissive option to choose instead.

So the choice was: no MP3 encoding, or an LGPL dependency. The answer here is an
LGPL dependency **quarantined behind its own product, and linked so that it can
be replaced**.

## The arrangement

```
Vendor/LAME/upstream/          the source — pinned, byte for byte, plus config.h
        │
        │  Scripts/build-lame-xcframework.sh
        ▼
lame.xcframework.zip           ios-arm64 · ios-arm64_x86_64-simulator · macos-arm64_x86_64
        │
        │  .binaryTarget(name: "LAME", …)
        ▼
LatheMP3  (static Swift)  ──imports──▶  lame  (dynamic C framework)
```

**The source is not compiled by SwiftPM.** It stays in this repository because
it is the LGPL's *corresponding source*: the build script turns exactly these
files into exactly the framework that ships, with nothing else as input.

**`lame.framework` contains LAME's C and nothing else.** No Swift, no Lathe code.
It exports only the functions `lame.h` declares; LAME's internals are hidden. Its
module is `lame`, and `LatheMP3` is the only thing in this package that imports
it.

**`LatheMP3` is still an ordinary static Swift module.** That is deliberate. If
`LatheMP3` were the dynamic framework it would carry its own copy of
`LatheCore`, the app would link a second one through every other Lathe product,
and Swift would see two unrelated `LatheError` types: `catch let e as LatheError`
would silently stop matching anything the MP3 code throws. Keeping the dynamic
boundary around the C library alone avoids that entirely, and it is also the
boundary the licence cares about.

## Why dynamic

The LGPL (section 6 of v2) lets a proprietary application use the library on
condition that whoever receives the application can replace the library with a
modified version and have the application use it. Compiled in as source, as
this package used to do, LAME is fused into the app's binary and cannot be
replaced without the app's object files. Shipped as its own dynamic framework
inside the app bundle, it can: the app finds it through `@rpath` at launch, and a
framework with the same name and the same exported functions takes its place.

That is the established arrangement for LGPL codecs in Apple apps — ffmpeg-kit's
LGPL builds ship each library as a separate dynamic framework for this reason.

## How the quarantine works

`LAME` is only reachable through the `LatheMP3` product. It is not part of the
`Lathe` umbrella, and `LatheAudio` does not depend on it.

That means the licence question is answerable from a manifest rather than from a
binary:

- A package that lists `LatheMP3` in its dependencies ships `lame.framework` and
  takes on the LGPL obligations below.
- A package that does not list it **provably does not link LAME**, because there
  is no other path to it in the dependency graph.

## What an app shipping this must do

This is not legal advice, and the obligations depend on how you distribute. What
follows is what the arrangement above is designed to make possible.

1. **Embed `lame.framework`; do not link LAME statically.** Xcode does this for
   you when an app target depends on `LatheMP3`: the framework is copied to
   `Frameworks/` and re-signed with the app's identity. Do not rebuild LAME into
   your own binary, and do not merge it into another framework.
2. **Include the licence text.** `COPYING` travels inside the framework
   (`lame.framework/COPYING` on iOS, `Resources/COPYING` on macOS), but a user
   cannot be expected to find it there. Put the GNU Library General Public
   License, version 2, in the app's acknowledgements screen or licence file.
3. **Credit LAME.** Say, where a user can see it, that the app uses the LAME MP3
   encoder (<https://lame.sourceforge.io>), that LAME is licensed under the LGPL,
   and which version it is (3.100).
4. **Offer the source.** Point to the corresponding source — this repository at
   the tag the app was built from, `Vendor/LAME/upstream` and
   `Scripts/build-lame-xcframework.sh` — or to upstream's tarball with the
   SHA-256 above, and keep it available. Lathe's copy is unmodified; if you ever
   change it, the change is part of what you must offer.
5. **Do not forbid replacement.** Your own terms must not prohibit a user from
   modifying LAME or from reverse engineering the app to the extent needed to
   debug a replacement.

**The App Store is the case worth thinking about.** Apple's terms and the LGPL's
replacement requirement sit uneasily together, because an App Store app cannot
be re-signed and re-installed by an ordinary user. The dynamic framework, the
shipped licence and the offered source are what the apps that ship LGPL code in
the store do, and they are what this arrangement provides. Whether that is
sufficient for your distribution is your decision to make — and everything else
in Lathe is available to you without the question arising at all.

## How a user replaces the framework

1. Get the source: this repository at the relevant tag. Modify
   `Vendor/LAME/upstream` as you like (keep the functions `lame.h` declares —
   they are the interface the app was linked against).
2. Build it: `Scripts/build-lame-xcframework.sh /some/dir`. It needs only Xcode.
   Out come `lame.xcframework.zip` and its slices, ad-hoc signed.
3. Swap it in: replace `Frameworks/lame.framework` in the app bundle with the
   matching slice (`macos-arm64_x86_64` for a Mac app, `ios-arm64` for a
   device), then re-sign the bundle (`codesign --force --sign - App.app` for a
   Mac app you run locally; a development or ad-hoc profile for a device).

Replacing it was checked on a throwaway Mac app: a build with the minor version
changed to 101 in `version.h`, swapped into the finished bundle and ad-hoc
re-signed, ran and reported `encoder 3.101`.

## And a word on whether you want MP3

AAC beats MP3 at every bitrate and every Apple platform encodes it. The reason to
choose MP3 is compatibility with hardware or services that accept nothing else.
That is a real reason and a narrow one. If the destination understands AAC,
`LatheAudio` produces a better file and no licence question.

## What is vendored, and what is deliberately not

**Taken:** `libmp3lame/` — every `.c` and `.h` except `mpglib_interface.c` — plus
`libmp3lame/vector/` and the public `include/lame.h`.

**`libmp3lame/vector/` is vendored despite being x86-only.** `fft.c` and
`quantize.c` include `vector/lame_intrin.h` *unconditionally*; only its contents
are guarded by `HAVE_XMMINTRIN_H`. With that undefined these files compile to
nothing, and leaving them out breaks the build.

**Not taken, and this one is a licence decision rather than a size one:**
`mpglib`, LAME's bundled MPEG *decoder*. It is **GPL** where the encoder is LGPL.
Vendoring it would make the framework GPL and take the whole question out of the
consumer's hands. `mpglib_interface.c` is excluded for the same reason. Nothing
here needs it: Apple's own decoder reads MP3. `lame.h` still *declares* the
`hip_*` decoder functions; the framework does not define or export them.

Also not taken: the i386 NASM assembly (no assembler in this build, no 32-bit x86
target), the command-line front end, the test programs, the Windows and DOS
project files, and the autotools machinery.

## config.h is written, not copied

LAME expects the header autoconf generates, and this package does not run
autoconf. `refresh-upstream.sh` writes one instead. Three things in it are worth
knowing, because each was found by a build failure that named something else:

1. **`HAVE_XMMINTRIN_H` is absent, not zero.** LAME tests it with `#ifdef`, so
   defining it as `0` still selects the SSE path.
2. **`ieee754_float32_t` and `ieee754_float64_t` are typedef'd here.** autoconf
   appends them when the platform does not declare them, which darwin does not —
   they come from glibc's `<ieee754.h>`. Without them `util.h` does not compile,
   and the error names the type rather than the missing step.
3. **`FLOAT` and `FLOAT8` are NOT defined.** `machine.h` defines them *and*
   `FLOAT_MAX`/`FLOAT8_MAX` alongside — but only inside the `#ifndef FLOAT`
   branch it takes when config.h has said nothing. Defining `FLOAT` skips that
   branch, leaves `FLOAT_MAX` undefined, and the build fails several files later
   complaining about a constant.

## The build script

`Scripts/build-lame-xcframework.sh` compiles every `.c` under
`upstream/libmp3lame` with `-O2 -DHAVE_CONFIG_H`, once per architecture, and
links each set into a dynamic library:

| Slice | Architectures | Minimum | Layout |
|---|---|---|---|
| `ios-arm64` | arm64 | iOS 17.0 | flat bundle |
| `ios-arm64_x86_64-simulator` | arm64, x86_64 | iOS 17.0 | flat bundle |
| `macos-arm64_x86_64` | arm64, x86_64 | macOS 14.0 | versioned bundle (`Versions/A`) |

The minimums are the package's own. Each framework has an `Info.plist`
(`com.lathe.lame`, version 3.100, `MinimumOSVersion` / `LSMinimumSystemVersion`),
`Headers/lame.h`, a module map declaring `framework module lame`, `COPYING`, and
an ad-hoc signature, so it validates as it stands and the embedding app replaces
the signature with its own. No bitcode: it is deprecated, and App Store Connect
refuses it.

Everything is built in a temporary directory, never in the repository — codesign
refuses a bundle carrying the extended attributes a network share stamps.

**The zip is reproducible with the same Xcode.** Source paths are mapped out of
the objects, file times are pinned, the slices in the xcframework's
`Info.plist` are sorted, the archive is written in sorted order, and the ad-hoc
signature carries no timestamp. Three consecutive builds give the same checksum.
A different Xcode is a different compiler and gives a different one, which is
why Package.swift pins the checksum of a *published* asset rather than of a
rebuild.

## Where the zip comes from

`Package.swift` names the binary target `LAME`. Two states:

- **Local** — `path: "Artifacts/lame.xcframework.zip"`. The zip is built by the
  script and ignored by git. A missing binary target fails every build in the
  package, not only `LatheMP3`'s — with Swift 6.4, `swift build --target
  LatheImage` dies with an uncaught `-[NSNull length]` exception rather than
  naming the file — so CI builds the zip before anything else (and uploads it
  as a workflow artifact). Locally:

  ```sh
  Scripts/build-lame-xcframework.sh
  swift build && swift test --no-parallel
  ```

- **Published** — `url:` a GitHub release asset, `checksum:` what the script
  printed. SwiftPM downloads and verifies it; nothing needs building first, and
  the CI steps that build it become no-ops.

## Updating

```sh
Vendor/LAME/refresh-upstream.sh 3.100      # or a newer version
Scripts/build-lame-xcframework.sh
swift build && swift test --no-parallel
```

Nothing is patched — every file is copied byte for byte — so a version bump is a
copy, and the only hand-written file is `config.h` above. Update the version and
SHA-256 in the table at the top with what the refresh script prints. Then
publish the new `lame.xcframework.zip` as a release asset — preferably the one CI
built with a release Xcode — and update the `url:` and `checksum:` in
`Package.swift` to match.
