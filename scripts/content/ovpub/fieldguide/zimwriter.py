"""The only module that imports libzim.writer. Pages, blobs and metadata in; a ZIM with a full-text index out."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from pathlib import Path

from libzim.writer import Blob, Creator, Hint, Item, StringProvider, ContentProvider


@dataclass(frozen=True)
class Page:
    path: str
    title: str
    html: str
    front: bool


@dataclass(frozen=True)
class BlobItem:
    path: str
    mime: str
    data: bytes


class _BytesProvider(ContentProvider):
    def __init__(self, data: bytes):
        super().__init__()
        self.data = data
        self.sent = False

    def get_size(self) -> int:
        return len(self.data)

    def feed(self) -> Blob:
        if self.sent:
            return Blob("")
        self.sent = True
        return Blob(self.data)


class _Item(Item):
    def __init__(self, path: str, title: str, mime: str, provider_factory, front: bool):
        super().__init__()
        self._path, self._title, self._mime, self._factory, self._front = path, title, mime, provider_factory, front

    def get_path(self) -> str:
        return self._path

    def get_title(self) -> str:
        return self._title

    def get_mimetype(self) -> str:
        return self._mime

    def get_contentprovider(self):
        return self._factory()

    def get_hints(self) -> dict:
        return {Hint.FRONT_ARTICLE: self._front}


def write_zim(out: Path, pages: list[Page], blobs: list[BlobItem], metadata: dict[str, str], illustration_png: bytes, main_path: str = "index.html") -> None:
    tmp = out.with_name(out.name + ".tmp")
    tmp.unlink(missing_ok=True)
    with Creator(str(tmp)).config_indexing(True, "eng").config_clustersize(1 << 20) as c:
        c.set_mainpath(main_path)
        # Before any item: python-libzim 3.13.1 keeps the GIL inside add_illustration, and if that call lands on a
        # full cluster libzim's writer thread waits for the GIL while the main thread waits for the queue (measured:
        # a 25-minute hang became 4.4 s once the illustration went in first, when no cluster can be full).
        c.add_illustration(48, illustration_png)
        for p in pages:
            c.add_item(_Item(p.path, p.title, "text/html", lambda h=p.html: StringProvider(h), p.front))
        for b in blobs:
            c.add_item(_Item(b.path, b.path.rsplit("/", 1)[-1], b.mime, lambda d=b.data: _BytesProvider(d), False))
        for k, v in metadata.items():
            c.add_metadata(k, v)
    tmp.replace(out)


def metadata_for(build_date: date, article_count: int, description: str) -> dict[str, str]:
    return {
        "Name": "fieldguide_en",
        "Title": "OfflineVault Field Guide",
        "Description": description[:80],
        "LongDescription": description,
        "Language": "eng",
        "Creator": "OfflineVault",
        "Publisher": "OfflineVault",
        "Date": build_date.isoformat(),
        "License": "CC BY-SA 4.0; US Government works public domain",
        "Tags": "_category:other;_ftindex:yes;_pictures:yes;_videos:no;_details:yes;preparedness;first aid",
        "Scraper": "ovpub.fieldguide",
        "Source": "https://github.com/offlinevault",
    }
