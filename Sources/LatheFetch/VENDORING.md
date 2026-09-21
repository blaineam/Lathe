# CPython, and why none of it is in this repository

`LatheFetch` embeds a real CPython interpreter. It does not contain one, does not
download one at build time, and does not name one in `Package.swift`. This file
records which CPython it is written against, how an application gets that
CPython, and why the obvious routes were not taken.

It is the sibling of `Sources/CWebP/VENDORING.md` and answers the same questions,
but it reaches the opposite conclusion — and the reason it does is the
interesting part.

| | |
|---|---|
| Upstream | <https://github.com/beeware/Python-Apple-support> |
| Release tag | `3.13-b15` |
| CPython | 3.13.15 |
| Published | 2026-09-04 |
| Asset | `Python-3.13-iOS-support.b15.tar.gz` |
| Size | 32,566,713 bytes (~2,900 files unpacked) |
| SHA-256 | `80175765a31babe43b0910395cf86ba4e8412adf1902b069d55b74d523ecc5d1` |
| Minimum iOS | 13.0 |
| Licence | PSF-2.0 (CPython) · BSD-3-Clause (the support project) |
| **Vendored into this repository** | **nothing** |

The floor this code actually requires is **CPython 3.9**, not 3.13: the fifteen C
functions it binds have had these signatures since 3.2, and the latest arrival
among them — `PyUnicode_AsUTF8AndSize` — has been exported since 3.3. 3.13 is
what the pinned release ships and what the suite is developed against; nothing
here breaks on 3.9, which matters because that is the CPython inside Xcode.

## The acquisition route, in one line

**The application acquires CPython; `LatheFetch` binds to it at run time through
`dlsym`.** Fifteen stable-ABI symbols, resolved once at bootstrap, against
whatever CPython the process has: the `Python.framework` an iOS app embedded, or
the host's framework build on macOS.

Consequently `swift build`, `swift test` and
`xcodebuild -destination 'generic/platform=iOS'` all work with nothing fetched,
and this module costs the other five modules nothing.

## Why not a SwiftPM `binaryTarget`

This is the reflex, and it is wrong here for three reasons. The third is the one
that settles it.

**1. SwiftPM cannot consume the published artifact.** A `binaryTarget` takes
either a local path or a remote `.xcframework.zip` plus a checksum. Every
Python-Apple-support release asset is a `.tar.gz`. So a remote binary target is
not available without somebody first repackaging and re-hosting every release —
which means this package would be redistributing a 32 MB build of CPython, taking
on the hosting, the availability and the security-update obligation for it.

**2. A *local* binary target breaks a fresh clone.** SwiftPM validates binary
target paths while loading the package graph, not while building the target that
uses them. An artifact that a script has to produce first therefore makes
`swift build` fail for the whole package until somebody runs that script —
including for `LatheImage` and `LatheVideo`, which have nothing to do with
Python. Making the manifest conditional on the file's existence would fix the
error and replace it with something worse: a package whose product list depends
on the state of the working directory.

**3. The xcframework is not the whole dependency, and a binary target cannot
deliver the rest.** This is the decisive one, and it is checkable in thirty
seconds:

```text
Python.xcframework/
  Info.plist
  ios-arm64/
    Python.framework/            ← the binary and its headers
    lib-arm64/python3.13/lib-dynload/…   ← compiled stdlib extension modules
    platform-config/…
  ios-arm64_x86_64-simulator/…
  lib/python3.13/…              ← the pure-Python standard library: 2,512 files
```

The standard library sits **beside** the slices, not inside them. SwiftPM embeds
a binary target's `.framework` and has no mechanism to place anything else into
an application bundle. A `binaryTarget` on this xcframework therefore delivers an
interpreter with no standard library, and CPython's response to that is not an
error — it is `Py_FatalError` and `abort()` inside `Py_Initialize`. Upstream's own
integration is an Xcode Run Script phase, because copying and individually
codesigning ~2,900 files into a bundle is an application-level job that no
package manifest can express.

So the binaryTarget route is not merely inconvenient here. It is *incomplete*,
and the missing half is the half that makes the interpreter work.

## Why not a `systemLibrary` target

A `systemLibrary` target with a module map pointed at a host-supplied Python is
the other standard answer, and it does work on macOS. It fails the one
requirement that matters:

- **It has no answer for iOS.** A module map needs a header path at *compile*
  time. On iOS the headers are inside an xcframework the application supplies,
  which the package manifest cannot name and no CI runner has. The package must
  build for `generic/platform=iOS` with nothing fetched — that is a standing
  constraint here — and a systemLibrary target cannot.
- **`pkg-config` is not universally available either.** Homebrew's `python@3.x`
  ships `python-3.x-embed.pc`; the CPython inside Xcode does not, and neither
  does an iOS build.
- **It moves a run-time fact to build time.** Whether this machine has a Python
  is not a property of the source; it is a property of the machine, and it can
  change without the source changing. Binding at run time puts the question where
  the answer lives.

## What was chosen, and what it costs

Run-time binding through `dlsym`, in `PythonSymbols.swift`. Three properties earn
it:

- **Nothing is fetched to build or test this package.** The existing suite keeps
  passing on a clean checkout; the Python tests find whatever interpreter the
  machine has and skip cleanly when it has none.
- **It matches the rule this package already runs on.** The README's first
  contributing rule is *no version gating for codec capability — probe at
  runtime and degrade*. "Is there a Python here?" is the same kind of question,
  and `PythonRuntime.bootstrap` answering it with a catchable error rather than a
  link failure is the same kind of answer.
- **The application owns the interpreter, which is where it has to be owned
  anyway.** The embedding, the signing, the stdlib copy and the per-`.so`
  signature are all Xcode build-phase work. Pretending a package manifest owns
  any of it would be a fiction that breaks at the first real build.

The honest costs:

- **The fifteen C signatures are hand-written and unchecked against a real
  header.** Mitigated, not eliminated: every one is stable-ABI and takes only
  `int`, `const char *`, `Py_ssize_t` and opaque `PyObject *` — no struct layout
  is named anywhere, which is the thing that actually changes between CPython
  versions. That constraint is also why interpreter configuration goes through
  `PYTHONHOME`/`PYTHONPATH` rather than PEP 587's `PyConfig`, whose layout is
  explicitly not stable.
- **A missing symbol is a run-time failure, not a link error.** Mitigated by
  resolving all fifteen eagerly at bootstrap and naming the first one missing.
- **Rich C-API work is not available.** Everything beyond the fifteen is done in
  Python, by the driver in `PythonDriver.swift`. That is a real constraint on
  what this module can grow into, and a deliberate one: a line of Python cannot
  be silently wrong about a calling convention.
- **An application that forgets the stdlib build phase gets a crash from CPython
  rather than an error from Lathe** — unless it goes through `PythonLayout`,
  which is why every constructor there validates before anything is initialised.

## Does CI need a fetch step?

**No, and the tests are not hiding behind that.** Plainly:

| | |
|---|---|
| `swift build` | works with nothing fetched |
| `swift test` — the 200 media tests | unaffected |
| `swift test` — the wheel, installer-refusal and layout tests | run with no interpreter and no network |
| `swift test` — the version, marker and dependency-resolution tests | pure functions of fixture `METADATA`; no interpreter, no network |
| `swift test` — the interpreter, detached-call and cancellation tests | run against the host's CPython |
| `swift test` — the TLS verification test | starts its own TLS server; needs `/usr/bin/openssl` to make a certificate, and skips with a known issue when it cannot |
| `xcodebuild -destination 'generic/platform=iOS'` | works with nothing fetched |
| the PyPI tests, including installing `gallery-dl` with its whole graph | **opt-in**, `LATHE_FETCH_NETWORK_TESTS=1` |

The interpreter tests need *a* CPython on the machine. Every Mac that can build
this package has one — Xcode ships `Python3.framework` (3.9) and
`PythonLayout.hostInstalled()` finds it as a last resort — so in practice they
run everywhere. If they cannot, they record a **known issue naming the reason**
rather than failing or quietly passing, which is the same treatment the video
suite gives a machine that cannot encode a fixture. `LATHE_PYTHON_HOME` and
`LATHE_PYTHON_LIBRARY` pin a specific interpreter when the discovered one is not
the one wanted.

What is **not** covered on macOS, and cannot be: the iOS restrictions. PEP 730's
missing `os.fork` and `subprocess` do not exist on a Mac, so the code paths that
report them are exercised only in their reporting form. That gap is real and is
named here rather than left to be discovered.

## Refreshing it

```sh
./fetch-upstream.sh --print-checksum   # download the pinned release, print its hash
./fetch-upstream.sh                    # fetch, verify, unpack into ./.python-apple-support
./fetch-upstream.sh <destination>      # …somewhere else
```

To move to a newer release:

1. Find the current release for the Python series you want at
   <https://github.com/beeware/Python-Apple-support/releases>. The tags are
   `<series>-b<build>`; the assets are per-platform `.tar.gz`.
2. Update `SUPPORT_TAG`, `SUPPORT_BUILD`, `PYTHON_SERIES` and `EXPECTED_SHA256`
   at the top of `fetch-upstream.sh` — the first three by hand, the fourth from
   `--print-checksum`.
3. Put the tag, CPython version, date, asset name, byte count and SHA-256 in the
   table above, and the CPython version in `THIRD-PARTY-NOTICES.md`.
4. `swift test --scratch-path /tmp/lathe-build` — then, against a real device or
   simulator build of an application that embeds the new release, run the
   interpreter suite again. **A macOS-only pass does not tell you the iOS slice
   works**, and this is the step people skip.
5. Read upstream's `VERSIONS` file, reproduced in the table below, for the
   bundled OpenSSL. That is the one whose version genuinely matters to a
   downloader.

**The bundled OpenSSL arrives with no CA bundle**, and no release of it ever
will: the paths it was built to look in do not exist inside an application
sandbox. Python-side HTTPS therefore fails certificate verification until
something supplies anchors, which is what `PythonTrustStore` is for — and note
that the bundle it uses is fetched by `URLSession`, against the *system* trust
store, precisely so that acquiring it does not depend on the thing it fixes.
Nothing here vendors a certificate either.

The pinned release bundles these, built into the framework:

| Library | Version | Licence |
|---|---|---|
| OpenSSL | 3.0.22-1 | Apache-2.0 |
| libFFI | 3.4.7-2 | MIT |
| XZ (liblzma) | 5.6.4-2 | 0BSD |
| BZip2 | 1.0.8-2 | BSD-4-Clause-like |
| mpdecimal | 4.0.0-2 | BSD-2-Clause |

All permissive, which is the licence policy's requirement. Note that none of them
is linked by this package — they are inside the framework the *application*
embeds, and their notices belong in that application's acknowledgements.

## What a consumer has to do

### An iOS application

1. `./fetch-upstream.sh` (or fetch the release by hand).
2. Embed `Python.xcframework` — **Embed & Sign**.
3. Add a Run Script phase that copies `Python.xcframework/lib/python3.13` into
   the bundle as `python/lib/python3.13`, copies the slice's `lib-dynload`
   beside it, and **codesigns each `.so` individually**. iOS requires a
   signature per Mach-O; a single signature over the directory is not enough and
   the failure is an opaque load error at first import. Upstream ships this
   script — use theirs.
4. At launch:

   ```swift
   let runtime = try PythonRuntime.bootstrap(.init(layout: try PythonLayout.inBundle()))
   ```

5. Expect `subprocess` and `os.fork` to raise. See PEP 730, and
   `PythonException.isPlatformRestriction`.
6. Supply a CA bundle before Python touches the network: the bundled OpenSSL
   has none. `installer.installTrustStore()` then `runtime.useTrustStore(_:)`,
   and on later launches `Configuration.trustStore = PythonTrustStore.installed(in:)`.

Lathe's own iOS app is the worked example: `App-iOS/project.yml` links and
embeds the xcframework, and `App-iOS/embed-python.sh` runs upstream's
`install_python` (from the xcframework's `build/utils.sh`) as a Run Script
phase before Embed Frameworks. `Queue.swift` does steps 4 and 6.

### A macOS application or tool

Nothing. `PythonLayout.hostInstalled()` finds the machine's framework build, in
this order: `LATHE_PYTHON_HOME`/`LATHE_PYTHON_LIBRARY`, Homebrew's versioned
kegs, `/Library/Frameworks`, then the `Python3.framework` inside Xcode or the
Command Line Tools.

A *distributed* macOS application should not rely on the host's Python — the user
may have none, or a broken one — and should embed the macOS support release the
same way an iOS app does.

### Anyone

`PythonRuntime.bootstrap` throwing `.interpreterUnavailable` is a normal,
expected outcome. It means "this feature is off on this machine", not "this
application is broken", and it should be handled that way.

## Patches

**None.** Nothing upstream is modified, because nothing upstream is copied. The
only thing this package pins is a URL and a hash.

## Licence

CPython is distributed under the **PSF License Agreement**, which is permissive
and GPL-compatible, and the Python-Apple-support build scripts are
**BSD-3-Clause**. Neither is vendored here, so neither travels with Lathe — but
an application that embeds the framework *is* distributing CPython and inherits
the notice obligation. See `THIRD-PARTY-NOTICES.md` at the repository root, which
is the file a consumer is expected to find.

Packages installed through `PythonPackageInstaller` are a separate matter
entirely, and the distinction is the reason that type exists: they are fetched by
the **user**, at run time, on their own device, from an index they chose. Lathe
does not distribute them, mirror them, or bundle them, so their licences bind the
user and not this package. That is what keeps the no-GPL rule in the README's
licence policy true even when the thing a user installs is not permissively
licensed.
