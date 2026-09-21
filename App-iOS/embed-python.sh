#!/bin/sh
#
# Xcode Run Script phase: puts CPython's standard library into Lathe.app.
#
# Python.xcframework itself is linked and embedded by project.yml. What a
# framework dependency cannot deliver is everything else CPython needs at run
# time, which the xcframework carries BESIDE its slices:
#
#   Lathe.app/python/lib/python3.13/…          the pure-Python stdlib, where
#                                              PythonLayout.inBundle() looks
#   Lathe.app/Frameworks/<module>.framework     each lib-dynload .so, rewrapped
#   …/lib-dynload/<module>.fwork                as a signed framework, with a
#                                              stub CPython's iOS importer follows
#
# iOS will not load a bare .so from inside an app bundle, so every extension
# module becomes its own signed framework. None of that is written here: it is
# upstream's own `install_python`, shipped inside the xcframework as
# build/utils.sh, exactly as their testbed project calls it.
#
# The xcframework comes from Sources/LatheFetch/fetch-upstream.sh, which
# downloads the pinned beeware/Python-Apple-support release, verifies its
# SHA-256, and unpacks it into .python-apple-support/ (git-ignored).

set -e

# Relative to $PROJECT_DIR (App-iOS), because that is how utils.sh resolves it.
PYTHON_XCFRAMEWORK=../.python-apple-support/Python.xcframework

if [ ! -f "$PROJECT_DIR/$PYTHON_XCFRAMEWORK/build/utils.sh" ]; then
    echo "error: $PROJECT_DIR/$PYTHON_XCFRAMEWORK is missing. Run Sources/LatheFetch/fetch-upstream.sh from the repository root first."
    exit 1
fi

# utils.sh signs each extension framework with the build's identity. An
# unsigned build (CI's CODE_SIGNING_ALLOWED=NO sideload .ipa) has none, and
# `codesign --sign ""` fails; ad-hoc signatures are what the rest of such a
# bundle carries until the sideloading tool re-signs all of it.
if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    export EXPANDED_CODE_SIGN_IDENTITY=-
    export EXPANDED_CODE_SIGN_IDENTITY_NAME="ad-hoc"
fi

# An incremental build re-runs this over a bundle that already holds the
# previous run's extension frameworks. install_stdlib's rsync --delete removes
# the old .fwork stubs and re-copies each .so, and install_dylib moves it into
# the existing framework, so a rerun converges on the same bundle.
. "$PROJECT_DIR/$PYTHON_XCFRAMEWORK/build/utils.sh"
install_python "$PYTHON_XCFRAMEWORK"
