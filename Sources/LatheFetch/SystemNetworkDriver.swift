import Foundation

/// The Python half of ``SystemNetworkBridge``: a yt-dlp request handler and a
/// `requests` transport adapter that both send through URLSession.
///
/// Installed once per interpreter, shared by ``MediaFetcher`` and
/// ``GalleryFetcher``. Each fetcher then opts its own tool in:
///
/// - **yt-dlp**: `LatheURLSessionRH` is registered with `register_rh` and a
///   preference well above the built-in handlers (requests is 100), so every
///   request it can carry goes through it. Anything it declines — a websocket,
///   a `socks4` proxy, a request asking for impersonation — falls through to
///   yt-dlp's own handlers exactly as before, still through the proxy.
/// - **gallery-dl**: `Extractor._init_session` is wrapped so that each session
///   it builds mounts `LatheURLSessionAdapter` for http and https. `requests`
///   keeps doing everything above the transport — cookies, redirects, retries.
///
/// Registration is process-wide, as yt-dlp's handler registry is: it is done
/// only when a fetcher's configuration asks for it (by default, on iOS).
enum SystemNetworkDriver {

    static let installExpression = "_lathe_net_installed()"
    static let bindFunction = "_lathe_net_bind"
    static let registerYouTubeDLFunction = "_lathe_net_register_ytdlp"
    static let registerGalleryDLFunction = "_lathe_net_register_gallerydl"

    /// iOS on, macOS off: see ``MediaFetcher/Configuration/usesSystemNetworking``.
    static var defaultEnabled: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Installs the transport, binds it, and runs one registration function.
    /// `false` when the tool it registers with cannot be imported yet.
    static func register(_ function: String, in runtime: PythonRuntime) async -> Bool {
        if (try? await runtime.evaluateDetached(installExpression)) == nil {
            guard (try? await runtime.executeDetached(source)) != nil else { return false }
        }
        guard (try? await runtime.evaluateDetached(
            "\(bindFunction)()", arguments: SystemNetworkBridge.addresses)) != nil
        else { return false }
        guard let reply = try? await runtime.evaluateDetached("\(function)()"),
            let text = reply.value.string, text.contains("\"ok\": true")
        else {
            LatheFetchLog.python.error("URLSession transport not registered by \(function, privacy: .public)")
            return false
        }
        return true
    }

    static let source = #"""
        # Lathe's URLSession transport. See SystemNetworkBridge in Swift.
        import base64
        import io
        import json

        _LATHE_NET = {
            "open": None, "read": None, "close": None, "free": None, "ctypes": None,
            "ytdlp_registered": False, "gallerydl_registered": False,
        }


        def _lathe_net_installed():
            return "ok"


        def _lathe_net_bind():
            import ctypes
            args = lathe_arguments
            _LATHE_NET["ctypes"] = ctypes
            _LATHE_NET["open"] = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_char_p)(int(args["net_open"]))
            _LATHE_NET["read"] = ctypes.CFUNCTYPE(
                ctypes.c_void_p, ctypes.c_int64, ctypes.c_ssize_t, ctypes.POINTER(ctypes.c_ssize_t)
            )(int(args["net_read"]))
            _LATHE_NET["close"] = ctypes.CFUNCTYPE(None, ctypes.c_int64)(int(args["net_close"]))
            _LATHE_NET["free"] = ctypes.CFUNCTYPE(None, ctypes.c_void_p)(int(args["net_free"]))
            return json.dumps({"ok": True})


        class _LatheNetError(OSError):
            """A failure reported by URLSession. `kind` is one of transport,
            timeout, ssl, certificate, proxy."""

            def __init__(self, kind, message):
                super().__init__(message)
                self.kind = kind


        def _lathe_net_body(data):
            """Whatever a caller passed as a body, as bytes (or None)."""
            if data is None:
                return None
            if isinstance(data, str):
                return data.encode("utf-8")
            if isinstance(data, (bytes, bytearray, memoryview)):
                return bytes(data)
            if hasattr(data, "read"):
                content = data.read()
                return content.encode("utf-8") if isinstance(content, str) else bytes(content)
            return b"".join(
                part.encode("utf-8") if isinstance(part, str) else bytes(part) for part in data)


        def _lathe_net_open(method, url, headers, body, timeout, proxy):
            """Send one request (no redirect following). Returns the reply dict."""
            ctypes = _LATHE_NET["ctypes"]
            payload = {
                "method": method,
                "url": url,
                "headers": [[str(k), str(v)] for k, v in headers],
                "timeout": float(timeout) if timeout else 0,
                "proxy": proxy or "",
            }
            if body is not None:
                payload["body"] = base64.b64encode(body).decode("ascii")
            pointer = _LATHE_NET["open"](json.dumps(payload).encode("utf-8"))
            if not pointer:
                raise _LatheNetError("transport", "URLSession returned nothing")
            try:
                reply = json.loads(ctypes.string_at(pointer).decode("utf-8"))
            finally:
                _LATHE_NET["free"](pointer)
            if not reply.get("ok"):
                raise _LatheNetError(reply.get("kind", "transport"), reply.get("error", "request failed"))
            return reply


        class _LatheNetStream(io.RawIOBase):
            """A response body read from URLSession in chunks, never whole."""

            def __init__(self, handle, error_factory=None):
                super().__init__()
                self._handle = handle
                self._open = True
                self._error_factory = error_factory

            def readable(self):
                return True

            def readinto(self, buffer):
                if not self._open:
                    return 0
                ctypes = _LATHE_NET["ctypes"]
                view = memoryview(buffer).cast("B")
                length = ctypes.c_ssize_t(0)
                pointer = _LATHE_NET["read"](self._handle, len(view), ctypes.byref(length))
                count = length.value
                if count < 0:
                    try:
                        reason = ctypes.string_at(pointer).decode("utf-8", "replace") if pointer else "read failed"
                    finally:
                        if pointer:
                            _LATHE_NET["free"](pointer)
                    self._release()
                    error = _LatheNetError("transport", reason)
                    raise (self._error_factory(error) if self._error_factory else error)
                if count == 0:
                    self._release()
                    return 0
                try:
                    view[:count] = ctypes.string_at(pointer, count)
                finally:
                    _LATHE_NET["free"](pointer)
                return count

            def _release(self):
                if self._open:
                    self._open = False
                    _LATHE_NET["close"](self._handle)

            def close(self):
                self._release()
                super().close()


        class _LatheBufferedStream(io.BufferedReader):
            """A BufferedReader that can carry attributes, standing in for the
            urllib3 response requests normally puts in `Response.raw`: requests
            reads `_original_response` for cookies, gallery-dl's downloader
            asks `chunked` before sniffing a file's first bytes."""

            chunked = False

            def release_conn(self):
                self.close()


        _LATHE_REDIRECTS = (301, 302, 303, 307, 308)


        # ------------------------------------------------------------------
        # yt-dlp
        # ------------------------------------------------------------------

        def _lathe_net_register_ytdlp():
            if _LATHE_NET["ytdlp_registered"]:
                return json.dumps({"ok": True, "already": True})
            if _LATHE_NET["open"] is None:
                return json.dumps({"ok": False, "error": "not bound"})
            import urllib.parse
            import urllib.request
            from yt_dlp.networking.common import (
                Features, RequestHandler, Response, _REQUEST_HANDLERS, register_preference, register_rh)
            from yt_dlp.networking.exceptions import (
                CertificateVerifyError, HTTPError, ProxyError, RequestError, SSLError, TransportError)
            from yt_dlp.networking._helper import get_redirect_method
            from yt_dlp.utils.networking import select_proxy

            def map_error(error):
                kind = getattr(error, "kind", "transport")
                if kind == "certificate":
                    return CertificateVerifyError(msg=str(error), cause=error)
                if kind == "ssl":
                    return SSLError(msg=str(error), cause=error)
                if kind == "proxy":
                    return ProxyError(msg=str(error), cause=error)
                return TransportError(msg=str(error), cause=error)

            class _Pairs:
                """Response headers with repeats kept (one Set-Cookie per line)."""

                def __init__(self, pairs):
                    self._pairs = pairs

                def items(self):
                    return list(self._pairs)

            class _CookieResponse:
                """Just enough of an http.client response for CookieJar.extract_cookies."""

                def __init__(self, pairs):
                    import email.message
                    self._message = email.message.Message()
                    for name, value in pairs:
                        self._message[name] = value

                def info(self):
                    return self._message

            class LatheURLSessionRH(RequestHandler):
                """Sends yt-dlp's HTTP through URLSession (Apple's TLS)."""

                _SUPPORTED_URL_SCHEMES = ("http", "https")
                _SUPPORTED_PROXY_SCHEMES = ("http", "https", "socks5", "socks5h")
                _SUPPORTED_FEATURES = (Features.NO_PROXY, Features.ALL_PROXY)
                RH_NAME = "lathe-urlsession"

                def _check_extensions(self, extensions):
                    super()._check_extensions(extensions)
                    extensions.pop("cookiejar", None)
                    extensions.pop("timeout", None)
                    extensions.pop("legacy_ssl", None)
                    extensions.pop("keep_header_casing", None)

                def _send(self, request):
                    headers = self._get_headers(request)
                    explicit_cookie = None
                    for name in list(headers):
                        if name.lower() == "cookie":
                            explicit_cookie = headers.pop(name)
                    cookiejar = self._get_cookiejar(request)
                    timeout = self._calculate_timeout(request)
                    proxies = self._get_proxies(request)
                    url, method = request.url, request.method
                    body = _lathe_net_body(request.data)

                    for hop in range(21):
                        proxy = select_proxy(url, proxies)
                        probe = urllib.request.Request(url, method=method)
                        if cookiejar is not None:
                            cookiejar.add_cookie_header(probe)
                        cookies = [c for c in (explicit_cookie if hop == 0 else None, probe.get_header("Cookie")) if c]
                        outgoing = list(headers.items())
                        if cookies:
                            outgoing.append(("Cookie", "; ".join(cookies)))
                        try:
                            reply = _lathe_net_open(method, url, outgoing, body, timeout, proxy)
                        except _LatheNetError as error:
                            raise map_error(error) from error

                        pairs = [tuple(pair) for pair in reply["headers"]]
                        if cookiejar is not None:
                            cookiejar.extract_cookies(_CookieResponse(pairs), probe)
                        status = reply["status"]
                        location = next((v for k, v in pairs if k.lower() == "location"), None)

                        stream = _LatheNetStream(reply["handle"], map_error)
                        response = Response(
                            fp=io.BufferedReader(stream), url=reply["url"], headers=_Pairs(pairs), status=status)

                        if status in _LATHE_REDIRECTS and location:
                            if hop == 20:
                                raise HTTPError(response, redirect_loop=True)
                            response.close()
                            new_url = urllib.parse.urljoin(url, location)
                            new_method = get_redirect_method(method, status)
                            if new_method != method and new_method == "GET":
                                body = None
                                for name in list(headers):
                                    if name.lower() in ("content-type", "content-length"):
                                        headers.pop(name)
                            if urllib.parse.urlparse(new_url).netloc != urllib.parse.urlparse(url).netloc:
                                for name in list(headers):
                                    if name.lower() == "authorization":
                                        headers.pop(name)
                            url, method = new_url, new_method
                            continue

                        if not 200 <= status < 300:
                            raise HTTPError(response)
                        return response

            if "LatheURLSession" not in _REQUEST_HANDLERS:
                register_rh(LatheURLSessionRH)

                @register_preference(LatheURLSessionRH)
                def _lathe_urlsession_preference(rh, request):
                    # Above requests (100) and urllib, so it is always tried first.
                    return 1000

            _LATHE_NET["ytdlp_registered"] = True
            return json.dumps({"ok": True})


        # ------------------------------------------------------------------
        # gallery-dl (requests)
        # ------------------------------------------------------------------

        def _lathe_net_register_gallerydl():
            if _LATHE_NET["gallerydl_registered"]:
                return json.dumps({"ok": True, "already": True})
            if _LATHE_NET["open"] is None:
                return json.dumps({"ok": False, "error": "not bound"})
            import http
            import http.client
            import requests
            import requests.adapters
            import requests.cookies
            import requests.exceptions
            import requests.structures
            import requests.utils
            from gallery_dl.extractor import common

            def map_error(error, request=None):
                kind = getattr(error, "kind", "transport")
                if kind in ("certificate", "ssl"):
                    return requests.exceptions.SSLError(str(error), request=request)
                if kind == "proxy":
                    return requests.exceptions.ProxyError(str(error), request=request)
                if kind == "timeout":
                    return requests.exceptions.Timeout(str(error), request=request)
                return requests.exceptions.ConnectionError(str(error), request=request)

            class _Original:
                def __init__(self, message):
                    self.msg = message

            class LatheURLSessionAdapter(requests.adapters.BaseAdapter):
                """A requests transport that sends through URLSession.

                Returns redirects unfollowed; requests' Session follows them
                and keeps the cookie jar, as it does with its own adapter."""

                def send(self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None):
                    proxy = requests.utils.select_proxy(request.url, proxies) if proxies else None
                    if isinstance(timeout, tuple):
                        timeout = max(t for t in timeout if t is not None) if any(timeout) else None
                    headers = [(k, v) for k, v in request.headers.items()]
                    try:
                        reply = _lathe_net_open(
                            request.method, request.url, headers, _lathe_net_body(request.body), timeout, proxy)
                    except _LatheNetError as error:
                        raise map_error(error, request) from error

                    pairs = [tuple(pair) for pair in reply["headers"]]
                    message = http.client.HTTPMessage()
                    folded = requests.structures.CaseInsensitiveDict()
                    for name, value in pairs:
                        message[name] = value
                        folded[name] = (folded[name] + ", " + value) if name in folded else value

                    response = requests.Response()
                    response.status_code = reply["status"]
                    response.url = reply["url"]
                    response.request = request
                    response.headers = folded
                    try:
                        response.reason = http.HTTPStatus(response.status_code).phrase
                    except ValueError:
                        response.reason = ""
                    response.encoding = requests.utils.get_encoding_from_headers(folded)
                    raw = _LatheBufferedStream(
                        _LatheNetStream(reply["handle"], lambda e: map_error(e, request)))
                    raw._original_response = _Original(message)
                    response.raw = raw
                    requests.cookies.extract_cookies_to_jar(response.cookies, request, raw)
                    response.connection = self
                    if not stream:
                        _ = response.content
                    return response

                def close(self):
                    pass

            original = common.Extractor._init_session

            def _init_session(self, _original=original):
                _original(self)
                adapter = LatheURLSessionAdapter()
                self.session.mount("https://", adapter)
                self.session.mount("http://", adapter)

            common.Extractor._init_session = _init_session
            _LATHE_NET["gallerydl_registered"] = True
            return json.dumps({"ok": True})
        """#
}
