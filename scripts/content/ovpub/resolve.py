"""Spec intent -> this month's candidate artefact. Network reads only; nothing here writes.

A `Candidate` says what the artefact for an entry would be called, where its bytes come from, and what is already
known about them (size and sha from the Kiwix `.meta4`, HuggingFace LFS, or nothing). Mirror entries (kiwix, url,
archive) keep the upstream file name. Everything else is dated: its edition starts as the publishing month and
converge bumps the Kiwix-style letter suffix when that month already holds different bytes.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from urllib.parse import quote, unquote, urlparse
from xml.etree import ElementTree

from .http import Http
from .spec import (ArchiveSource, BuiltSource, DocumentsSource, Entry, KiwixExternalSource, KiwixSource, MapExtractSource, UrlSource, ZimitSource)

KIWIX_LISTING = "https://download.kiwix.org/zim/{category}/"
# Downloads may come from a faster mirror of the same tree (measured 2026-10-19: download.kiwix.org 0.5 MB/s,
# mirrorservice.org and ftp.fau.de 50 MB/s). Resolution and the .meta4 checksum always use the canonical host,
# so a mirror can only be slow or incomplete, never wrong: the sha is still checked against the canonical meta4.
KIWIX_DOWNLOAD_BASE = os.environ.get("OV_KIWIX_MIRROR", "https://download.kiwix.org/zim/").rstrip("/") + "/"
KIWIX_OPDS = "https://opds.library.kiwix.org/catalog/v2/entries?count=-1&name={name}"
PROTOMAPS_BUILD = "https://build.protomaps.com/{date}.pmtiles"
ARCHIVE_METADATA = "https://archive.org/metadata/{item}"
HF_TREE = "https://huggingface.co/api/models/{repo}/tree/main"


class ResolveError(Exception):
    pass


@dataclass(frozen=True)
class Upstream:
    url: str
    size: int | None
    sha256: str | None
    sha_source: str | None
    last_modified: str | None = None


@dataclass(frozen=True)
class Edition:
    """`2026-10`, then `2026-10b`, `2026-10c` when the same month is published again with different bytes."""
    month: str
    suffix: str = ""

    @classmethod
    def parse(cls, text: str) -> "Edition":
        m = re.fullmatch(r"(\d{4}-\d{2})([a-z]?)", text)
        if not m:
            raise ValueError(f"not an edition: {text!r}")
        return cls(m.group(1), m.group(2))

    def bump(self) -> "Edition":
        return Edition(self.month, next_suffix(self.suffix))

    def __str__(self) -> str:
        return self.month + self.suffix


def next_suffix(suffix: str) -> str:
    if suffix == "z":
        raise ValueError("edition suffix past z")
    return chr(ord(suffix) + 1) if suffix else "b"


@dataclass(frozen=True)
class Candidate:
    entry: Entry
    artefact_id: str
    path: str
    edition: str | None
    upstream: Upstream | None

    @property
    def mirror(self) -> bool:
        """The key is the upstream file name, so a sha conflict in the store means upstream changed bytes under one name."""
        return isinstance(self.entry.source, (KiwixSource, UrlSource, ArchiveSource))

    @property
    def external(self) -> bool:
        """The app fetches the upstream file itself; the publisher only records what Kiwix publishes about it."""
        return self.entry.external

    @property
    def passthrough(self) -> bool:
        """The artefact is the upstream file byte for byte, so its sha is the upstream sha."""
        if self.upstream is None:
            return False
        if isinstance(self.entry.source, MapExtractSource):
            return self.entry.source.maxzoom >= 15
        return True

    @property
    def key(self) -> str:
        return self.path

    def with_edition(self, edition: Edition | str) -> "Candidate":
        return dated(self.entry, str(edition), self.upstream)


def now_month(today: date | None = None) -> str:
    return (today or datetime.now(timezone.utc).date()).strftime("%Y-%m")


def resolve(entry: Entry, http: Http, today: date | None = None) -> Candidate:
    src = entry.source
    month = now_month(today)
    if isinstance(src, (KiwixSource, KiwixExternalSource)):
        file_name, edition, up = resolve_kiwix(src, http, canonical=entry.external)
        return Candidate(entry, f"{entry.id}-{edition}", f"zim/{file_name}", edition, up)
    if isinstance(src, UrlSource):
        up = resolve_url(src.url, http)
        return Candidate(entry, entry.id, f"{_folder(entry)}/{_basename(src.url)}", None, up)
    if isinstance(src, ArchiveSource):
        up = resolve_archive(src, http)
        return Candidate(entry, entry.id, f"{_folder(entry)}/{src.file}", None, up)
    if isinstance(src, MapExtractSource):
        _, up = resolve_protomaps(http, today)
        return dated(entry, month, up)
    if isinstance(src, BuiltSource) and src.builder != "fieldguide":
        raise ResolveError(f"{entry.id}: unknown builder {src.builder!r}")
    if isinstance(src, (DocumentsSource, ZimitSource, BuiltSource)):
        return dated(entry, month, None)
    raise ResolveError(f"{entry.id}: unknown source {type(src).__name__}")


def dated(entry: Entry, edition: str, upstream: Upstream | None) -> Candidate:
    """Id `<entry>-<edition>` and key `<folder>/<stem>_<edition>.<ext>` for every artefact that is not a mirror."""
    src = entry.source
    if isinstance(src, DocumentsSource):
        stem, ext = entry.id, "tar.gz"
    elif isinstance(src, ZimitSource):
        stem, ext = src.name, "zim"
    elif isinstance(src, MapExtractSource):
        stem, ext = (entry.id[4:] if entry.id.startswith("map-") else entry.id), "pmtiles"
    elif isinstance(src, BuiltSource) and src.builder == "fieldguide":
        stem, ext = "fieldguide_en", "zim"
    else:
        raise ResolveError(f"{entry.id}: {type(src).__name__} artefacts are not dated")
    return Candidate(entry, f"{entry.id}-{edition}", f"{_folder(entry)}/{stem}_{edition}.{ext}", edition, upstream)


def _folder(entry: Entry) -> str:
    return {"model": "models", "zim": "zim", "map": "maps", "document-pack": "packs"}[entry.kind]


def _basename(url: str) -> str:
    return unquote(urlparse(url).path.rsplit("/", 1)[-1])


# --- Kiwix -------------------------------------------------------------------------------------------------------

def dated_pattern(base: str) -> re.Pattern:
    return re.compile(rf"^{re.escape(base)}_(\d{{4}}-\d{{2}}[a-z]?)\.zim$")


def newest_edition(file_names: list[str], base: str) -> tuple[str, str] | None:
    """(file name, edition) with the newest edition; '2026-09b' sorts after '2026-09'."""
    pat = dated_pattern(base)
    hits = [(m.group(1), n) for n in file_names if (m := pat.match(n))]
    if not hits:
        return None
    edition, name = max(hits, key=lambda h: (h[0][:7], h[0][7:]))
    return name, edition


def listing_file_names(html: str) -> list[str]:
    return [unquote(h) for h in re.findall(r'href="([^"?/]+\.zim)"', html)]


def parse_meta4(xml: str) -> tuple[int | None, str | None]:
    root = ElementTree.fromstring(xml)
    ns = {"m": "urn:ietf:params:xml:ns:metalink"}
    f = root.find("m:file", ns)
    if f is None:
        return None, None
    size = f.findtext("m:size", default=None, namespaces=ns)
    sha = None
    for h in f.findall("m:hash", ns):
        if h.get("type") == "sha-256":
            sha = (h.text or "").strip().lower()
    return (int(size) if size else None), sha


def resolve_kiwix(src: KiwixSource | KiwixExternalSource, http: Http, canonical: bool = False) -> tuple[str, str, Upstream]:
    """`canonical` keeps the download URL on download.kiwix.org: a client may fetch it months later, when a mirror has moved on."""
    listing = KIWIX_LISTING.format(category=src.category)
    picked = None
    try:
        picked = newest_edition(listing_file_names(http.get_text(listing)), src.base)
    except Exception as e:  # noqa: BLE001 - the OPDS fallback is the point
        listing_error: Exception | None = e
    else:
        listing_error = None
    if picked is None:
        name_only = re.sub(r"_(maxi|nopic|mini)$", "", src.base)
        try:
            feed = http.get_text(KIWIX_OPDS.format(name=quote(name_only)))
        except Exception as e:  # noqa: BLE001
            raise ResolveError(f"kiwix {src.category}/{src.base}: listing failed ({listing_error}); OPDS failed ({e})") from e
        hrefs = re.findall(r'href="([^"]+\.zim)\.meta4"', feed)
        picked = newest_edition([h.rsplit("/", 1)[-1] for h in hrefs], src.base)
        if picked is None:
            raise ResolveError(f"kiwix {src.category}/{src.base}: no dated file in the listing or OPDS")
    file_name, edition = picked
    url = listing + file_name
    size, sha = None, None
    try:
        size, sha = parse_meta4(http.get_text(url + ".meta4"))
    except Exception:  # noqa: BLE001 - size comes from HEAD below, sha from the download
        pass
    if size is None:
        h = http.head(url)
        if h is None:
            raise ResolveError(f"kiwix {file_name}: listed but HEAD is 404")
        size = int(h["content-length"]) if "content-length" in h else None
    download_url = url if canonical else f"{KIWIX_DOWNLOAD_BASE}{src.category}/{file_name}"
    # A mirror syncs hours to days behind the canonical tree, so a freshly listed edition can be missing there.
    if download_url != url and http.head(download_url) is None:
        download_url = url
    return file_name, edition, Upstream(download_url, size, sha, "meta4" if sha else None)


# --- Direct URLs, HuggingFace, archive.org, Protomaps -------------------------------------------------------------

def resolve_url(url: str, http: Http) -> Upstream:
    h = http.head(url)
    if h is None:
        raise ResolveError(f"{url}: 404")
    size = int(h["content-length"]) if "content-length" in h else None
    sha, source = None, None
    m = re.match(r"https://huggingface\.co/([^/]+/[^/]+)/resolve/main/(.+)$", url)
    if m:
        try:
            tree = http.get_json(HF_TREE.format(repo=m.group(1)))
            for f in tree:
                if f.get("path") == unquote(m.group(2)) and f.get("lfs", {}).get("oid"):
                    sha, source = f["lfs"]["oid"].lower(), "hf"
                    size = size or f.get("size")
        except Exception:  # noqa: BLE001 - the sha is then computed on download
            pass
    return Upstream(url, size, sha, source, h.get("last-modified"))


def resolve_archive(src: ArchiveSource, http: Http) -> Upstream:
    meta = http.get_json(ARCHIVE_METADATA.format(item=src.item))
    files = meta.get("files", []) if isinstance(meta, dict) else []
    hit = next((f for f in files if f.get("name") == src.file), None)
    if hit is None:
        raise ResolveError(f"archive.org {src.item}: no file {src.file!r} (have {[f.get('name') for f in files if f.get('name', '').endswith('.pdf')]})")
    return Upstream(src.url, int(hit["size"]) if hit.get("size") else None, None, None)


def resolve_protomaps(http: Http, today: date | None = None, back: int = 7) -> tuple[str, Upstream]:
    """The newest daily planet build that answers HEAD, starting today."""
    start = today or datetime.now(timezone.utc).date()
    for i in range(back):
        d = (start - timedelta(days=i)).strftime("%Y%m%d")
        h = http.head(PROTOMAPS_BUILD.format(date=d))
        if h is not None:
            return d, Upstream(PROTOMAPS_BUILD.format(date=d), int(h["content-length"]) if "content-length" in h else None, None, None, h.get("last-modified"))
    raise ResolveError(f"protomaps: no build in the last {back} days")


def document_upstreams(src: DocumentsSource, http: Http) -> dict[str, Upstream | Exception]:
    out: dict[str, Upstream | Exception] = {}
    for d in src.documents:
        try:
            out[d.id] = resolve_archive(d.source, http) if isinstance(d.source, ArchiveSource) else resolve_url(d.source.url, http)
        except Exception as e:  # noqa: BLE001 - reported per document
            out[d.id] = e
    return out
