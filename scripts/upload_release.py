#!/usr/bin/env python
"""Publishes one app release to the content origin through the worker's admin route (scripts/release.sh calls this).

    scripts/content/.venv/bin/python scripts/upload_release.py <dmg> <appcast.xml> <latest.json>
        [--origin https://offlinevault.dev] [--secret-file ~/.offlinevault-keys/upload-secret]

Keys land under app/. The DMG is immutable (a versioned name; the same bytes may be re-put, different bytes under
the same name are refused with 409, so bump --version and --build and rebuild); appcast.xml and latest.json are mutable. The
order is DMG, appcast, latest.json, so a reader never sees a feed or download pointer ahead of its bytes. After
each put the public /updates/ URL is read back and compared with the local file, DMG included.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "content"))
from ovpub.store import ImmutableKeyError, WorkerStore  # noqa: E402

KEY_PREFIX = "app/"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def public_sha(store: WorkerStore, key: str) -> tuple[str, int]:
    h = hashlib.sha256()
    size = 0
    with store.session.get(f"{store.public}/{key}", stream=True, timeout=store.timeout,
                           headers={"Cache-Control": "no-cache"}) as r:
        if r.status_code != 200:
            raise SystemExit(f"GET /updates/{key}: HTTP {r.status_code}")
        for chunk in r.iter_content(1 << 20):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size


def publish(store: WorkerStore, path: Path) -> None:
    key = KEY_PREFIX + path.name
    sha = sha256_file(path)
    size = path.stat().st_size
    existing = store.head(key)
    if existing and existing.sha256 == sha and existing.size == size:
        print(f"  {key}: already live with these bytes, skipping upload")
    else:
        print(f"  {key}: uploading {size:,} bytes")
        try:
            store.put_file(key, path, sha)
        except ImmutableKeyError:
            raise SystemExit(f"{key} already exists with different bytes. A release name is immutable: "
                             f"rerun scripts/release.sh with a new --version (the DMG is named after it) and --build.")
    got_sha, got_size = public_sha(store, key)
    if got_sha != sha or got_size != size:
        raise SystemExit(f"{key}: origin serves sha {got_sha} ({got_size} bytes), local is {sha} ({size} bytes)")
    print(f"  {key}: verified at {store.public}/{key} (sha256 {sha}, {size:,} bytes)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dmg", type=Path)
    ap.add_argument("appcast", type=Path)
    ap.add_argument("latest", type=Path)
    ap.add_argument("--origin", default="https://offlinevault.dev")
    ap.add_argument("--secret-file", type=Path, default=Path.home() / ".offlinevault-keys" / "upload-secret")
    args = ap.parse_args()
    if args.dmg.suffix != ".dmg" or args.appcast.name != "appcast.xml" or args.latest.name != "latest.json":
        raise SystemExit("expected <something>.dmg, appcast.xml and latest.json, in that order")
    secret = args.secret_file.read_text().strip()
    if not secret:
        raise SystemExit(f"{args.secret_file} is empty")
    store = WorkerStore(args.origin, secret)
    for path in (args.dmg, args.appcast, args.latest):
        publish(store, path)


if __name__ == "__main__":
    main()
