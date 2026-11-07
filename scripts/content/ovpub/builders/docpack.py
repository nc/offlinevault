"""A document pack: the entry's PDFs plus one JSON sidecar each, in a tar.gz whose bytes depend only on the PDFs."""
from __future__ import annotations

import gzip
import io
import json
import tarfile
from pathlib import Path

from .. import fetch
from ..spec import LICENCES, ArchiveSource, DocumentsSource
from . import BuildContext
from ..resolve import Candidate


def documents_dir(ctx: BuildContext, entry_id: str) -> Path:
    return ctx.content / "documents" / entry_id


class DocpackBuilder:
    def inputs(self, cand: Candidate, ctx: BuildContext) -> dict:
        """Fetches every PDF (small) and records url, size and sha per document."""
        src = cand.entry.source
        assert isinstance(src, DocumentsSource)
        cache = fetch.HashCache(ctx.content)
        out: dict[str, dict] = {}
        d = documents_dir(ctx, cand.entry.id)
        for doc in src.documents:
            dest = d / doc.file_name
            if not (dest.exists() and fetch.is_pdf(dest)):
                if ctx.offline:
                    raise fetch.FetchError(f"{doc.id}: not cached and --offline")
                fetch.download_pdf(doc.source.url, dest, ctx.log)
            out[doc.id] = {"url": doc.source.url, "size": dest.stat().st_size, "sha256": cache.sha256(dest)}
        return out

    def build(self, cand: Candidate, ctx: BuildContext) -> Path:
        src = cand.entry.source
        assert isinstance(src, DocumentsSource)
        d = documents_dir(ctx, cand.entry.id)
        out = ctx.content / "packs" / f"{cand.entry.id}.tar.gz"
        out.parent.mkdir(parents=True, exist_ok=True)
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for doc in sorted(src.documents, key=lambda x: x.id):
                pdf = d / doc.file_name
                _add(tar, doc.file_name, pdf.read_bytes())
                side = {"title": doc.title, "publisher": doc.publisher, "licence": LICENCES[doc.licence].label, "role": cand.entry.role or "procedural",
                        "sourceURL": f"https://archive.org/details/{doc.source.item}" if isinstance(doc.source, ArchiveSource) else doc.source.url,
                        "summary": doc.summary}
                _add(tar, f"{doc.id}.json", (json.dumps({k: v for k, v in side.items() if v}, indent=2, ensure_ascii=False) + "\n").encode())
        tmp = out.with_suffix(".tmp")
        with open(tmp, "wb") as f:
            with gzip.GzipFile(fileobj=f, mode="wb", mtime=0) as gz:
                gz.write(buf.getvalue())
        tmp.replace(out)
        return out


def _add(tar: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mtime = 0
    info.mode = 0o644
    tar.addfile(info, io.BytesIO(data))
