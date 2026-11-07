import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from ovpub import fetch

BODY = bytes(range(256)) * 400   # 102,400 bytes


def serve(drop_after: int | None, honour_range: bool):
    """A server that closes the connection after `drop_after` bytes on the first request."""
    state = {"requests": 0}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            state["requests"] += 1
            start = 0
            rng = self.headers.get("Range")
            if rng and honour_range:
                start = int(rng.split("=")[1].rstrip("-"))
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{len(BODY)-1}/{len(BODY)}")
            else:
                self.send_response(200)
            body = BODY[start:]
            cut = drop_after if (drop_after is not None and state["requests"] == 1) else None
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body if cut is None else body[:cut])
            self.wfile.flush()
            if cut is not None:
                self.connection.close()

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, state


def test_stream_resumes_after_the_connection_drops(monkeypatch):
    monkeypatch.setattr(fetch, "CHUNK", 8192)
    srv, state = serve(drop_after=30_000, honour_range=True)
    try:
        got = b"".join(fetch.stream(f"http://127.0.0.1:{srv.server_port}/x", backoff=0.01))
    finally:
        srv.shutdown()
    assert got == BODY and state["requests"] == 2


def test_stream_refuses_a_server_that_ignores_range(monkeypatch):
    monkeypatch.setattr(fetch, "CHUNK", 8192)
    srv, _ = serve(drop_after=30_000, honour_range=False)
    try:
        with pytest.raises(fetch.FetchError, match="ignored Range"):
            b"".join(fetch.stream(f"http://127.0.0.1:{srv.server_port}/x", backoff=0.01))
    finally:
        srv.shutdown()
