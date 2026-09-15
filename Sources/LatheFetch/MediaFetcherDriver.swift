import Foundation

/// The Python half of the `yt-dlp` surface.
///
/// The same arrangement as ``PythonDriver``, for the same reason: everything
/// that would need more of the C API than the fifteen symbols this package
/// binds is written in Python, once, in an audited blob, rather than
/// reconstructed from `PyObject_CallMethod` at every call site.
///
/// Four jobs here, and each one is a thing Swift cannot do directly:
///
/// 1. **Construct `YoutubeDL` with options that never reach `ffmpeg`.** The
///    hazard is subtle and is documented at ``format`` below.
/// 2. **Register a JavaScript challenge provider** backed by
///    ``JavaScriptEngine``, so YouTube's signature challenges can be solved
///    without the subprocess PEP 730 forbids.
/// 3. **Bridge `yt-dlp`'s progress hooks**, which are Python callables, back
///    into a Swift ``ProgressHandle`` — and carry the cancellation answer in
///    the other direction.
/// 4. **Serialise the info dictionary** into the JSON shape `MediaListing`
///    decodes, which is the same shape `yt-dlp --dump-json` prints.
enum MediaFetcherDriver {

    /// Installs the module. Idempotent — running it twice rebinds the
    /// addresses and re-registers nothing.
    static let installExpression = "_lathe_ytdlp_installed()"

    static let bindFunction = "_lathe_ytdlp_bind"
    static let registerProviderFunction = "_lathe_ytdlp_register_provider"
    static let extractFunction = "_lathe_ytdlp_extract"
    static let entriesFunction = "_lathe_ytdlp_entries"
    static let extractorFunction = "_lathe_ytdlp_extractor"
    static let downloadFunction = "_lathe_ytdlp_download"
    static let readinessFunction = "_lathe_ytdlp_readiness"

    /// What `yt-dlp` release this provider was written against.
    ///
    /// The JavaScript-challenge provider subclasses `EJSBaseJCP`, which lives
    /// under `yt_dlp.extractor.youtube.jsc._builtin` — a **private** module
    /// whose own public sibling says so: `jsc/README.md` names
    /// `yt_dlp.extractor.youtube.jsc.provider` as the public API and everything
    /// else as internal, with no stability guarantee.
    ///
    /// Subclassing it anyway is a considered trade. The public
    /// `JsChallengeProvider` leaves `_real_bulk_solve` abstract, so using only
    /// public API means reimplementing the solver-script sourcing, version
    /// checking, hash verification, caching and response marshalling — several
    /// hundred lines of someone else's logic, reproduced, which would go stale
    /// *silently*. Subclassing the private base goes stale **loudly**, at
    /// import, with a name in the traceback.
    ///
    /// This is the most fragile joint in the whole feature and it is named
    /// here rather than buried. When it breaks, ``MediaFetcher/readiness()``
    /// reports the JavaScript provider as unavailable with the reason, and
    /// everything except signature-protected YouTube keeps working.
    static let developedAgainstVersion = "2026.08.19"

    static let source = #"""
        # Lathe's yt-dlp glue. Installed once per process by LatheFetch's
        # MediaFetcher; not intended to be imported by hand.
        #
        # Everything here returns a JSON string and raises nothing that Swift
        # cannot name. The one deliberate exception is the download path, which
        # lets yt-dlp's own exceptions propagate so that PythonException carries
        # the real traceback into MediaFetchError.mapping.
        import json
        import os
        import sys
        import threading

        _LATHE_YTDLP = {
            "js_evaluate": None,
            "js_free": None,
            "progress": None,
            "provider_registered": False,
            "provider_error": None,
            "ctypes_error": None,
        }


        def _lathe_ytdlp_installed():
            return "ok"


        # ------------------------------------------------------------------
        # The Swift call path
        #
        # Addresses rather than symbol names: see JavaScriptBridge in Swift for
        # why dlsym is not dependable for a static library linked into an app.
        # ctypes.CFUNCTYPE releases the GIL for the duration of the call, which
        # is what we want — nothing on the Swift side touches the Python C API,
        # so holding it would only stall the interpreter.
        # ------------------------------------------------------------------

        def _lathe_ytdlp_bind():
            args = lathe_arguments
            try:
                import ctypes
            except Exception as exc:  # pragma: no cover - only on a stripped build
                _LATHE_YTDLP["ctypes_error"] = (
                    "this interpreter has no ctypes module, so Swift cannot be called back into. "
                    "The JavaScript challenge solver is unavailable; every extractor that does not "
                    "need one still works. (%s)" % exc)
                return json.dumps({"ok": False, "error": _LATHE_YTDLP["ctypes_error"]})

            evaluate_proto = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_char_p)
            free_proto = ctypes.CFUNCTYPE(None, ctypes.c_void_p)
            progress_proto = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p)

            _LATHE_YTDLP["js_evaluate"] = evaluate_proto(int(args["evaluate"]))
            _LATHE_YTDLP["js_free"] = free_proto(int(args["free"]))
            _LATHE_YTDLP["progress"] = progress_proto(int(args["progress"]))
            _LATHE_YTDLP["ctypes"] = ctypes
            return json.dumps({"ok": True})


        def _lathe_run_javascript(program):
            """Evaluate a JavaScript program in JavaScriptCore. Returns its stdout."""
            evaluate = _LATHE_YTDLP["js_evaluate"]
            if evaluate is None:
                raise RuntimeError("the JavaScript engine is not bound")
            ctypes = _LATHE_YTDLP["ctypes"]
            pointer = evaluate(program.encode("utf-8"))
            if not pointer:
                raise RuntimeError("the JavaScript engine returned nothing")
            try:
                payload = json.loads(ctypes.string_at(pointer).decode("utf-8"))
            finally:
                # In a finally so that a decode failure cannot leak the buffer:
                # this runs once per player per session, but a leak in a process
                # that never restarts is a leak forever.
                _LATHE_YTDLP["js_free"](pointer)
            return payload


        def _lathe_report_progress(payload):
            """Report to Swift. Returns False when the caller asked to stop."""
            hook = _LATHE_YTDLP["progress"]
            if hook is None:
                return True
            return bool(hook(json.dumps(payload).encode("utf-8")))


        # ------------------------------------------------------------------
        # The JavaScript challenge provider
        # ------------------------------------------------------------------

        def _lathe_ytdlp_register_provider():
            """Register a JavaScriptCore-backed JS challenge provider with yt-dlp.

            Returns a JSON report rather than raising: a yt-dlp whose challenge
            solver is missing still extracts from every site that does not need
            one, and turning that into a hard failure would trade most of the
            feature for the loudest possible complaint about part of it.
            """
            if _LATHE_YTDLP["provider_registered"]:
                return json.dumps({"ok": True, "already": True})
            if _LATHE_YTDLP["js_evaluate"] is None:
                return json.dumps({"ok": False, "error": _LATHE_YTDLP["ctypes_error"] or "not bound"})

            try:
                from yt_dlp.extractor.youtube.jsc.provider import (
                    JsChallengeProviderError,
                    register_preference,
                    register_provider,
                )
                # PRIVATE API. See MediaFetcherDriver.developedAgainstVersion.
                from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
                from yt_dlp.extractor.youtube.jsc._registry import _jsc_providers
            except Exception as exc:
                _LATHE_YTDLP["provider_error"] = (
                    "this yt-dlp does not expose the JS challenge provider interface this build "
                    "was written against (%s: %s). Sites that need a JavaScript runtime — which in "
                    "practice means signature-protected YouTube — will not work; everything else "
                    "is unaffected." % (type(exc).__name__, exc))
                return json.dumps({"ok": False, "error": _LATHE_YTDLP["provider_error"]})

            # register_provider asserts on a duplicate key, and this module may
            # be re-run in a process that never restarts, so the registry is
            # checked rather than the local flag alone.
            if "LatheJavaScriptCore" in _jsc_providers.value:
                _LATHE_YTDLP["provider_registered"] = True
                return json.dumps({"ok": True, "already": True})

            try:
                class LatheJavaScriptCoreJCP(EJSBaseJCP):
                    PROVIDER_NAME = "lathe-javascriptcore"
                    PROVIDER_VERSION = "1.0.0"
                    BUG_REPORT_LOCATION = "the application embedding LatheFetch"
                    JS_RUNTIME_NAME = "lathe-javascriptcore"

                    @property
                    def runtime_info(self):
                        # The base class looks the runtime up in yt-dlp's
                        # external-runtime registry, which only ever holds
                        # things found on PATH and started as a subprocess.
                        # JavaScriptCore is neither, so there is nothing there
                        # to find and availability is answered directly below.
                        return None

                    def is_available(self):
                        return _LATHE_YTDLP["js_evaluate"] is not None and self._available

                    def _run_js_runtime(self, stdin, /):
                        result = _lathe_run_javascript(stdin)
                        if not result.get("ok"):
                            raise JsChallengeProviderError(
                                "JavaScriptCore could not run the challenge solver: %s"
                                % (result.get("error") or "no reason given"))
                        _LATHE_YTDLP["last_solve_seconds"] = result.get("duration")
                        return result.get("stdout") or ""

                register_provider(LatheJavaScriptCoreJCP)
                register_preference(LatheJavaScriptCoreJCP)(
                    lambda provider, requests: 10000)
            except Exception as exc:
                _LATHE_YTDLP["provider_error"] = "%s: %s" % (type(exc).__name__, exc)
                return json.dumps({"ok": False, "error": _LATHE_YTDLP["provider_error"]})

            _LATHE_YTDLP["provider_registered"] = True
            return json.dumps({"ok": True, "already": False})


        # ------------------------------------------------------------------
        # Options
        # ------------------------------------------------------------------

        def _lathe_base_options(request):
            """Options every call shares.

            `format` is supplied by the caller and is never omitted. That is not
            tidiness — yt-dlp's `_default_format_spec` decides what "best" means
            by asking whether it can merge, and asking that constructs an
            FFmpegMergerPP and probes for the ffmpeg binary. On iOS the probe is
            a subprocess call, which raises. Passing an explicit format id is
            what keeps that code path unreachable.
            """
            options = {
                "quiet": True,
                "no_warnings": False,
                "noprogress": True,
                "no_color": True,
                "consoletitle": False,
                # No post-processors, ever. Every one of them that matters
                # shells out, and the two this package would otherwise want —
                # the merger and the remuxer — are done in Swift with
                # AVAssetWriter instead.
                "postprocessors": [],
                "prefer_ffmpeg": False,
                # yt-dlp's cache defaults to ~/.cache/yt-dlp, which inside an
                # application sandbox is neither present nor writable. The
                # cache is where the solver script and the player signature
                # timestamps live, so switching it off would mean refetching
                # them on every call.
                "cachedir": request.get("cache_directory") or False,
                "socket_timeout": request.get("timeout") or 30,
                "retries": request.get("retries", 3),
                "fragment_retries": request.get("retries", 3),
                "extractor_retries": request.get("retries", 3),
                "ignoreerrors": False,
                "logtostderr": False,
                "check_formats": False,
                # Nothing beside the media file. A downloader on a device has no
                # use for a .info.json or a thumbnail sidecar, and writing them
                # would mean a "partial file" that is not the one being watched.
                "writeinfojson": False,
                "writethumbnail": False,
                "writesubtitles": False,
                "overwrites": True,
            }
            if request.get("user_agent"):
                options["http_headers"] = {"User-Agent": request["user_agent"]}
            if request.get("extractor_args"):
                options["extractor_args"] = request["extractor_args"]
            # A watch URL that carries a `list` parameter is still a watch
            # URL. YouTube appends an autoplay mix to almost every link it
            # hands out, so without this the ordinary act of copying a link
            # from the address bar and pasting it in resolves to a playlist
            # of fifty related videos and refuses to download anything.
            #
            # Defaulted on: a caller that genuinely wants the playlist asks
            # for it, because that is the rarer intent and the more surprising
            # outcome to arrive at by accident.
            options["noplaylist"] = bool(request.get("no_playlist", True))
            if request.get("cookie_file"):
                options["cookiefile"] = request["cookie_file"]
            if request.get("proxy"):
                options["proxy"] = request["proxy"]
            return options


        # ------------------------------------------------------------------
        # Extraction
        # ------------------------------------------------------------------

        def _lathe_ytdlp_extract():
            import yt_dlp

            request = json.loads(lathe_arguments["request"])
            options = _lathe_base_options(request)
            options["skip_download"] = True
            # Extraction must not be allowed to fall into the default format
            # selector; see _lathe_base_options.
            options["format"] = "all"

            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(request["url"], download=False, process=False)
                if info is not None and info.get("_type") in ("playlist", "multi_video"):
                    entries = info.get("entries")
                    try:
                        count = len(entries)
                    except TypeError:
                        count = -1
                    return json.dumps({
                        "kind": "playlist",
                        "count": count,
                        "title": info.get("title"),
                    })
                # `process=False` is fast but leaves formats unresolved, so the
                # real extraction happens here, once we know it is not a
                # playlist and the work will not be thrown away.
                info = ydl.extract_info(request["url"], download=False)
                sanitised = ydl.sanitize_info(info)

            return json.dumps({"kind": "media", "info": sanitised}, default=str)


        def _lathe_ytdlp_extractor():
            """Which extractor claims this URL, ignoring the generic one.

            yt-dlp's generic extractor is suitable for every URL ever written,
            which makes "does yt-dlp support this" a question with only one
            answer. Skipping it turns the question into a useful one: a named
            extractor means yt-dlp knows the site, and nothing but the generic
            extractor means it will be guessing from whatever the page
            happens to contain.

            That distinction is what lets a caller route a URL between this
            and gallery-dl instead of always picking the same one.
            """
            import yt_dlp

            url = lathe_arguments["url"]
            for candidate in yt_dlp.extractor.gen_extractor_classes():
                key = candidate.ie_key()
                if key == "Generic":
                    continue
                try:
                    if candidate.suitable(url):
                        return json.dumps({"extractor": key})
                except Exception:
                    # A broken `suitable` in one extractor must not decide the
                    # answer for the other two thousand.
                    continue
            return json.dumps({"extractor": None})


        def _lathe_ytdlp_entries():
            """The items inside a playlist, without extracting any of them.

            `extract_flat="in_playlist"` is what makes this cheap: yt-dlp
            returns each entry's identity from the index page it already
            fetched, instead of visiting every item to resolve its formats.
            On a channel with two thousand videos that is the difference
            between one request and two thousand.

            `entries` is a generator for most extractors, so it is walked
            with a limit rather than measured. Asking `len()` for it is
            what makes a large playlist hang, and asking for all of it is
            what makes a large playlist never finish.
            """
            import itertools
            import yt_dlp

            request = json.loads(lathe_arguments["request"])
            options = _lathe_base_options(request)
            options["skip_download"] = True
            options["format"] = "all"
            options["extract_flat"] = "in_playlist"
            # The one place that does want the playlist: this function's whole
            # job is to enumerate it.
            options["noplaylist"] = False
            limit = int(request.get("limit") or 500)

            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(request["url"], download=False, process=False)
                if info is None:
                    return json.dumps({"title": None, "entries": [], "truncated": False})

                if info.get("_type") not in ("playlist", "multi_video"):
                    # Not a playlist at all. Reporting the URL back as a
                    # single entry means the caller has one code path for
                    # "download everything here" whether or not "here"
                    # turned out to hold more than one thing.
                    url = info.get("webpage_url") or request["url"]
                    return json.dumps({
                        "title": info.get("title"),
                        "entries": [{"url": url, "title": info.get("title")}],
                        "truncated": False,
                    })

                walked = itertools.islice(info.get("entries") or [], limit + 1)
                found = []
                for entry in walked:
                    if entry is None:
                        continue
                    url = entry.get("url") or entry.get("webpage_url")
                    if not url:
                        # A flat entry can carry only an id and the name of
                        # the extractor that made it. `ie_key` is how yt-dlp
                        # itself rebuilds a URL from that pair.
                        ident, key = entry.get("id"), entry.get("ie_key")
                        if ident and key:
                            url = "%s:%s" % (key.lower(), ident)
                    if url:
                        found.append({"url": url, "title": entry.get("title")})

                return json.dumps({
                    "title": info.get("title"),
                    "entries": found[:limit],
                    "truncated": len(found) > limit,
                })


        # ------------------------------------------------------------------
        # Downloading
        # ------------------------------------------------------------------

        def _lathe_ytdlp_download():
            """Download exactly one format id to exactly one path.

            One format id, never a `+` expression: a compound expression is what
            makes yt-dlp construct the ffmpeg merger. A caller that wants both
            tracks calls this twice and joins the results in Swift.
            """
            import yt_dlp

            request = json.loads(lathe_arguments["request"])
            token = request["token"]
            part = request.get("part", 0)
            part_count = request.get("part_count", 1)
            destination = request["destination"]

            state = {"filename": destination, "total": None, "downloaded": 0}

            def hook(status):
                state["filename"] = status.get("filename") or state["filename"]
                total = status.get("total_bytes") or status.get("total_bytes_estimate")
                if total:
                    state["total"] = total
                downloaded = status.get("downloaded_bytes")
                if downloaded is not None:
                    state["downloaded"] = downloaded
                keep_going = _lathe_report_progress({
                    "token": token,
                    "part": part,
                    "part_count": part_count,
                    "status": status.get("status") or "downloading",
                    "downloaded_bytes": state["downloaded"],
                    "total_bytes": state["total"],
                    "fragment_index": status.get("fragment_index"),
                    "fragment_count": status.get("fragment_count"),
                    "speed": status.get("speed"),
                    "eta": status.get("eta"),
                })
                if not keep_going:
                    # yt-dlp's own cancellation exception, so its downloader
                    # unwinds through the paths it already has for a user
                    # pressing ^C — including removing the .part file.
                    raise yt_dlp.utils.DownloadCancelled("cancelled by the caller")

            options = _lathe_base_options(request)
            options["format"] = request["format_id"]
            # A literal path, so `%` in a directory name is not a template.
            options["outtmpl"] = destination.replace("%", "%%")
            options["progress_hooks"] = [hook]
            options["paths"] = {}

            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(request["url"], download=True)

            path = state["filename"]
            size = os.path.getsize(path) if os.path.exists(path) else 0
            return json.dumps({
                "path": path,
                "bytes": size,
                "format_id": request["format_id"],
            })


        # ------------------------------------------------------------------
        # Readiness
        # ------------------------------------------------------------------

        def _lathe_ytdlp_readiness():
            report = {
                "installed": False,
                "version": None,
                "javascript": False,
                "javascript_error": _LATHE_YTDLP["provider_error"] or _LATHE_YTDLP["ctypes_error"],
                "solver_scripts": False,
                "solver_error": None,
                "cryptography": "pure-python",
                "developed_against": None,
            }
            try:
                import yt_dlp
                report["installed"] = True
                report["version"] = yt_dlp.version.__version__
            except Exception as exc:
                report["error"] = "%s: %s" % (type(exc).__name__, exc)
                return json.dumps(report)

            report["javascript"] = bool(
                _LATHE_YTDLP["provider_registered"] and _LATHE_YTDLP["js_evaluate"] is not None)

            # The solver scripts are the other half of the JavaScript story and
            # they fail separately: a registered provider with no script to run
            # is exactly as useless as no provider, and it is worth being able
            # to tell which happened.
            try:
                import yt_dlp_ejs.yt.solver as _solver
                report["solver_scripts"] = bool(_solver.lib() and _solver.core())
            except Exception as exc:
                report["solver_error"] = (
                    "the challenge solver scripts are not installed (%s). Install the "
                    "yt-dlp-ejs project alongside yt-dlp." % exc)

            # yt-dlp prefers pycryptodomex for AES and falls back to its own
            # pure-Python implementation when it is absent. pycryptodomex is a
            # C extension and can never be installed at run time on iOS, so the
            # fallback is the permanent state here — reported, so that a slow
            # AES-128 HLS decrypt is a known property rather than a mystery.
            try:
                from yt_dlp.dependencies import Cryptodome
                report["cryptography"] = "pycryptodomex" if Cryptodome.AES else "pure-python"
            except Exception:
                pass

            return json.dumps(report)
        """#
}
