"""What one source contributes to an article, and how it is kept on disk (snapshots, image files)."""
from __future__ import annotations

import base64
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Attribution:
    title: str
    url: str
    revision: str          # "revision 1379947008 (2026-10-12)" or "2015 edition, pages 16-31"
    licence: str           # "CC BY-SA 4.0" | "Public domain (US Government, 17 USC §105)"
    credit: str            # "Wikipedia contributors" | "US Army"


@dataclass(frozen=True)
class Image:
    path: str              # "I/3f9a2c1b0d7e.jpg"
    data: bytes
    credit: str
    licence: str


@dataclass
class Fragment:
    kind: str              # mediawiki | pdf
    heading: str
    html: str
    attribution: Attribution
    images: list[Image] = field(default_factory=list)
    pin: dict = field(default_factory=dict)   # what articles.lock.json stores for this source
    pdf_path: str | None = None               # "P/<document>.pdf" when the PDF is embedded
    pdf_page: int | None = None               # page the "Open the original PDF" link opens

    def save(self, directory: Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        body = {"kind": self.kind, "heading": self.heading, "html": self.html, "attribution": asdict(self.attribution), "pin": self.pin,
                "images": [{"path": i.path, "credit": i.credit, "licence": i.licence, "data": base64.b64encode(i.data).decode()} for i in self.images]}
        (directory / "fragment.json").write_text(json.dumps(body, indent=1, ensure_ascii=False) + "\n")

    @classmethod
    def load(cls, directory: Path) -> "Fragment":
        body = json.loads((directory / "fragment.json").read_text())
        return cls(kind=body["kind"], heading=body["heading"], html=body["html"], attribution=Attribution(**body["attribution"]), pin=body.get("pin", {}),
                   images=[Image(i["path"], base64.b64decode(i["data"]), i["credit"], i["licence"]) for i in body["images"]])
