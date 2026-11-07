#!/usr/bin/env python3
"""Static file server with HTTP Range support (Python's http.server lacks it), used to stand in for
Cloudflare R2 during development. Serves a fixture directory; `--version N` selects which
manifest.vN.signed.json (the dev-key envelope the app verifies) is exposed as manifest.json so an update can be
demonstrated. `--unsigned` serves the plain manifest.vN.json instead: the self-hosted path in tests, and a
rejection on the official port.

    python3 scripts/fixture_server.py --root fixture/out --port 8787 --version 1 [--unsigned]

It also stands in for the licence issuer: POST /api/licence/activate, /deactivate and /seats answer with the
pre-signed dev-key files in fixture/ (made by `licencetool fixtures`). No signing happens here. The key's second
group picks the plan; keys use the 32-symbol alphabet 23456789ABCDEFGHJKLMNPQRSTUVWXYZ (no 0, O, 1, I):

    OV-DEVC-xxxx-xxxx-xxxx  core        OV-DEVH-...  household   OV-DEVD-...  drive   OV-DEVF-...  founder
    OV-DEVX-...             expired     OV-DEVS-...  409, two Macs already hold the seats   anything else: 404
"""
import argparse, base64, json, os, posixpath, re, sys, threading, time, hashlib
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import unquote, urlparse

KEY_RE = re.compile(r"^OV(-[2-9A-HJ-NP-Z]{4}){4}$")
FAMILIES = {"DEVC": "core", "DEVH": "household", "DEVD": "drive", "DEVF": "founder", "DEVX": "expired"}
SEAT_LOCK = threading.Lock()
SEATS = {}  # key -> {deviceId: seat dict}; in memory, so a restart frees every seat

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

class RangeHandler(SimpleHTTPRequestHandler):
    manifest_version = "1"
    manifest_signed = True
    throttle = 0.0  # seconds of sleep per 1 MiB, to make progress visible

    def translate_path(self, path):
        path = urlparse(path).path
        if path in ("/manifest.json", "manifest.json"):
            path = f"/manifest.v{self.manifest_version}{'.signed' if self.manifest_signed else ''}.json"
        rel = posixpath.normpath(unquote(path)).lstrip("/")
        return os.path.join(self.directory, rel)

    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path) or not os.path.exists(path):
            return super().do_GET()
        size = os.path.getsize(path)
        etag = '"%s"' % hashlib.md5(f"{path}{size}{os.path.getmtime(path)}".encode()).hexdigest()
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        status = 200
        if rng and rng.startswith("bytes="):
            spec = rng[6:].split(",")[0]
            s, _, e = spec.partition("-")
            try:
                if s:
                    start = int(s); end = int(e) if e else size - 1
                else:
                    start = max(0, size - int(e)); end = size - 1
            except ValueError:
                start, end = 0, size - 1
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers(); return
            end = min(end, size - 1)
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("ETag", etag)
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start); remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(1 << 20, remaining))
                if not chunk: break
                try: self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): return
                remaining -= len(chunk)
                if self.throttle: time.sleep(self.throttle)

    def log_message(self, fmt, *args):
        sys.stderr.write("[fixture] %s %s\n" % (self.address_string(), fmt % args))

    # --- licence issuer stand-in ---------------------------------------------------------------------------
    licence_dir = None

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_json(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return None
        return body if isinstance(body, dict) else None

    def do_POST(self):
        path = urlparse(self.path).path
        if path not in ("/api/licence/activate", "/api/licence/deactivate", "/api/licence/seats"):
            return self.send_json(404, {"error": "not_found"})
        body = self.read_json()
        key = body.get("key") if body else None
        device = body.get("deviceId") if body else None
        if not isinstance(key, str) or not KEY_RE.match(key) or not isinstance(device, str) or not device:
            return self.send_json(400, {"error": "bad_request"})
        family = key.split("-")[1]
        if family == "DEVS":
            seats = [{"deviceId": "fixture-mac-1", "deviceName": "Kitchen Mac mini", "activatedAt": "2026-10-01T09:00:00Z", "lastSeenAt": now_iso()},
                     {"deviceId": "fixture-mac-2", "deviceName": "Study MacBook", "activatedAt": "2026-10-02T09:00:00Z", "lastSeenAt": now_iso()}]
            if path.endswith("deactivate"):
                return self.send_json(200, {"seats": [s for s in seats if s["deviceId"] != device], "seatLimit": 2})
            if path.endswith("seats"):
                return self.send_json(200, {"seats": seats, "seatLimit": 2})
            return self.send_json(409, {"error": "seats_exhausted", "seats": seats, "seatLimit": 2})
        plan = FAMILIES.get(family)
        if plan is None:
            return self.send_json(404, {"error": "unknown_key"})
        with open(os.path.join(self.licence_dir, f"dev-licence-{plan}.json")) as f:
            licence = json.load(f)
        seat_limit = json.loads(base64.b64decode(licence["payload"]))["seats"]
        with SEAT_LOCK:
            roster = SEATS.setdefault(key, {})
            if path.endswith("deactivate"):
                roster.pop(device, None)
                return self.send_json(200, {"seats": list(roster.values()), "seatLimit": seat_limit})
            if path.endswith("seats"):
                return self.send_json(200, {"seats": list(roster.values()), "seatLimit": seat_limit})
            if device not in roster and len(roster) >= seat_limit:
                return self.send_json(409, {"error": "seats_exhausted", "seats": list(roster.values()), "seatLimit": seat_limit})
            seat = roster.setdefault(device, {"deviceId": device, "activatedAt": now_iso()})
            seat["deviceName"] = body.get("deviceName"); seat["appVersion"] = body.get("appVersion"); seat["lastSeenAt"] = now_iso()
            return self.send_json(200, {"licence": licence, "seats": list(roster.values()), "seatLimit": seat_limit})

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="fixture/out")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--version", default="1", help="which manifest.vN.json to serve as manifest.json")
    ap.add_argument("--unsigned", action="store_true", help="serve the plain manifest.vN.json instead of the signed envelope")
    ap.add_argument("--throttle", type=float, default=0.0, help="seconds to sleep per MiB served")
    ap.add_argument("--licences", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixture"), help="directory holding dev-licence-*.json")
    a = ap.parse_args()
    RangeHandler.manifest_version = a.version
    RangeHandler.manifest_signed = not a.unsigned
    RangeHandler.throttle = a.throttle
    RangeHandler.licence_dir = os.path.abspath(a.licences)
    root = os.path.abspath(a.root)
    handler = lambda *args, **kw: RangeHandler(*args, directory=root, **kw)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), handler)
    print(f"serving {root} at http://127.0.0.1:{a.port}/ (manifest v{a.version}{' unsigned' if a.unsigned else ' signed'}; licences from {RangeHandler.licence_dir})", flush=True)
    try: srv.serve_forever()
    except KeyboardInterrupt: pass

if __name__ == "__main__":
    main()
