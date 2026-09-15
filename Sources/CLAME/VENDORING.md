# CLAME — LAME, vendored

**This is the only non-permissive code in Lathe.** Everything else in this
package is Apache-2.0 or permissively licensed and can be linked by anything.
LAME is **LGPL**, and this document exists so that depending on it is a decision
somebody made on purpose.

| | |
|---|---|
| Upstream | LAME 3.100 |
| Source | `https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz` |
| SHA-256 | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` |
| Licence | LGPL (GNU **Library** General Public License, v2) — see `upstream/COPYING` |
| Vendored by | `./refresh-upstream.sh` |

## Why there is an LGPL library in here at all

**Apple ships no MP3 encoder.** Every Apple platform decodes MP3; none of them
encodes it. It is the one audio capability in this package that cannot come from
the system, and every usable MP3 encoder in existence is LGPL — LAME, Shine, and
the rest. There is no permissive option to choose instead.

So the choice was: no MP3 encoding, or an LGPL dependency. The answer here is an
LGPL dependency **quarantined behind its own product**.

## How the quarantine works

`CLAME` is only reachable through the `LatheMP3` product. It is not part of the
`Lathe` umbrella, and `LatheAudio` does not depend on it.

That means the licence question is answerable from a manifest rather than from a
binary:

- A package that lists `LatheMP3` in its dependencies links LAME and takes on
  the LGPL obligations.
- A package that does not list it **provably does not link LAME**, because there
  is no other path to it in the dependency graph.

If you are shipping something where that matters, that is the check to make, and
it is a one-line check.

## What the LGPL asks of you, in outline

This is not legal advice, and the obligations depend on how you distribute.
Broadly, the LGPL expects that a user can replace the LGPL library with their own
build of it. The usual ways to satisfy that are to link it dynamically — ship it
as a separate dynamic framework inside the app bundle — or to provide the object
files needed to relink.

**The App Store case is genuinely unsettled and is not this document's to
decide.** Apple's terms and the LGPL's relinking requirement are in tension, and
reasonable people disagree about whether a dynamic framework inside an app bundle
resolves it. If you are shipping to the App Store, get your own answer before
depending on `LatheMP3` — and note that everything else in Lathe is available to
you without this question arising at all.

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
are guarded by `HAVE_XMMINTRIN_H`. On Apple silicon these files compile to
nothing, and leaving them out breaks the build.

**Not taken, and this one is a licence decision rather than a size one:**
`mpglib`, LAME's bundled MPEG *decoder*. It is **GPL** where the encoder is LGPL.
Vendoring it would make this target GPL and take the whole question out of the
consumer's hands. `mpglib_interface.c` is excluded for the same reason. Nothing
here needs it: Apple's own decoder reads MP3.

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

## Updating

```sh
./refresh-upstream.sh 3.100      # or a newer version
swift build && swift test
```

Nothing is patched — every file is copied byte for byte — so a version bump is a
copy, and the only hand-written file is `config.h` above. Update the version and
SHA-256 in the table at the top with what the script prints.
