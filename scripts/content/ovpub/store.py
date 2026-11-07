"""Where published bytes live. `WorkerStore` speaks the worker's /admin/r2/ route (SPEC §4); `FakeStore` is the
in-memory or on-disk stand-in for tests and `--store fake`; `Printer` answers reads and narrates writes for `plan`.

Keys are content-immutable: a put to an existing key with a different sha is refused (409 from the worker,
ImmutableKeyError here) except for manifest.json and manifests/*. `put_stream` returns the size and sha of what it
sent; a stream whose sha is unknown up front goes up multipart without one, and the object then has no stored sha.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator, Protocol

import requests

from .http import USER_AGENT

PART_SIZE = 90 * 1024 * 1024
SINGLE_PUT_LIMIT = 95 * 1024 * 1024
PARALLEL_PARTS = 4
MUTABLE = ("manifest.json", "manifests/")


class ImmutableKeyError(Exception):
    pass


class StoreError(Exception):
    pass


@dataclass(frozen=True)
class ObjectInfo:
    key: str
    size: int
    sha256: str | None
    etag: str | None = None


class Store(Protocol):
    def head(self, key: str) -> ObjectInfo | None: ...
    def put_file(self, key: str, path: Path, sha256: str) -> None: ...
    def put_stream(self, key: str, chunks: Iterator[bytes], sha256: str | None, size: int | None) -> ObjectInfo: ...
    def list(self, prefix: str) -> list[ObjectInfo]: ...
    def delete(self, key: str) -> None: ...
    def get(self, key: str) -> bytes | None: ...


def is_mutable(key: str) -> bool:
    return key == MUTABLE[0] or key.startswith(MUTABLE[1])


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --- WorkerStore -------------------------------------------------------------------------------------------------

class WorkerStore:
    """Uploads through the worker's admin route, downloads through its public /updates/ route."""

    def __init__(self, origin: str, secret: str, session: requests.Session | None = None, retries: int = 4, timeout: float = 600):
        self.origin = origin.rstrip("/")
        self.admin = f"{self.origin}/admin/r2"
        self.public = f"{self.origin}/updates"
        self.session = session or requests.Session()
        self.session.headers.update({"Authorization": f"Bearer {secret}", "User-Agent": USER_AGENT})
        self.retries, self.timeout = retries, timeout

    def _request(self, method: str, url: str, ok=(200,), **kw) -> requests.Response:
        delay = 2.0
        for attempt in range(self.retries):
            try:
                r = self.session.request(method, url, timeout=self.timeout, **kw)
            except requests.RequestException as e:
                if attempt == self.retries - 1:
                    raise StoreError(f"{method} {url}: {e}") from e
                time.sleep(delay)
                delay *= 2
                continue
            if r.status_code in ok:
                return r
            if r.status_code == 409:
                raise ImmutableKeyError(f"{url}: key holds different bytes")
            if r.status_code == 401:
                raise StoreError("upload secret rejected (401)")
            if r.status_code >= 500 and attempt < self.retries - 1:
                time.sleep(delay)
                delay *= 2
                continue
            raise StoreError(f"{method} {url}: HTTP {r.status_code} {r.text[:200]}")
        raise StoreError(f"{method} {url}: gave up")

    def head(self, key: str) -> ObjectInfo | None:
        r = self._request("HEAD", f"{self.admin}/object/{key}", ok=(200, 404))
        if r.status_code == 404:
            return None
        return ObjectInfo(key, int(r.headers.get("Content-Length", "0")), r.headers.get("X-OfflineVault-SHA256"), r.headers.get("ETag"))

    def put_file(self, key: str, path: Path, sha256: str) -> None:
        size = os.path.getsize(path)
        if size <= SINGLE_PUT_LIMIT:
            with open(path, "rb") as f:
                self._request("PUT", f"{self.admin}/object/{key}", data=f, headers={"X-OfflineVault-SHA256": sha256, "Content-Length": str(size)})
            return
        upload_id = self._create_multipart(key, sha256)
        try:
            parts = list(range(1, (size + PART_SIZE - 1) // PART_SIZE + 1))

            def send(n: int) -> dict:
                with open(path, "rb") as f:
                    f.seek((n - 1) * PART_SIZE)
                    return self._put_part(key, upload_id, n, f.read(PART_SIZE))

            with ThreadPoolExecutor(PARALLEL_PARTS) as pool:
                etags = list(pool.map(send, parts))
            self._complete(key, upload_id, etags)
        except BaseException:
            self._abort(key, upload_id)
            raise

    def put_stream(self, key: str, chunks: Iterator[bytes], sha256: str | None, size: int | None) -> ObjectInfo:
        # Small known-size objects (manifests, catalogues) go up in one PUT, which the worker only accepts with the
        # sha declared; multipart is for anything over a part and may hash as it goes.
        if size is not None and size <= PART_SIZE:
            if not sha256:
                raise StoreError(f"{key}: a single PUT needs the object's sha256 up front")
            data = b"".join(chunks)
            if len(data) != size:
                raise StoreError(f"{key}: stream was {len(data)} bytes, expected {size}")
            self._request("PUT", f"{self.admin}/object/{key}", data=data,
                          headers={"X-OfflineVault-SHA256": sha256, "Content-Type": "application/octet-stream"})
            return ObjectInfo(key, size, sha256)
        upload_id = self._create_multipart(key, sha256)
        digest = hashlib.sha256()
        sent = 0
        # Parts upload on a small pool while the next part is still arriving, so a stream runs at the slower of
        # the two links instead of their sum (measured 2026-10-20: 9 MB/s each way when they alternated).
        futures: list = []
        try:
            with ThreadPoolExecutor(PARALLEL_PARTS) as pool:
                buf = bytearray()
                n = 1
                for c in chunks:
                    digest.update(c)
                    sent += len(c)
                    buf += c
                    while len(buf) >= PART_SIZE:
                        while len([f for f in futures if not f.done()]) >= PARALLEL_PARTS:
                            time.sleep(0.05)
                        futures.append(pool.submit(self._put_part, key, upload_id, n, bytes(buf[:PART_SIZE])))
                        del buf[:PART_SIZE]
                        n += 1
                if buf or not futures:
                    futures.append(pool.submit(self._put_part, key, upload_id, n, bytes(buf)))
                etags = [f.result() for f in futures]   # in part order; raises the first upload failure
            self._complete(key, upload_id, etags)
        except BaseException:
            for f in futures:
                f.cancel()
            self._abort(key, upload_id)
            raise
        return ObjectInfo(key, sent, digest.hexdigest())

    def _create_multipart(self, key: str, sha256: str | None) -> str:
        headers = {"X-OfflineVault-SHA256": sha256} if sha256 else {}
        r = self._request("POST", f"{self.admin}/multipart/{key}", headers=headers)
        return r.json()["uploadId"]

    def _put_part(self, key: str, upload_id: str, n: int, data: bytes) -> dict:
        r = self._request("PUT", f"{self.admin}/multipart/{key}", params={"uploadId": upload_id, "part": n}, data=data)
        return {"partNumber": n, "etag": r.json()["etag"]}

    def _complete(self, key: str, upload_id: str, parts: list[dict]) -> None:
        self._request("POST", f"{self.admin}/multipart/{key}/complete", json={"uploadId": upload_id, "parts": parts})

    def _abort(self, key: str, upload_id: str) -> None:
        try:
            self._request("DELETE", f"{self.admin}/multipart/{key}", params={"uploadId": upload_id}, ok=(200, 204, 404))
        except Exception:  # noqa: BLE001 - the original failure matters more
            pass

    def list(self, prefix: str) -> list[ObjectInfo]:
        out: list[ObjectInfo] = []
        cursor = None
        while True:
            params = {"prefix": prefix}
            if cursor:
                params["cursor"] = cursor
            body = self._request("GET", f"{self.admin}/list", params=params).json()
            out.extend(ObjectInfo(k["key"], int(k["size"]), k.get("sha256")) for k in body.get("keys", []))
            cursor = body.get("cursor")
            if not cursor:
                return out

    def delete(self, key: str) -> None:
        self._request("DELETE", f"{self.admin}/object/{key}", ok=(200, 204, 404))

    def get(self, key: str) -> bytes | None:
        r = self.session.get(f"{self.public}/{key}", timeout=self.timeout, headers={"Cache-Control": "no-cache"})
        if r.status_code == 404:
            return None
        if r.status_code != 200:
            raise StoreError(f"GET {key}: HTTP {r.status_code}")
        return r.content


# --- FakeStore ---------------------------------------------------------------------------------------------------

class FakeStore:
    """Dict-backed. With `root`, bytes are also written under root/<key> so a dry run leaves inspectable files.
    `pretend` lists objects the store answers `head` for without holding bytes (R2 as the lock claims it)."""

    def __init__(self, root: Path | None = None, pretend: dict[str, ObjectInfo] | None = None):
        self.root = Path(root) if root else None
        self.objects: dict[str, bytes] = {}
        self.shas: dict[str, str | None] = {}
        self.pretend: dict[str, ObjectInfo] = dict(pretend or {})
        self.log: list[tuple] = []
        if self.root and (self.root / ".index.json").exists():
            self.shas = json.loads((self.root / ".index.json").read_text())

    def head(self, key: str) -> ObjectInfo | None:
        if key in self.shas:
            size = len(self.objects[key]) if key in self.objects else os.path.getsize(self.root / key)
            return ObjectInfo(key, size, self.shas[key])
        return self.pretend.get(key)

    def _store(self, key: str, data: bytes, sha256: str | None) -> None:
        # Like R2 custom metadata: the declared sha is recorded as given (none when none was declared), so the
        # publisher's post-upload check is what catches a mismatch.
        if key in self.shas and (self.shas[key] != sha256 or sha256 is None) and not is_mutable(key):
            raise ImmutableKeyError(f"{key}: key holds different bytes")
        self.objects[key] = data
        self.shas[key] = sha256
        self.pretend.pop(key, None)
        if self.root:
            p = self.root / key
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            (self.root / ".index.json").write_text(json.dumps(self.shas, indent=1, sort_keys=True))

    def put_file(self, key: str, path: Path, sha256: str) -> None:
        self.log.append(("put_file", key))
        self._store(key, Path(path).read_bytes(), sha256)

    def put_stream(self, key: str, chunks: Iterator[bytes], sha256: str | None, size: int | None) -> ObjectInfo:
        self.log.append(("put_stream", key))
        data = b"".join(chunks)
        self._store(key, data, sha256)
        return ObjectInfo(key, len(data), sha256_bytes(data))

    def list(self, prefix: str) -> list[ObjectInfo]:
        return [self.head(k) for k in sorted(set(self.shas) | set(self.pretend)) if k.startswith(prefix)]

    def delete(self, key: str) -> None:
        self.log.append(("delete", key))
        self.objects.pop(key, None)
        self.shas.pop(key, None)
        self.pretend.pop(key, None)
        if self.root and (self.root / key).exists():
            (self.root / key).unlink()

    def get(self, key: str) -> bytes | None:
        if key in self.objects:
            return self.objects[key]
        if self.root and key in self.shas and (self.root / key).exists():
            return (self.root / key).read_bytes()
        return None


# --- Printer -----------------------------------------------------------------------------------------------------

class Printer:
    """Reads go to the real store when one is available; every write is printed and skipped."""

    def __init__(self, inner: Store | None, out: Callable[[str], None] = print):
        self.inner, self.out = inner, out
        self.planned: list[tuple[str, str, int | None]] = []

    def head(self, key: str) -> ObjectInfo | None:
        return self.inner.head(key) if self.inner else None

    def put_file(self, key: str, path: Path, sha256: str) -> None:
        self.planned.append(("put_file", key, os.path.getsize(path)))
        self.out(f"  would upload {key} ({os.path.getsize(path):,} bytes)")

    def put_stream(self, key: str, chunks: Iterator[bytes], sha256: str | None, size: int | None) -> ObjectInfo:
        self.planned.append(("put_stream", key, size))
        self.out(f"  would stream {key} ({size or 0:,} bytes)")
        return ObjectInfo(key, size or 0, sha256)

    def list(self, prefix: str) -> list[ObjectInfo]:
        return self.inner.list(prefix) if self.inner else []

    def delete(self, key: str) -> None:
        self.planned.append(("delete", key, None))
        self.out(f"  would delete {key}")

    def get(self, key: str) -> bytes | None:
        return self.inner.get(key) if self.inner else None
