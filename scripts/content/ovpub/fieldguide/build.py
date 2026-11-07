"""Guide data -> fragments (fetched, pinned or snapshotted) -> rendered pages -> ZIM."""
from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

from .. import fetch
from ..spec import Spec, load_spec
from .fragment import Fragment
from .mediawiki import MediaWikiClient, fetch_fragment
from .pdf import pdf_fragment
from .render import STYLE_CSS, render_about, render_article, render_index, render_section
from .spec import Article, Guide, GuideError, MediaWikiRef, PdfRef, load_guide
from .zimwriter import BlobItem, Page, metadata_for, write_zim

DESCRIPTION = ("OfflineVault's emergency procedures for water, food, first aid, shelter, fire, power, communications and household hazards, "
               "each adapted from public sources that are credited in place.")


@dataclass
class BuildResult:
    path: Path
    article_count: int
    image_count: int
    pdf_count: int
    skipped: list[tuple[str, str]] = field(default_factory=list)
    lock_changed: bool = False


class SourceUnavailable(Exception):
    pass


def inputs_digest(guide_dir: Path) -> dict[str, str]:
    """What a rebuild depends on: every YAML under the guide and the pinned revisions."""
    h = hashlib.sha256()
    for p in sorted(Path(guide_dir).glob("**/*.yaml")):
        h.update(str(p.relative_to(guide_dir)).encode())
        h.update(p.read_bytes())
    lock = Path(guide_dir) / "articles.lock.json"
    return {"articles": h.hexdigest(), "articlesLock": hashlib.sha256(lock.read_bytes()).hexdigest() if lock.exists() else ""}


def catalogue_for(guide_dir: Path) -> Spec:
    return load_spec(Path(guide_dir).parent / "catalogue-spec.json")


def pdf_location(guide_dir: Path, content: Path, doc_id: str, catalogue: Spec) -> Path:
    entry, doc = catalogue.documents()[doc_id]
    return content / "documents" / entry.id / doc.file_name


def collect_fragments(guide: Guide, guide_dir: Path, content: Path, cache: Path, offline: bool, refresh: bool, lock: dict, log) -> dict[str, list[Fragment]]:
    """Per slug, one Fragment per source. Online: fetch (honouring pins unless --refresh) and update `lock`.
    Offline: load committed snapshots; PDFs are not embedded because their bytes are not in the repo."""
    client = MediaWikiClient(cache, offline=offline, log=log)
    link_map = guide.wiki_titles()
    catalogue = None if offline else catalogue_for(guide_dir)
    out: dict[str, list[Fragment]] = {}
    for a in guide.articles:
        frags: list[Fragment] = []
        pins = lock.setdefault(a.slug, {})
        for i, src in enumerate(a.sources):
            snap_dir = guide_dir / "snapshots" / a.slug / str(i)
            if offline:
                if not (snap_dir / "fragment.json").exists():
                    raise SourceUnavailable(f"{a.slug}: no snapshot for source {i} ({src.key}); run `fieldguide.py snapshot --articles {a.slug}`")
                frag = Fragment.load(snap_dir)
                if isinstance(src, PdfRef):
                    frag = pdf_fragment(src, guide.documents[src.document], None, embed=False, cached=frag)
                frags.append(frag)
                continue
            if isinstance(src, MediaWikiRef):
                pinned = None if refresh else pins.get(src.key)
                frag = fetch_fragment(src, client, link_map, a.slug, pinned)
            else:
                doc = guide.documents[src.document]
                pdf = pdf_location(guide_dir, content, src.document, catalogue)
                if not (pdf.exists() and fetch.is_pdf(pdf)):
                    fetch.download_pdf(doc.source.url, pdf, log)
                frag = pdf_fragment(src, doc, pdf, embed=True)
            pins[src.key] = frag.pin
            frags.append(frag)
        out[a.slug] = frags
    return out


def build(guide_dir: Path, out: Path, build_date: date, cache: Path, only: tuple[str, ...] = (), offline: bool = False, refresh: bool = False,
          allow_partial: bool = False, content: Path | None = None, log=print) -> BuildResult:
    guide_dir = Path(guide_dir)
    content = Path(content or guide_dir.parents[2] / "content")
    catalogue = catalogue_for(guide_dir)
    guide = load_guide(guide_dir, catalogue, only)
    lock_path = guide_dir / "articles.lock.json"
    lock = json.loads(lock_path.read_text()) if lock_path.exists() else {}
    before = json.dumps(lock, sort_keys=True)
    skipped: list[tuple[str, str]] = []
    fragments: dict[str, list[Fragment]] = {}
    for a in guide.articles:
        try:
            fragments.update(collect_fragments(Guide(guide.sections, (a,), {}, guide.documents), guide_dir, content, cache, offline, refresh, lock, log))
        except Exception as e:  # noqa: BLE001 - reported per article; fatal unless --allow-partial
            if not allow_partial:
                raise
            skipped.append((a.slug, f"{type(e).__name__}: {e}"))
            log(f"  skipping {a.slug}: {e}")
    built = tuple(a for a in guide.articles if a.slug in fragments)
    guide = Guide(guide.sections, built, guide.smoke_queries, guide.documents)
    if not offline and json.dumps(lock, sort_keys=True) != before:
        lock_path.write_text(json.dumps(lock, indent=1, sort_keys=True, ensure_ascii=False) + "\n")

    by_slug = guide.by_slug()
    sections = {s.id: s for s in guide.sections}
    pages: list[Page] = []
    images: dict[str, BlobItem] = {}
    pdfs: dict[str, BlobItem] = {}
    for a in built:
        frags = fragments[a.slug]
        related = [(by_slug[r].title, f"{r}.html") for r in a.related if r in by_slug]
        pages.append(Page(a.path, a.title, render_article(a, frags, sections[a.section], related, build_date), True))
        for f in frags:
            for img in f.images:
                images.setdefault(img.path, BlobItem(img.path, _mime(img.path), img.data))
            if f.pdf_path and f.pdf_path not in pdfs:
                doc_id = f.pdf_path[2:-4]
                pdfs[f.pdf_path] = BlobItem(f.pdf_path, "application/pdf", pdf_location(guide_dir, content, doc_id, catalogue).read_bytes())
    used_sections = [s for s in guide.sections if guide.in_section(s.id)]
    for s in used_sections:
        pages.append(Page(s.path, s.title, render_section(s, guide.in_section(s.id)), False))
    counts = {"sections": len(used_sections), "images": len(images), "pdfs": len(pdfs)}
    pages.append(Page("index.html", "OfflineVault Field Guide", render_index(guide, build_date), False))
    pages.append(Page("about.html", "About this guide", render_about(guide, build_date, counts), False))
    blobs = [BlobItem("S/style.css", "text/css", STYLE_CSS.strip().encode())] + list(images.values()) + list(pdfs.values())
    illustration = (guide_dir / "illustration-48.png").read_bytes()
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    write_zim(out, pages, blobs, metadata_for(build_date, len(built), DESCRIPTION), illustration)
    log(f"  wrote {out} ({os.path.getsize(out):,} bytes): {len(built)} articles, {len(images)} images, {len(pdfs)} PDFs")
    return BuildResult(out, len(built), len(images), len(pdfs), skipped, lock_changed=json.dumps(lock, sort_keys=True) != before)


def snapshot(guide_dir: Path, slugs: tuple[str, ...], cache: Path, content: Path | None = None, log=print) -> int:
    """Writes snapshots/<slug>/<n>/fragment.json for the fixture articles, from the pinned sources."""
    guide_dir = Path(guide_dir)
    content = Path(content or guide_dir.parents[2] / "content")
    guide = load_guide(guide_dir, catalogue_for(guide_dir), slugs)
    lock_path = guide_dir / "articles.lock.json"
    lock = json.loads(lock_path.read_text()) if lock_path.exists() else {}
    n = 0
    for a in guide.articles:
        frags = collect_fragments(Guide(guide.sections, (a,), {}, guide.documents), guide_dir, content, cache, False, False, lock, log)[a.slug]
        for i, f in enumerate(frags):
            f.save(guide_dir / "snapshots" / a.slug / str(i))
            n += 1
    lock_path.write_text(json.dumps(lock, indent=1, sort_keys=True, ensure_ascii=False) + "\n")
    return n


def _mime(path: str) -> str:
    return {"jpg": "image/jpeg", "png": "image/png", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp"}.get(path.rsplit(".", 1)[-1], "application/octet-stream")


__all__ = ["build", "snapshot", "inputs_digest", "BuildResult", "GuideError", "Article"]
