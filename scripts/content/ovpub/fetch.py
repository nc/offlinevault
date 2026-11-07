"""Moving bytes onto this Mac: resumable curl downloads, a size+mtime hash cache, streamed reads, PDF fetches
with the WebKit fallback for agency sites that refuse curl."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import requests
import time
from pathlib import Path
from typing import Iterator

from .http import USER_AGENT

CHUNK = 8 * 1024 * 1024
BROWSER_FETCH = Path(__file__).resolve().parents[1] / "browser_fetch.swift"


class FetchError(Exception):
    pass


class HashCache:
    """content/.hashcache.json: relative path -> {size, mtime_ns, sha256}. A 300 GB tree is hashed once."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self.path = self.root / ".hashcache.json"
        self.data: dict[str, dict] = json.loads(self.path.read_text()) if self.path.exists() else {}

    def sha256(self, path: Path) -> str:
        path = Path(path)
        st = path.stat()
        key = os.path.relpath(path, self.root)
        hit = self.data.get(key)
        if hit and hit["size"] == st.st_size and hit["mtime_ns"] == st.st_mtime_ns:
            return hit["sha256"]
        digest = sha256_file(path)
        self.data[key] = {"size": st.st_size, "mtime_ns": st.st_mtime_ns, "sha256": digest}
        self.root.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, indent=1, sort_keys=True))
        os.replace(tmp, self.path)
        return digest


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path, log=print) -> Path:
    """curl into dest.part with resume, rename when complete. Rerunning after a crash continues the .part."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    cmd = ["curl", "-fL", "-C", "-", "--retry", "5", "--retry-all-errors", "--retry-delay", "5", "-A", USER_AGENT, "-sS", "-o", str(part), url]
    log(f"  downloading {dest.name}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise FetchError(f"curl {url}: exit {r.returncode}: {r.stderr.strip()[-300:]}")
    os.replace(part, dest)
    return dest


def stream(url: str, attempts: int = 12, backoff: float = 5.0) -> Iterator[bytes]:
    """The upstream bytes as they arrive, resuming by byte range when the connection drops.

    A 139 GB object over one connection fails on the network before it fails on anything else (measured: HTTP/2
    INTERNAL_ERROR after 96 min from Protomaps, "transfer closed" after 100 min from a Kiwix mirror). Each
    attempt asks for `bytes=<received>-` and the caller sees one contiguous stream. A server that answers a
    resume request with 200 instead of 206 would restart from byte 0, so that is an error, not a retry.
    """
    received = 0
    last_error: Exception | None = None
    for attempt in range(attempts):
        headers = {"User-Agent": USER_AGENT}
        if received:
            headers["Range"] = f"bytes={received}-"
        try:
            with requests.get(url, headers=headers, stream=True, timeout=(30, 180)) as r:
                if received and r.status_code != 206:
                    raise FetchError(f"{url}: server ignored Range at byte {received} (HTTP {r.status_code})")
                r.raise_for_status()
                for chunk in r.iter_content(CHUNK):
                    if chunk:
                        received += len(chunk)
                        yield chunk
            return
        except FetchError:
            raise
        except (requests.RequestException, ConnectionError, OSError) as e:  # dropped mid-body or on connect
            last_error = e
            if attempt == attempts - 1:
                break
            time.sleep(min(backoff * (2 ** attempt), 300))
    raise FetchError(f"{url}: gave up after {attempts} attempts at byte {received}: {last_error}")


def is_pdf(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(5) == b"%PDF-"
    except OSError:
        return False


def download_pdf(url: str, dest: Path, log=print) -> Path:
    """curl first; when the host hands back HTML or refuses, the hidden WKWebView downloader runs the site's
    JavaScript like Safari. Only a real PDF is kept."""
    dest = Path(dest)
    if dest.exists() and is_pdf(dest):
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    r = subprocess.run(["curl", "-fL", "-sS", "--retry", "3", "-A", USER_AGENT, "-o", str(part), url], capture_output=True, text=True)
    if r.returncode == 0 and is_pdf(part):
        os.replace(part, dest)
        return dest
    part.unlink(missing_ok=True)
    log(f"  plain download refused for {dest.name}; retrying with the WebKit downloader")
    r = subprocess.run(["swift", str(BROWSER_FETCH), url, str(part), "120"], capture_output=True, text=True)
    if r.returncode == 0 and is_pdf(part):
        os.replace(part, dest)
        return dest
    part.unlink(missing_ok=True)
    raise FetchError(f"{url}: not fetchable as a PDF (curl and WebKit both failed)")
