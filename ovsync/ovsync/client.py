from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Callable

import requests

from . import __version__
from .errors import LicenceNeeded, NetworkError, VerificationFailed
from .licence import day_string
from .manifest import parse_iso

CHUNK = 1 << 20
TIMEOUT = (20, 120)
Progress = Callable[[int, int], None]


class Service:
    def __init__(self, origin: str, session: requests.Session | None = None):
        self.origin = origin.rstrip("/") + "/"
        self.content = self.origin + "updates/"
        self.session = session or requests.Session()
        self.session.headers["User-Agent"] = f"ovsync/{__version__}"

    def fetch_manifest(self) -> bytes:
        return self._get(self.content + "manifest.json").content

    def download(self, url: str, dest: Path, size: int, sha256: str, progress: Progress) -> None:
        part = dest.with_name(dest.name + ".part")
        dest.parent.mkdir(parents=True, exist_ok=True)
        for attempt in ("resume", "fresh"):
            if attempt == "fresh":
                part.unlink(missing_ok=True)
            digest, offset = _hash_existing(part)
            if offset > size:
                part.unlink()
                digest, offset = hashlib.sha256(), 0
            if offset < size:
                digest = self._fetch_rest(url, part, offset, digest, size, progress)
            if digest.hexdigest() == sha256 and part.stat().st_size == size:
                os.replace(part, dest)
                return
            if attempt == "fresh":
                raise VerificationFailed(f"{dest.name}: SHA-256 does not match the catalogue after download")

    def _fetch_rest(self, url: str, part: Path, offset: int, digest, size: int, progress: Progress):
        """200 to a Range request means the server ignored it and is sending the whole file (RFC 9110, 14.2)."""
        headers = {"Range": f"bytes={offset}-"} if offset else {}
        try:
            with self.session.get(url, headers=headers, stream=True, timeout=TIMEOUT) as r:
                if r.status_code == 200 and offset:
                    digest, offset = hashlib.sha256(), 0
                    part.unlink()
                elif r.status_code not in (200, 206):
                    raise NetworkError(f"{url}: HTTP {r.status_code}")
                with open(part, "ab") as f:
                    for chunk in r.iter_content(CHUNK):
                        f.write(chunk)
                        digest.update(chunk)
                        offset += len(chunk)
                        progress(offset, size)
        except requests.RequestException as e:
            raise NetworkError(f"{url}: {_reason(e)}")
        return digest

    def activate(self, key: str, device_id: str, device_name: str) -> dict:
        return self._licence_post("activate", {"key": key, "deviceId": device_id, "deviceName": device_name, "appVersion": f"ovsync/{__version__}"})

    def deactivate(self, key: str, device_id: str) -> dict:
        return self._licence_post("deactivate", {"key": key, "deviceId": device_id})

    def seats(self, key: str, device_id: str) -> dict:
        return self._licence_post("seats", {"key": key, "deviceId": device_id})

    def _licence_post(self, action: str, body: dict) -> dict:
        url = self.origin + "api/licence/" + action
        try:
            r = self.session.post(url, json=body, timeout=TIMEOUT)
        except requests.RequestException as e:
            raise NetworkError(f"could not reach the licence service: {_reason(e)}")
        try:
            data = r.json() if r.content else {}
        except ValueError:
            data = {}
        if 200 <= r.status_code < 300:
            return data
        if r.status_code == 404:
            raise LicenceNeeded("key not recognised. Check it against your receipt; keys use no 0, O, 1 or I")
        if r.status_code == 409:
            names = ", ".join(s.get("deviceName") or s.get("deviceId", "?") for s in data.get("seats", []))
            raise LicenceNeeded(f"all {data.get('seatLimit', '')} seats are in use ({names}). Run 'ovsync deactivate' on one of them")
        if r.status_code == 410:
            ended = data.get("endedAt")
            when = day_string(parse_iso(ended)) if ended else "an earlier date"
            raise LicenceNeeded(f"this plan ended on {when}")
        raise NetworkError(f"the licence service answered HTTP {r.status_code}")

    def _get(self, url: str) -> requests.Response:
        try:
            r = self.session.get(url, timeout=TIMEOUT)
        except requests.RequestException as e:
            raise NetworkError(f"{url}: {_reason(e)}")
        if r.status_code != 200:
            raise NetworkError(f"{url}: HTTP {r.status_code}")
        return r


def _hash_existing(part: Path):
    digest = hashlib.sha256()
    if not part.exists():
        return digest, 0
    with open(part, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            digest.update(chunk)
        return digest, f.tell()


def _reason(e: requests.RequestException) -> str:
    if isinstance(e, requests.ConnectionError):
        return "connection failed"
    if isinstance(e, requests.Timeout):
        return "timed out"
    return e.__class__.__name__
