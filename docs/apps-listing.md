# Lathe, for the apps and support directories

Copy for listing Lathe alongside the other free tools. Written to sit beside
existing entries rather than to be pasted verbatim — trim it to match whatever
shape those pages already use.

## One line

A free Mac downloader: paste a link or browse signed in, and it fetches in the
background.

## Short

**Lathe** — Paste one link or a hundred, or browse to the page signed in as
yourself and take what is on it. Lathe works through them in the background,
with yt-dlp and gallery-dl when a site needs an extractor and by streaming the
URL directly when it does not. Tor routing is built in, for browsing and
downloading alike. Free, open source, and no account.

Requires macOS 26.

## Longer, for a support page

Lathe is two things sharing a name.

The **Mac app** is a downloader. A field at the top takes URLs separated by
spaces or newlines, so pasting a column out of a spreadsheet works without
editing it first. The Browse pane is a real browser with tabs: sign in to a
site once and the downloader can use the same session, which is what makes a
members-only page work at all. Only that site's cookies are ever handed over.

It ships **no extractor**. yt-dlp and gallery-dl are installed on request, into
the app's own folder — nothing outside it is touched and no system Python is
involved. That is what keeps it a tool you assembled rather than one that
arrives with a thousand sites baked in.

The **library** underneath it is an Apache-2.0 Swift package for media work on
Apple platforms: probing, transcoding, images, audio, PDFs and comic archives,
metadata, and chapter preservation — all through the system frameworks, with no
subprocesses, so the same code runs on iOS where launching a binary is not
possible at all. It is the engine inside Sami.

- Free, no account, no upload step.
- Source: github.com/blaineam/Lathe
- Documentation and benchmarks: lathe.wemiller.com

## What it is not

It is not a media converter with a nice interface — that is **Sami**, which is
paid and on the App Store. Lathe hands finished downloads to Sami when both are
installed, and neither needs the other.
