"""Parsoid HTML from a MediaWiki site, cut down to the sections an article wants, with only freely licensed images.

Network calls go through `MediaWikiClient`; `sanitise` is a pure function over the HTML string so it can be
golden-tested. Parsoid marks every section with <section data-mw-section-id> and every image with
resource="./File:…", which is what the pruning and the licence lookup key on.
"""
from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, unquote

import requests
from bs4 import BeautifulSoup, NavigableString, Tag

from ..http import USER_AGENT
from .fragment import Attribution, Fragment, Image
from .spec import MediaWikiRef

ALLOWED_TAGS = {"section", "h2", "h3", "h4", "h5", "p", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tr", "th", "td",
                "caption", "b", "strong", "i", "em", "a", "figure", "figcaption", "img", "br", "blockquote", "code", "sup", "sub"}
KEEP_ATTRS = {"a": {"href"}, "img": {"src", "alt"}, "td": {"colspan", "rowspan"}, "th": {"colspan", "rowspan"}}
DROP_SELECTORS = (".navbox", ".infobox", ".reflist", ".mw-references-wrap", "ol.mw-references", "sup.reference", ".mw-ref", ".hatnote", "[role=note]",
                  ".mw-editsection", ".noprint", ".sistersitebox", "table.ambox", ".ambox", ".mw-empty-elt", "style", "script", "link", "meta",
                  ".IPA", ".shortdescription", ".sidebar", ".metadata", ".box-Multiple_issues", ".portal", ".mw-indicator", "span.noexcerpt",
                  "table.vertical-navbox", ".navbox-styles", "figure.mw-halign-center.noresize", "[typeof~='mw:Extension/math']", ".mwe-math-element",
                  "span[typeof='mw:DisplaySpace']", "[typeof~='mw:Extension/indicator']")
DROP_HEADINGS = {"see also", "references", "external links", "further reading", "notes", "explanatory notes", "bibliography", "sources", "footnotes",
                 "citations", "gallery"}
ALLOWED_IMAGE_LICENCES = ("public domain", "cc0", "cc by ", "cc by-sa ", "cc-by-", "pd")
IMAGE_WIDTH = 800


def normalise(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip().lower()


class MediaWikiClient:
    def __init__(self, cache: Path, offline: bool = False, session: requests.Session | None = None, log=print):
        self.cache = Path(cache)
        self.offline = offline
        self.session = session or requests.Session()
        self.session.headers["User-Agent"] = USER_AGENT
        self.log = log

    def _get(self, url: str, **kw) -> requests.Response:
        if self.offline:
            raise RuntimeError(f"offline: would fetch {url}")
        r = self.session.get(url, timeout=60, **kw)
        r.raise_for_status()
        return r

    def parsoid(self, ref: MediaWikiRef, revision: int | None) -> tuple[str, int, str]:
        """(html, revision id, canonical title). Cached by site/title/revision; a pinned revision never refetches."""
        title = ref.title.replace(" ", "_")
        d = self.cache / "mediawiki" / ref.site
        d.mkdir(parents=True, exist_ok=True)
        if revision:
            hit = d / f"{_safe(title)}@{revision}.html"
            if hit.exists():
                html = hit.read_text()
                return html, revision, _canonical_title(html) or ref.title
        url = f"https://{ref.site}/api/rest_v1/page/html/{quote(title, safe='')}" + (f"/{revision}" if revision else "")
        self.log(f"  fetching {ref.site}/{title}" + (f"@{revision}" if revision else ""))
        html = self._get(url).text
        rev = _revision_of(html)
        canonical = _canonical_title(html) or ref.title
        (d / f"{_safe(title)}@{rev}.html").write_text(html)
        return html, rev, canonical

    def image_info(self, site: str, file_titles: list[str]) -> dict[str, dict]:
        """File title -> {licence, artist, url, mime} via the wiki's imageinfo API (it resolves Commons files too)."""
        out: dict[str, dict] = {}
        for i in range(0, len(file_titles), 50):
            batch = file_titles[i:i + 50]
            params = {"action": "query", "titles": "|".join(f"File:{t}" for t in batch), "prop": "imageinfo", "iiprop": "extmetadata|url|mime|size",
                      "iiurlwidth": IMAGE_WIDTH, "format": "json", "formatversion": 2, "iiextmetadatafilter": "LicenseShortName|Artist|Credit"}
            data = self._get(f"https://{site}/w/api.php", params=params).json()
            for page in data.get("query", {}).get("pages", []):
                ii = (page.get("imageinfo") or [{}])[0]
                em = ii.get("extmetadata", {})
                title = page["title"].split(":", 1)[-1]
                out[title] = {"licence": _text(em.get("LicenseShortName", {}).get("value", "")), "artist": _text(em.get("Artist", {}).get("value", "")),
                              "url": ii.get("thumburl") or ii.get("url"), "mime": ii.get("mime")}
        return out

    def image_bytes(self, url: str) -> bytes:
        d = self.cache / "images"
        d.mkdir(parents=True, exist_ok=True)
        key = d / (hashlib.sha256(url.encode()).hexdigest()[:24] + ".bin")
        if key.exists():
            return key.read_bytes()
        data = self._get(url).content
        key.write_bytes(data)
        return data


def _safe(title: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.()-]", "_", title)[:150]


def _revision_of(html: str) -> int:
    m = re.search(r'Special:Redirect/revision/(\d+)', html)
    if not m:
        raise ValueError("Parsoid HTML without a revision id")
    return int(m.group(1))


def _canonical_title(html: str) -> str | None:
    m = re.search(r"<title>(.*?)</title>", html)
    return m.group(1).strip() if m else None


def _text(html: str) -> str:
    return re.sub(r"\s+", " ", BeautifulSoup(html, "lxml").get_text()).strip()


def licence_allowed(short_name: str) -> bool:
    s = short_name.lower().strip()
    return bool(s) and any(s.startswith(p) for p in ALLOWED_IMAGE_LICENCES) and "nc" not in s.split("-") and "nd" not in s.split("-")


def sanitise(html: str, keep_sections: tuple[str, ...], link_map: dict[str, str], own_slug: str) -> tuple[str, list[str]]:
    """Pure. Returns (fragment html, file titles referenced by its <img>s). Headings are demoted one level so a
    source's h2 sits under the article's own h2. Internal links to other Field Guide articles survive; every other
    link becomes plain text (there is no Wikipedia to link to offline)."""
    soup = BeautifulSoup(html, "lxml")
    body = soup.body or soup
    for sel in DROP_SELECTORS:
        for el in body.select(sel):
            el.decompose()
    wanted = {normalise(s) for s in keep_sections}
    kept: list[Tag] = []
    for sec in body.find_all("section", recursive=False):
        h = sec.find(["h2"], recursive=False)
        name = normalise(h.get_text()) if h else ""
        if wanted:
            if name in wanted:
                kept.append(sec)
        elif name not in DROP_HEADINGS:
            kept.append(sec)
    for sec in kept:
        for sub in sec.find_all("section"):
            h = sub.find(["h2", "h3", "h4", "h5"], recursive=False)
            if h and normalise(h.get_text()) in DROP_HEADINGS:
                sub.decompose()
    files: list[str] = []
    for sec in kept:
        for a in sec.find_all("a"):
            href = a.get("href", "")
            if href.startswith("./") and a.get("rel") == ["mw:WikiLink"]:
                target = unquote(href[2:]).split("#")[0].replace("_", " ")
                slug = link_map.get(target)
                if slug and slug != own_slug:
                    a.attrs = {"href": f"{slug}.html"}
                    continue
            a.unwrap()
        for fig in sec.find_all("figure"):
            img = fig.find("img")
            res = img.get("resource", "") if img else ""
            if not res.startswith("./File:"):
                fig.decompose()
                continue
            title = unquote(res[len("./File:"):]).replace("_", " ")
            files.append(title)
            img.attrs = {"src": title, "alt": img.get("alt", "")}
            cap = fig.find("figcaption")
            if cap is None:
                cap = soup.new_tag("figcaption")
                fig.append(cap)
        for img in sec.find_all("img"):
            if img.find_parent("figure") is None:
                img.decompose()
        for tag in sec.find_all(True):
            if tag.name in ("h2", "h3", "h4"):
                tag.name = {"h2": "h3", "h3": "h4", "h4": "h5"}[tag.name]
        for tag in list(sec.find_all(True)):
            if tag.name not in ALLOWED_TAGS:
                tag.unwrap()
                continue
            tag.attrs = {k: v for k, v in tag.attrs.items() if k in KEEP_ATTRS.get(tag.name, set())}
        sec.attrs = {}
    out = "".join(str(s) for s in kept)
    out = re.sub(r"<p>\s*</p>", "", out)
    out = re.sub(r"\n{2,}", "\n", out)
    return out, files


def fetch_fragment(ref: MediaWikiRef, client: MediaWikiClient, link_map: dict[str, str], own_slug: str, pinned: dict | None) -> Fragment:
    revision = pinned.get("revision") if pinned else None
    html, rev, canonical = client.parsoid(ref, revision)
    frag_html, file_titles = sanitise(html, ref.sections, link_map, own_slug)
    images: list[Image] = []
    if ref.images and file_titles:
        info = client.image_info(ref.site, sorted(set(file_titles)))
        soup = BeautifulSoup(frag_html, "lxml")
        for fig in soup.find_all("figure"):
            img = fig.find("img")
            meta = info.get(img["src"]) if img else None
            if not meta or not meta.get("url") or not licence_allowed(meta.get("licence", "")) or not str(meta.get("mime", "")).startswith("image/"):
                fig.decompose()
                continue
            data = client.image_bytes(meta["url"])
            ext = {"image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/svg+xml": "svg", "image/webp": "webp"}.get(meta["mime"], "bin")
            path = f"I/{hashlib.sha256(data).hexdigest()[:12]}.{ext}"
            credit = f"{meta.get('artist') or 'Unknown author'}, {meta['licence']}, via Wikimedia Commons"
            img.attrs = {"src": f"../{path}", "alt": img.get("alt", "")}
            cap = fig.find("figcaption")
            credit_tag = soup.new_tag("small")
            credit_tag.string = f" {credit}"
            cap.append(credit_tag)
            images.append(Image(path, data, credit, meta["licence"]))
        frag_html = "".join(str(c) for c in (soup.body.children if soup.body else soup.children))
    else:
        soup = BeautifulSoup(frag_html, "lxml")
        for fig in soup.find_all("figure"):
            fig.decompose()
        frag_html = "".join(str(c) for c in (soup.body.children if soup.body else soup.children))
    fetched = (pinned or {}).get("fetched") or datetime.now(timezone.utc).date().isoformat()
    site_name = {"en.wikipedia.org": "Wikipedia", "en.wikibooks.org": "Wikibooks"}.get(ref.site, ref.site)
    attribution = Attribution(title=canonical, url=f"https://{ref.site}/wiki/{quote(canonical.replace(' ', '_'))}?oldid={rev}",
                              revision=f"revision {rev} ({fetched})", licence="CC BY-SA 4.0", credit=f"{site_name} contributors")
    pin = {"revision": rev, "fetched": fetched, "images": [{"path": i.path, "licence": i.licence} for i in images]}
    return Fragment("mediawiki", f"From {site_name}: {canonical}", frag_html, attribution, images, pin)
