"""Pages of a public-domain PDF as readable HTML, with the PDF itself embedded once per ZIM."""
from __future__ import annotations

import hashlib
import html
import re
from collections import Counter
from pathlib import Path

from pypdf import PdfReader

from ..spec import LICENCES, ArchiveSource, Document
from .fragment import Attribution, Fragment
from .spec import PdfRef

BULLET = re.compile(r"^\s*[•●▪■\-−–❑☐]\s*(.*)$")
PAGE_LABEL = re.compile(r"^(\d+-\d+|[ivx]+|\d+|Page \d+ of \d+|\d+\s+Ready\.gov\s*)$", re.I)
PARA_NUMBER = re.compile(r"^(\d+-\d+\.\s+\S.*)$")
FIGURE = re.compile(r"^Figure \d+[-.]\d+\.?", re.I)
SECTION = re.compile(r"^(Section\s+[IVX]+\.|CHAPTER\s+\d+)", re.I)


LIGATURES = {"/f_i": "fi", "/f_l": "fl", "/f_f": "ff", "/f_f_i": "ffi", "/f_f_l": "ffl", "\ufb01": "fi", "\ufb02": "fl", "\ufb00": "ff", "\ufb03": "ffi", "\ufb04": "ffl"}


def page_texts(pdf: Path, lo: int, hi: int) -> list[str]:
    r = PdfReader(str(pdf))
    hi = min(hi, len(r.pages))
    out = []
    for i in range(lo - 1, hi):
        t = r.pages[i].extract_text() or ""
        for k in sorted(LIGATURES, key=len, reverse=True):
            t = t.replace(k, LIGATURES[k])
        out.append(t)
    return out


def pages_to_html(texts: list[str]) -> str:
    """Join lines into paragraphs, lift bullets into lists, ALL-CAPS and numbered paragraph titles into headings,
    and drop the running headers that repeat on most pages."""
    lines_per_page = [[ln.rstrip() for ln in t.splitlines()] for t in texts]
    counts = Counter(ln.strip() for page in lines_per_page for ln in set(page) if ln.strip())
    repeated = {ln for ln, n in counts.items() if n >= max(2, len(texts) // 2) and len(ln) < 120}
    blocks: list[tuple[str, str]] = []   # (kind, text) kind in p | h3 | h4 | li
    para: list[str] = []

    def flush():
        if para:
            text = " ".join(para)
            text = re.sub(r"(\w)- (\w)", r"\1\2", text)
            text = re.sub(r"\s+", " ", text).strip()
            if text:
                blocks.append(("p", text))
            para.clear()

    for page in lines_per_page:
        for raw in page:
            ln = raw.strip()
            if not ln:
                flush()
                continue
            if ln in repeated or PAGE_LABEL.match(ln) or FIGURE.match(ln):
                continue
            m = BULLET.match(ln)
            if m and m.group(1):
                flush()
                blocks.append(("li", m.group(1)))
                continue
            if PARA_NUMBER.match(ln) and len(ln) < 90:
                flush()
                blocks.append(("h4", ln))
                continue
            letters = re.sub(r"[^A-Za-z]", "", ln)
            if SECTION.match(ln) and len(ln) < 90:
                flush()
                blocks.append(("h3", ln))
                continue
            if len(letters) >= 4 and letters.isupper() and len(ln) < 80:
                flush()
                blocks.append(("h3", ln.title() if len(letters) > 12 else ln))
                continue
            if blocks and blocks[-1][0] == "li" and not para and (ln[0].islower() or raw.startswith(" ")):
                blocks[-1] = ("li", blocks[-1][1] + " " + ln)
                continue
            para.append(ln)
            if ln.endswith((".", ":", "!", "?")) and len(ln) < 60:
                flush()
        flush()
    out: list[str] = []
    in_list = False
    for kind, text in blocks:
        if kind == "li" and not in_list:
            out.append("<ul>")
            in_list = True
        if kind != "li" and in_list:
            out.append("</ul>")
            in_list = False
        out.append(f"<{'li' if kind == 'li' else kind}>{html.escape(text)}</{'li' if kind == 'li' else kind}>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def pdf_fragment(ref: PdfRef, doc: Document, pdf: Path | None, embed: bool, cached: Fragment | None = None) -> Fragment:
    """`pdf` is the local file (None under --offline with a snapshot); `embed` controls the P/<doc>.pdf link."""
    if pdf is None:
        assert cached is not None
        frag = cached
    else:
        texts = page_texts(pdf, *ref.pages)
        body = pages_to_html(texts)
        sha = hashlib.sha256(pdf.read_bytes()).hexdigest()
        source_url = f"https://archive.org/details/{doc.source.item}" if isinstance(doc.source, ArchiveSource) else doc.source.url
        lo, hi = ref.pages
        attribution = Attribution(title=doc.title, url=source_url, revision=f"pages {lo}–{hi} of the PDF" if hi > lo else f"page {lo} of the PDF",
                                  licence=LICENCES[doc.licence].label, credit=doc.publisher or "US Government")
        frag = Fragment("pdf", ref.heading or f"From {doc.title}", body, attribution, [], {"sha256": sha, "pages": f"{lo}-{hi}"})
    frag.pdf_path = f"P/{doc.id}.pdf" if embed else None
    frag.pdf_page = ref.pages[0]
    return frag
