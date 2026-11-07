"""An in-process stand-in for the worker's /admin/r2/ and /updates/ routes (SPEC §3 and §4), for WorkerStore tests."""
from __future__ import annotations

import hashlib
import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SECRET = "test-upload-secret"


class Bucket:
    def __init__(self):
        self.objects: dict[str, tuple[bytes, str | None]] = {}
        self.uploads: dict[str, dict] = {}
        self.aborted: list[str] = []
        self.lock = threading.Lock()


def make_server(bucket: Bucket, part_limit: int = 95 * 1024 * 1024):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _send(self, code: int, body: bytes = b"", headers: dict | None = None):
            self.send_response(code)
            headers = dict(headers or {})
            headers.setdefault("Content-Length", str(len(body)))
            for k, v in headers.items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _body(self) -> bytes:
            n = int(self.headers.get("Content-Length", "0"))
            return self.rfile.read(n) if n else b""

        def _auth(self) -> bool:
            if self.headers.get("Authorization") != f"Bearer {SECRET}":
                self._send(401, b"unauthorized")
                return False
            return True

        def do_GET(self):
            u = urlparse(self.path)
            if u.path.startswith("/updates/"):
                key = u.path[len("/updates/"):]
                if key in bucket.objects:
                    data, sha = bucket.objects[key]
                    return self._send(200, data, {"X-OfflineVault-SHA256": sha} if sha else {})
                return self._send(404, b"not found")
            if not self._auth():
                return
            if u.path == "/admin/r2/list":
                q = parse_qs(u.query)
                prefix = q.get("prefix", [""])[0]
                keys = sorted(k for k in bucket.objects if k.startswith(prefix))
                page = keys[:2]
                body = {"keys": [{"key": k, "size": len(bucket.objects[k][0]), "sha256": bucket.objects[k][1]} for k in page]}
                if len(keys) > 2 and not q.get("cursor"):
                    body["cursor"] = "more"
                if q.get("cursor"):
                    body["keys"] = [{"key": k, "size": len(bucket.objects[k][0]), "sha256": bucket.objects[k][1]} for k in keys[2:]]
                return self._send(200, json.dumps(body).encode(), {"Content-Type": "application/json"})
            self._send(404)

        def do_HEAD(self):
            if not self._auth():
                return
            u = urlparse(self.path)
            key = u.path[len("/admin/r2/object/"):]
            if key in bucket.objects:
                data, sha = bucket.objects[key]
                headers = {"Content-Length": str(len(data)), "ETag": '"e"'}
                if sha:
                    headers["X-OfflineVault-SHA256"] = sha
                return self._send(200, headers=headers)
            self._send(404)

        def do_PUT(self):
            if not self._auth():
                return
            u = urlparse(self.path)
            body = self._body()
            if len(body) > part_limit:
                return self._send(413, b"too large")
            if u.path.startswith("/admin/r2/object/"):
                key = u.path[len("/admin/r2/object/"):]
                sha = hashlib.sha256(body).hexdigest()
                declared = self.headers.get("X-OfflineVault-SHA256")
                if not declared:   # the real route refuses an upload that does not declare its sha
                    return self._send(400, b'{"error":"bad_request","reason":"x-offlinevault-sha256"}')
                if declared != sha:
                    return self._send(400, b"sha mismatch")
                with bucket.lock:
                    if key in bucket.objects and bucket.objects[key][1] != sha and not (key == "manifest.json" or key.startswith("manifests/")):
                        return self._send(409, b"immutable")
                    bucket.objects[key] = (body, sha)
                return self._send(200, b"{}")
            if u.path.startswith("/admin/r2/multipart/"):
                q = parse_qs(u.query)
                up = bucket.uploads.get(q["uploadId"][0])
                if up is None:
                    return self._send(404, b"no such upload")
                n = int(q["part"][0])
                etag = hashlib.md5(body).hexdigest()
                with bucket.lock:
                    up["parts"][n] = (etag, body)
                return self._send(200, json.dumps({"etag": etag}).encode())
            self._send(404)

        def do_POST(self):
            if not self._auth():
                return
            u = urlparse(self.path)
            body = self._body()
            if u.path.endswith("/complete"):
                key = u.path[len("/admin/r2/multipart/"):-len("/complete")]
                req = json.loads(body)
                up = bucket.uploads.pop(req["uploadId"], None)
                if up is None:
                    return self._send(404)
                parts = sorted(req["parts"], key=lambda p: p["partNumber"])
                data = b"".join(up["parts"][p["partNumber"]][1] for p in parts)
                for p in parts:
                    if up["parts"][p["partNumber"]][0] != p["etag"]:
                        return self._send(400, b"etag mismatch")
                with bucket.lock:
                    bucket.objects[key] = (data, up["sha"])
                return self._send(200, b"{}")
            if u.path.startswith("/admin/r2/multipart/"):
                key = u.path[len("/admin/r2/multipart/"):]
                with bucket.lock:
                    stored = bucket.objects.get(key)
                    sha = self.headers.get("X-OfflineVault-SHA256")
                    if stored and (stored[1] != sha or sha is None) and not (key == "manifest.json" or key.startswith("manifests/")):
                        return self._send(409, b"immutable")
                uid = uuid.uuid4().hex
                bucket.uploads[uid] = {"key": key, "sha": self.headers.get("X-OfflineVault-SHA256") or None, "parts": {}}
                return self._send(200, json.dumps({"uploadId": uid}).encode())
            self._send(404)

        def do_DELETE(self):
            if not self._auth():
                return
            u = urlparse(self.path)
            if u.path.startswith("/admin/r2/multipart/"):
                uid = parse_qs(u.query)["uploadId"][0]
                bucket.uploads.pop(uid, None)
                bucket.aborted.append(uid)
                return self._send(204)
            key = u.path[len("/admin/r2/object/"):]
            bucket.objects.pop(key, None)
            self._send(204)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_port}"
