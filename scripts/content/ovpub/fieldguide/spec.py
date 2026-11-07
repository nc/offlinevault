"""Article YAML -> Guide. Editors change data here, never code. Every problem is named with its file."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Union

import yaml

from ..spec import Document, Spec


@dataclass(frozen=True)
class MediaWikiRef:
    site: str
    title: str
    sections: tuple[str, ...] = ()
    images: bool = True

    @property
    def key(self) -> str:
        return f"mediawiki:{self.site}:{self.title}"


@dataclass(frozen=True)
class PdfRef:
    document: str
    pages: tuple[int, int]
    heading: str | None = None

    @property
    def key(self) -> str:
        return f"pdf:{self.document}:{self.pages[0]}-{self.pages[1]}"


SourceRef = Union[MediaWikiRef, PdfRef]


@dataclass(frozen=True)
class Article:
    slug: str
    section: str
    title: str
    summary: str
    procedure: str
    sources: tuple[SourceRef, ...]
    related: tuple[str, ...] = ()
    keywords: tuple[str, ...] = ()

    @property
    def path(self) -> str:
        return f"A/{self.slug}.html"


@dataclass(frozen=True)
class Section:
    id: str
    title: str
    blurb: str

    @property
    def path(self) -> str:
        return f"C/{self.id}.html"


@dataclass(frozen=True)
class Guide:
    sections: tuple[Section, ...]
    articles: tuple[Article, ...]
    smoke_queries: dict[str, str]
    documents: dict[str, Document]

    def by_slug(self) -> dict[str, Article]:
        return {a.slug: a for a in self.articles}

    def in_section(self, section_id: str) -> list[Article]:
        return [a for a in self.articles if a.section == section_id]

    def wiki_titles(self) -> dict[str, str]:
        """Wikipedia title -> slug of the article that adapts it, for rewriting links between articles."""
        out: dict[str, str] = {}
        for a in self.articles:
            for s in a.sources:
                if isinstance(s, MediaWikiRef) and s.site == "en.wikipedia.org":
                    out.setdefault(s.title.replace("_", " "), a.slug)
        return out


class GuideError(ValueError):
    def __init__(self, problems: list[str]):
        super().__init__("\n".join(problems))
        self.problems = problems


def load_guide(root: Path, catalogue: Spec, only: tuple[str, ...] = ()) -> Guide:
    root = Path(root)
    problems: list[str] = []
    data = yaml.safe_load((root / "sections.yaml").read_text())
    sections = tuple(Section(s["id"], s["title"], s.get("blurb", "")) for s in data["sections"])
    smoke = dict(data.get("smoke_queries", {}))
    documents = {did: doc for did, (_, doc) in catalogue.documents().items()}
    articles: list[Article] = []
    for path in sorted((root / "articles").glob("*/*.yaml")):
        try:
            articles.append(_parse_article(path, {s.id for s in sections}, documents))
        except GuideError as e:
            problems.extend(e.problems)
    if only:
        missing = set(only) - {a.slug for a in articles}
        if missing:
            problems.append(f"--articles: unknown slugs {sorted(missing)}")
        articles = [a for a in articles if a.slug in set(only)]
    slugs: dict[str, str] = {}
    for a in articles:
        if a.slug in slugs:
            problems.append(f"{a.slug}: duplicate slug")
        slugs[a.slug] = a.section
    if not only:
        for a in articles:
            for r in a.related:
                if r not in slugs:
                    problems.append(f"{a.slug}.related: {r} is not an article")
        for q, slug in smoke.items():
            if slug not in slugs:
                problems.append(f"smoke_queries[{q!r}]: {slug} is not an article")
    if problems:
        raise GuideError(sorted(set(problems)))
    return Guide(sections, tuple(articles), smoke, documents)


def _parse_article(path: Path, section_ids: set[str], documents: dict[str, Document]) -> Article:
    raw = yaml.safe_load(path.read_text())
    where = f"{path.parent.name}/{path.name}"
    p: list[str] = []
    for key in ("title", "summary", "procedure", "sources"):
        if key not in raw:
            p.append(f"{where}: {key} missing")
    slug = raw.get("slug", path.stem)
    if slug != path.stem:
        p.append(f"{where}: slug {slug!r} must match the file name")
    section = raw.get("section", path.parent.name)
    if section not in section_ids:
        p.append(f"{where}: section {section!r} is not in sections.yaml")
    sources: list[SourceRef] = []
    for i, s in enumerate(raw.get("sources", [])):
        kind = s.get("kind")
        if kind == "mediawiki":
            if not s.get("title"):
                p.append(f"{where}: sources[{i}] needs a title")
            sources.append(MediaWikiRef(s.get("site", "en.wikipedia.org"), s["title"].replace("_", " "), tuple(s.get("sections", ())), bool(s.get("images", True))))
        elif kind == "pdf":
            doc = s.get("document")
            if doc not in documents:
                p.append(f"{where}: sources[{i}] document {doc!r} is not in catalogue-spec.json")
            pages = str(s.get("pages", ""))
            try:
                a, _, b = pages.partition("-")
                lo, hi = int(a), int(b or a)
                if lo < 1 or hi < lo:
                    raise ValueError
            except ValueError:
                p.append(f"{where}: sources[{i}] pages {pages!r} must be like 12-19")
                lo, hi = 1, 1
            sources.append(PdfRef(doc, (lo, hi), s.get("heading")))
        else:
            p.append(f"{where}: sources[{i}] kind {kind!r} is not mediawiki or pdf")
    if not sources and "sources" in raw:
        p.append(f"{where}: at least one source")
    if p:
        raise GuideError(p)
    return Article(slug=slug, section=section, title=raw["title"], summary=raw["summary"], procedure=raw["procedure"],
                   sources=tuple(sources), related=tuple(raw.get("related", ())), keywords=tuple(raw.get("keywords", ())))
