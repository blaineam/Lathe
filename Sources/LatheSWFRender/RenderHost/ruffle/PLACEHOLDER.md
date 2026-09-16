# This directory is empty on purpose

The Ruffle web build goes here, and it is **not committed** — the same
arrangement `LatheFetch` uses for CPython, and for the same reason. Run:

    Sources/LatheSWFRender/fetch-upstream.sh

which downloads the pinned Ruffle release, checks it against a recorded
SHA-256, and unpacks it into this directory.

`LatheSWFRender` builds, links and passes its whole test suite with this
directory empty — the suite drives the render host against a canvas it animates
itself, so everything except Ruffle is covered either way. What it cannot do
without these files is render a movie, and it refuses by name:
`LatheError.unsupportedOnThisPlatform`, quoting the script above.

See `Sources/LatheSWFRender/VENDORING.md` for the pin, the provenance, the
licence, and the one judgement this is not the place to make.
