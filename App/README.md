# Lathe.app

```sh
./App/make-app.sh && open ./App/build/Lathe.app
```

Drop files in, pick what to do, press Run.

- **Compress** — hardware-accelerated re-encode. Video to HEVC, stills to HEIC,
  audio to AAC. Chapters are preserved, and the count is reported.
- **Inspect** — what the file is and what it says about itself. Writes nothing.
- **Strip location** — removes GPS and leaves everything else, **without
  re-encoding**.

It never overwrites: results are written beside the original with a suffix, and a
second run produces a second file rather than replacing the first.

Work goes through the library's own `BulkRun`, so the app inherits its lane
policy rather than inventing one — two videos at a time because the Mac has a
small fixed number of encoders, images scaled to the cores, and the whole pool
shrinking when the machine is hot or on battery.

## Not signed

macOS will refuse the first launch. Right-click → Open, or
`xattr -dr com.apple.quarantine App/build/Lathe.app`. Signing and notarisation
live in the release workflow, which needs a Developer ID this script does not
have.

## No Xcode project, on purpose

The whole repository builds with `swift build`. A `.xcodeproj` would be a second
source of truth for the build that has to be kept in step by hand. A `.app` is a
directory with an `Info.plist` in it, and `make-app.sh` makes that directory.

## The icon is a placeholder, and looks like one on purpose

`make-icon.sh` draws it in code: concentric rings turned down to a centre, a
lathe seen end-on. Drawn rather than committed so there is no binary asset here
and no dependency on a design tool — and so replacing it with a real one changes
nothing else.

## What this is not, yet

**It is not the downloader.** The product this is meant to become fetches media
and hands it to Sami; that needs `LatheFetch`'s Python runtime and a first-run
installer, and none of that is wired up here. What exists today is the
processing half, which is the half that works end to end.
