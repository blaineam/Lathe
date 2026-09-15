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

**A browser, with tabs.** The Browse pane is a real `WKWebView` per tab, with
a persistent data store, so signing in to a site once keeps you signed in and
switching to Downloads and back finds the page as you left it. Each tab owns
its web view; that is what makes it survive.

Queueing or downloading from a tab hands the extractor *the cookies for that
page's domain* — which is what makes a members-only page work at all. Only
that domain's cookies, never the whole jar. It also asks whether you want the
one item or everything on the page, rather than guessing: a page in a browser
is as likely to be a gallery or a playlist as a single thing.

Tabs can be muted individually, from the tab itself, so a tab that starts
talking can be silenced without switching to it. There is no public API for
muting a `WKWebView` — the supported calls stop playback rather than silence
it — so it is done with an injected script.

**A drop folder.** Lathe watches a folder in iCloud Drive. A one-step Shortcut
on an iPhone's share sheet appends a URL to a file there, and the download
starts on the Mac. Settings → Shortcuts walks through it. Anything else that
can write a file works too: a Mac Shortcut, a script, a dragged `.webloc`.

**A hand-off to Sami.** If Sami is installed and the toggle is on, a
finished download is passed to it for conversion or compression under
whatever preset you have set there. If it isn't, the file just lands in the
download folder.

**Onboarding.** Neither downloader ships inside the bundle. The banner on
first run installs them into an app-private Python environment; nothing is
written outside the app's own container and no system Python is touched.

**Tor, built in.** The Tor client is linked into the app; turning routing on
starts it and both browsing and downloading go through it. There is nothing to
install, and no subprocess — `tor_run_main` runs on a thread, which is the
arrangement that also works on iOS where a bundled binary could not be
launched at all.

The framework it links is a release asset rather than a file in this
repository: `App/Vendor/Tor/slim-tor.sh` fetches upstream's build and slims it
from 335 MB to about 15 MB by dropping everything that is not arm64 and
removing debug information. Without it the app still builds and Tor routing
falls back to an external proxy.

## What it does not do

It does not download in the clear when the Tor toggle is on. If the proxy is
unreachable the download fails rather than falling back — a downloader that
quietly abandons the proxy it was told to use is worse than one that stops.

Readiness means a real connection *through* the proxy, not a handshake with
it. Tor opens its SOCKS port about a second after launch and cannot carry
anything for a minute after that, so a check that stopped at the handshake
would report "Connected" while every download failed.

It is also not anonymity, and says so in Settings: it is the same browser with
the same logins in it, so a site you are signed in to knows exactly who you
are wherever the packets came from.
