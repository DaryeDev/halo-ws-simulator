"""Tiny HTTP observability server (default port = WS port + 1).

Lets you watch the Halo display and inject events from a browser or a script
*without* opening a second WebSocket (the device link is single-client).

    GET /                      live view (auto-refreshing) + inject buttons
    GET /shot.png              current 256x256 framebuffer as PNG
    GET /inject?event=tap&arg=double
    GET /inject?event=button_single
"""
from __future__ import annotations

import io
import logging
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from halo_ws_sim.server import SimState

_log = logging.getLogger("halo_ws_sim.observe")

_INDEX = b"""<!doctype html><meta charset=utf-8><title>Halo WS Simulator</title>
<style>body{background:#111;color:#ddd;font:14px system-ui;text-align:center;margin:2rem}
img{width:512px;height:512px;image-rendering:pixelated;border-radius:50%;background:#000}
button{font-size:15px;margin:3px;padding:.5rem .8rem;border:0;border-radius:6px;background:#333;color:#eee}
button:hover{background:#444}</style>
<h3>Halo WS Simulator</h3>
<img id=fb src=/shot.png>
<div>
<button onclick=i('button_single')>click</button>
<button onclick=i('button_double')>double</button>
<button onclick=i('button_long')>long</button>
<button onclick="i('tap','single')">tap</button>
<button onclick="i('tap','double')">2-tap</button>
<button onclick="i('tap','triple')">3-tap</button>
</div>
<p id=s></p>
<script>
function i(e,a){fetch('/inject?event='+e+(a?'&arg='+a:'')).then(r=>r.text()).then(t=>s.textContent=t)}
setInterval(()=>{fb.src='/shot.png?'+Date.now()},250)
</script>
"""


class _Handler(BaseHTTPRequestHandler):
    state: SimState  # set on the class before serving

    def log_message(self, *_a):  # quiet
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._send(200, _INDEX, "text/html; charset=utf-8")
        elif parsed.path == "/shot.png":
            self._send(200, self._framebuffer_png(), "image/png")
        elif parsed.path == "/inject":
            self._send(200, self._inject(parse_qs(parsed.query)), "text/plain")
        else:
            self._send(404, b"not found", "text/plain")

    def _framebuffer_png(self) -> bytes:
        bridge = self.state.bridge
        buf = io.BytesIO()
        if bridge is None:
            from PIL import Image

            Image.new("RGBA", (256, 256), (0, 0, 0, 255)).save(buf, "PNG")
        else:
            bridge.emu.get_framebuffer().save(buf, "PNG")
        return buf.getvalue()

    def _inject(self, q: dict[str, list[str]]) -> bytes:
        bridge = self.state.bridge
        if bridge is None:
            return b"no client connected"
        event = (q.get("event") or [""])[0]
        arg = (q.get("arg") or [None])[0]
        bridge.inject(event, arg)
        return f"injected {event} {arg or ''}".strip().encode()


def start_observe_server(state: SimState, port: int) -> ThreadingHTTPServer:
    _Handler.state = state
    httpd = ThreadingHTTPServer(("0.0.0.0", port), _Handler)
    threading.Thread(target=httpd.serve_forever, name="halo-observe", daemon=True).start()
    _log.info("observability view on http://localhost:%d", port)
    return httpd
