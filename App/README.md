# Lathe (macOS)

A downloader. Paste one URL or a hundred, or browse to a page and take what
is on it, and Lathe fetches them in the background — with `yt-dlp` and
`gallery-dl` when the page needs an extractor, and by streaming the URL
directly when it does not.

It is a front end for the Lathe library, not a separate program: the same
`LatheFetch`, `LatheCore` and metadata code that Sami and the CLI use.

## Building

```
./make-app.sh
```

Writes `build/Lathe.app`. The bundle is **not code-signed**, so the first
launch has to be right-click → Open; after that it opens normally. It is not
notarized either, and deliberately so — see `../DISTRIBUTION.md`.

Requires macOS 26 or newer. The interface is built on Liquid Glass
(`glassEffect`, `GlassEffectContainer`), which does not exist before that.

## What it does

**A queue.** The field at the top takes URLs separated by spaces or
newlines, so pasting a column out of a spreadsheet or a list out of a
message works without editing it first. Each one becomes a row that reports
its own state; the rows run concurrently under a network lane, which is the
same `BulkRun` machinery the library uses everywhere else.

**A browser.** The Browse pane is a real `WKWebView` with a persistent data
store, so signing in to a site once keeps you signed in. "Queue this" hands
the current page to the extractors *along with the cookies for that page's
domain* — which is what makes a members-only or region-locked page work at
all. Only that domain's cookies are exported, never the whole jar.

**A hand-off to Sami.** If Sami is installed and the toggle is on, a
finished download is passed to it for conversion or compression under
whatever preset you have set there. If it isn't, the file just lands in the
download folder.

**Onboarding.** Neither downloader ships inside the bundle. The banner on
first run installs them into an app-private Python environment; nothing is
written outside the app's own container and no system Python is touched.

## What it does not do

It does not download in the clear when the Tor toggle is on. If the proxy is
unreachable the download fails rather than falling back — a downloader that
quietly abandons the proxy it was told to use is worse than one that stops.
