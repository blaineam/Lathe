import Foundation

/// The Python module that drives `gallery-dl`.
///
/// Same shape as ``MediaFetcherDriver`` and for the same reasons: one module
/// installed once per process, every function returning a JSON string, and
/// nothing crossing back into Swift that Swift cannot name.
///
/// ## Why `gallery-dl` needs a driver of its own rather than an option flag
///
/// The two tools do different jobs. `yt-dlp` resolves one page to a set of
/// renditions of one thing and leaves the downloading to its caller, which is
/// why ``MediaFetcher`` can select a format, fetch two streams and mux them.
/// `gallery-dl` resolves one page to *many* separate files and writes them
/// itself, naming them from its own templates. There is no format to select
/// and no single destination path to hand it.
///
/// So the driver's job here is the opposite one: constrain where it writes,
/// and find out what it wrote.
///
/// ## What is deliberately not used
///
/// * **No `exec` post-processor.** It spawns a process, which PEP 730 removes
///   on iOS, and which is in any case a way to run arbitrary commands from a
///   configuration file.
/// * **No `ytdl` downloader.** `gallery-dl` can delegate to `yt-dlp` for video
///   it finds; that path is left alone, because this package already drives
///   `yt-dlp` directly and going through two layers to reach it would mean two
///   sets of options with one set of behaviour.
/// * **No configuration files.** `gallery-dl` reads `~/.gallery-dl.conf` and
///   several other locations by default. Every setting here is passed in, and
///   the search is switched off, so what an application asked for is what
///   happens — a downloader whose behaviour depends on a file nobody in the
///   application wrote is not something a sandbox makes safe.
enum GalleryFetcherDriver {

    static let installExpression = "_lathe_gdl_installed()"

    static let readinessFunction = "_lathe_gdl_readiness"
    static let supportsFunction = "_lathe_gdl_supports"
    static let listFunction = "_lathe_gdl_list"
    static let downloadFunction = "_lathe_gdl_download"

    static let source = #"""
        # Lathe's gallery-dl glue. Installed once per process by LatheFetch's
        # GalleryFetcher; not intended to be imported by hand.
        import json
        import os

        _LATHE_GDL = {"progress": None}


        def _lathe_gdl_progress(payload):
            """Report progress, if anything is listening.

            The callback into Swift is bound by the yt-dlp driver, because
            binding it is a ctypes operation that should happen once per
            process and not once per tool. Both modules are executed into the
            same namespace, so the function is normally right here — but a
            caller that uses gallery-dl without ever touching yt-dlp would
            find it missing, and a downloader that refuses to run because
            nobody is watching the progress bar would be absurd. So: report
            when there is somewhere to report to, and otherwise keep going.
            """
            reporter = globals().get("_lathe_report_progress")
            if reporter is None:
                return True
            return reporter(payload)


        def _lathe_gdl_installed():
            return "ok"


        def _lathe_gdl_configure(request):
            """Apply a request's settings to gallery-dl's global configuration.

            gallery-dl keeps configuration in one process-wide dictionary
            rather than on the job, so this clears it every time instead of
            merging. Otherwise a cookie file set for one site would still be
            set for the next one, which is the kind of leak that is invisible
            until it is a headline.
            """
            from gallery_dl import config

            config.clear()

            base = request["directory"]
            config.set((), "base-directory", base)
            # Everything in one directory, named by the extractor's own
            # filename template. The default layout nests by site and album,
            # which is right for a long-running archiver and wrong for "these
            # files, in the folder I chose".
            config.set((), "directory", [])
            config.set((), "skip", True)

            timeout = request.get("timeout") or 30
            config.set((), "timeout", timeout)
            config.set((), "retries", request.get("retries", 3))
            # No post-processors at all; see the Swift documentation for why
            # `exec` in particular is never enabled.
            config.set((), "postprocessors", None)

            if request.get("cookie_file"):
                config.set((), "cookies", request["cookie_file"])
            if request.get("proxy"):
                config.set((), "proxy", request["proxy"])
            if request.get("user_agent"):
                config.set((), "user-agent", request["user_agent"])
            return config


        def _lathe_gdl_readiness():
            report = {"installed": False, "version": None, "error": None}
            try:
                import gallery_dl
                report["installed"] = True
                report["version"] = gallery_dl.version.__version__
            except Exception as exc:
                report["error"] = "%s: %s" % (type(exc).__name__, exc)
            return json.dumps(report)


        def _lathe_gdl_supports():
            """Whether a real extractor claims this URL.

            gallery-dl's `find` returns None when nothing matches, and
            otherwise an extractor instance. There is no generic fallback the
            way yt-dlp has one, so a match here is a genuine claim on the site
            rather than "something might be on that page".
            """
            from gallery_dl import extractor

            url = lathe_arguments["url"]
            try:
                found = extractor.find(url)
            except Exception as exc:
                return json.dumps({"supported": False, "error": str(exc)})
            if found is None:
                return json.dumps({"supported": False})
            return json.dumps({
                "supported": True,
                "category": getattr(found, "category", None),
                "subcategory": getattr(found, "subcategory", None),
            })


        def _lathe_gdl_list():
            """What is on the page, without downloading any of it.

            gallery-dl's DataJob collects the extractor's output instead of
            acting on it. The shape is a list of `(kind, url, metadata)` for
            downloadable items, with other kinds for directory and queue
            messages, so the urls are the entries whose first element is the
            url message.
            """
            from gallery_dl import job

            request = json.loads(lathe_arguments["request"])
            _lathe_gdl_configure(request)
            limit = int(request.get("limit") or 500)

            data_job = job.DataJob(request["url"])
            data_job.run()

            items = []
            for entry in data_job.data:
                if not entry or len(entry) < 2:
                    continue
                kind = entry[0]
                # 3 is Message.Url and 6 is Message.Queue in gallery-dl's
                # enum. Compared by value rather than imported by name
                # because the enum's location has moved between releases and
                # the values have not.
                if kind not in (3, 6):
                    continue
                url = entry[1]
                meta = entry[2] if len(entry) > 2 and isinstance(entry[2], dict) else {}
                items.append({
                    "url": url if isinstance(url, str) else str(url),
                    "title": meta.get("title") or meta.get("filename"),
                    "extension": meta.get("extension"),
                })
                if len(items) >= limit:
                    break

            return json.dumps({"entries": items, "truncated": len(items) >= limit})


        def _lathe_gdl_download():
            """Download everything on the page into one directory.

            The paths are collected by watching the job rather than by
            listing the directory afterwards: the directory may already hold
            files from an earlier run, and gallery-dl's `skip` setting means
            those are deliberately not rewritten. Diffing a listing would
            report them as new.
            """
            from gallery_dl import job

            request = json.loads(lathe_arguments["request"])
            _lathe_gdl_configure(request)

            token = request["token"]
            limit = request.get("limit")
            written = []
            state = {"cancelled": False, "seen": 0}

            class _LatheJob(job.DownloadJob):
                def handle_url(self, url, kwdict):
                    if state["cancelled"]:
                        return
                    super().handle_url(url, kwdict)
                    path = getattr(self.pathfmt, "path", None)
                    if path:
                        written.append(path)
                    state["seen"] += 1
                    keep_going = _lathe_gdl_progress({
                        "token": token,
                        "part": len(written),
                        "part_count": limit or 0,
                        "status": "downloading",
                        "downloaded_bytes": len(written),
                        "total_bytes": limit,
                    })
                    if not keep_going:
                        state["cancelled"] = True
                    if limit and state["seen"] >= int(limit):
                        state["cancelled"] = True

            gallery_job = _LatheJob(request["url"])
            status = gallery_job.run()

            return json.dumps({
                "paths": [p for p in written if p and os.path.exists(p)],
                "status": status,
                "cancelled": state["cancelled"],
            })
        """#
}
