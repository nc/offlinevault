#!/usr/bin/env python3
"""Serve the live catalogue from files already on this Mac, so a Debug app installs them through its normal path.

    local_mirror.py --out DIR --ids a,b,c [--content content] [--extra models=/path/dir] [--port 8798]

Fetches the live manifest, keeps the artefacts named by --ids plus the catalogue, links each artefact's file from
the publisher's cache (or an --extra directory) under DIR at the manifest path, signs the trimmed manifest with the
committed dev key (DEBUG builds trust it) and serves DIR over HTTP. Launch the app with
OFFLINEVAULT_UPDATES_URL=http://127.0.0.1:PORT/ and it verifies, installs and records the artefacts exactly as it
would from offlinevault.dev, at disk speed. Artefacts with no local file are left out and listed.
"""
from __future__ import annotations

import argparse
import base64
import functools
import http.server
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIVE = "https://offlinevault.dev/updates/"
DEV_KEY = ROOT / "scripts" / "dev-keys" / "licence-private.key"


def fetch(url: str) -> bytes:
    """The site refuses urllib's default User-Agent, so name the caller."""
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "offlinevault-eval-mirror"}), timeout=60).read()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ids", required=True, help="artefact ids to offer, comma separated")
    ap.add_argument("--content", default=str(ROOT / "content"), help="publisher cache with zim/, packs/, models/ folders")
    ap.add_argument("--extra", action="append", default=[], help="kind=dir, another folder to look in for that manifest folder")
    ap.add_argument("--port", type=int, default=8798)
    ap.add_argument("--no-serve", action="store_true")
    a = ap.parse_args(argv)
    out = Path(a.out)
    wanted = {i.strip() for i in a.ids.split(",") if i.strip()}
    extra = dict(e.split("=", 1) for e in a.extra)

    envelope = json.loads(fetch(LIVE + "manifest.json"))
    payload = json.loads(base64.b64decode(envelope["payload"] + "=="))
    kept, missing = [], []
    for art in payload["artefacts"]:
        if art["id"] not in wanted and art["kind"] != "catalogue":
            continue
        link = out / art["path"]
        link.parent.mkdir(parents=True, exist_ok=True)
        if art["kind"] == "catalogue":
            link.write_bytes(fetch(LIVE + art["path"]))
            kept.append(art)
            continue
        folder, name = art["path"].split("/", 1)
        source = Path(extra.get(folder, Path(a.content) / folder)) / name
        if not source.exists() or source.stat().st_size != art["sizeBytes"]:
            missing.append(f"{art['id']}: no file of {art['sizeBytes']} bytes at {source}")
            continue
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(source.resolve())
        kept.append(art)
    for m in missing:
        print("left out:", m, file=sys.stderr)
    for i in sorted(wanted - {k["id"] for k in kept} - {m.split(":")[0] for m in missing}):
        print("not in the live catalogue:", i, file=sys.stderr)
    trimmed = {**payload, "artefacts": kept}
    plain = out / "manifest.plain.json"
    plain.write_text(json.dumps(trimmed, indent=1))
    subprocess.run(["swift", "run", "-c", "release", "licencetool", "sign-envelope", "--format", envelope["format"], "--key", str(DEV_KEY),
                    "--key-id", "dev-2026", "--payload", str(plain), "--out", str(out / "manifest.json")],
                   cwd=ROOT / "Core", check=True, stdout=subprocess.DEVNULL)
    print(f"mirror {out}: {len(kept)} artefacts, {sum(k['sizeBytes'] for k in kept) / 1e9:.2f} GB, release {payload['version']}")
    if a.no_serve:
        return 0
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(out))
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    with http.server.ThreadingHTTPServer(("127.0.0.1", a.port), handler) as server:
        print(f"serving http://127.0.0.1:{a.port}/ (OFFLINEVAULT_UPDATES_URL)", flush=True)
        server.serve_forever()
    return 0


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main())
