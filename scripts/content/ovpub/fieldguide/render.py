"""HTML pages for the ZIM. Strings in, strings out; no network, no files."""
from __future__ import annotations

import html
import re
from datetime import date

from .fragment import Fragment
from .spec import Article, Guide, Section

STYLE_CSS = """
:root{--fg:#1d1d1f;--muted:#5b5b60;--accent:#0b6e4f;--warn:#9a3412;--bg:#fff;--rule:#e3e3e6}
@media (prefers-color-scheme:dark){:root{--fg:#ececf0;--muted:#a8a8b3;--accent:#5fcfa8;--warn:#f5a66d;--bg:#141416;--rule:#333338}}
html{font:16px/1.55 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;color:var(--fg);background:var(--bg)}
body{max-width:44em;margin:0 auto;padding:1.2em 1em 3em}
h1{font-size:1.7em;line-height:1.2;margin:.3em 0 .2em}h2{font-size:1.25em;margin:1.6em 0 .5em;border-top:1px solid var(--rule);padding-top:.8em}
h3{font-size:1.05em;margin:1.2em 0 .3em}h4,h5{font-size:1em;margin:1em 0 .2em}
nav.crumbs{font-size:.9em;color:var(--muted)}nav.crumbs a{color:var(--muted)}
p.summary{font-size:1.1em;color:var(--muted);margin-top:0}
.procedure{background:rgba(11,110,79,.07);border-left:4px solid var(--accent);padding:.2em 1em .6em;border-radius:4px}
.procedure h2{border:0;padding-top:.4em;margin-top:.4em}
.procedure ol,.procedure ul{padding-left:1.3em}.procedure li{margin:.3em 0}
p.warn{border-left:4px solid var(--warn);padding:.3em .8em;background:rgba(154,52,18,.08)}
p.credit,p.src,small{font-size:.85em;color:var(--muted)}
figure{margin:1em 0;text-align:center}figure img{max-width:100%;height:auto;border-radius:4px}figcaption{font-size:.85em;color:var(--muted)}
table{border-collapse:collapse;font-size:.9em;margin:1em 0;display:block;overflow-x:auto}td,th{border:1px solid var(--rule);padding:.3em .5em;vertical-align:top}
a{color:var(--accent)}ul.toc{list-style:none;padding:0}ul.toc li{margin:.4em 0}ul.toc .blurb{color:var(--muted);font-size:.9em}
footer{margin-top:3em;padding-top:1em;border-top:1px solid var(--rule);font-size:.85em;color:var(--muted)}
.related ul{padding-left:1.2em}
"""

FOOTER_LICENCE = ("Procedure text © OfflineVault, licensed CC BY-SA 4.0. Source texts are credited in each section; "
                  "Wikipedia text is CC BY-SA 4.0 and US Government works are in the public domain (17 USC §105).")


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def inline(md: str) -> str:
    s = esc(md)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"<em>\1</em>", s)
    return s


def markdown_subset(md: str) -> str:
    """Headings (###), ordered and bulleted lists with indented continuation lines, bold, italics, paragraphs,
    and `> ` lines as warnings. Enough for a procedure; anything else is written as a paragraph."""
    out: list[str] = []
    list_tag: str | None = None
    para: list[str] = []
    item: list[str] = []

    def close_para():
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>")
            para.clear()

    def close_item():
        if item:
            out.append(f"<li>{inline(' '.join(item))}</li>")
            item.clear()

    def close_list():
        nonlocal list_tag
        close_item()
        if list_tag:
            out.append(f"</{list_tag}>")
            list_tag = None

    for raw in md.splitlines():
        line = raw.rstrip()
        if not line.strip():
            close_para()
            close_list()
            continue
        m_h = re.match(r"^(#{1,4})\s+(.*)$", line)
        m_ol = re.match(r"^\s*\d+[.)]\s+(.*)$", line)
        m_ul = re.match(r"^\s*[-*]\s+(.*)$", line)
        if m_h:
            close_para(); close_list()
            level = min(max(len(m_h.group(1)), 3), 5)
            out.append(f"<h{level}>{inline(m_h.group(2))}</h{level}>")
        elif line.startswith(">"):
            close_para(); close_list()
            out.append(f'<p class="warn">{inline(line[1:].strip())}</p>')
        elif m_ol or m_ul:
            close_para()
            tag = "ol" if m_ol else "ul"
            if list_tag != tag:
                close_list()
                list_tag = tag
                out.append(f"<{tag}>")
            close_item()
            item.append((m_ol or m_ul).group(1))
        elif list_tag and raw.startswith((" ", "\t")):
            item.append(line.strip())
        else:
            close_list()
            para.append(line.strip())
    close_para()
    close_list()
    return "\n".join(out)


def page(title: str, body: str, css_href: str) -> str:
    return (f'<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>{esc(title)}</title><link rel="stylesheet" href="{css_href}"></head>\n<body>\n{body}\n</body></html>\n')


def render_article(a: Article, frags: list[Fragment], section: Section, related: list[tuple[str, str]], build_date: date) -> str:
    parts = [f'<nav class="crumbs"><a href="../index.html">OfflineVault Field Guide</a> › <a href="../{section.path}">{esc(section.title)}</a></nav>',
             f"<article>\n<h1>{esc(a.title)}</h1>\n<p class=\"summary\">{esc(a.summary)}</p>",
             f'<section class="procedure">\n<h2>What to do</h2>\n{markdown_subset(a.procedure)}\n</section>']
    if a.keywords:
        parts.append(f"<p class=\"keywords\"><small>Also: {esc(', '.join(a.keywords))}</small></p>")
    for f in frags:
        at = f.attribution
        parts.append(f'<section class="source">\n<h2>{esc(f.heading)}</h2>\n'
                     f'<p class="credit">Adapted from <a href="{esc(at.url)}">{esc(at.title)}</a> ({esc(at.revision)}), {esc(at.credit)}. {esc(at.licence)}.</p>\n'
                     f"{f.html}" + (f'\n<p class="src"><a href="../{esc(f.pdf_path)}#page={f.pdf_page}">Open the original PDF at page {f.pdf_page}</a></p>' if f.pdf_path else "") + "\n</section>")
    if related:
        parts.append('<section class="related">\n<h2>See also</h2>\n<ul>' + "".join(f'<li><a href="{esc(h)}">{esc(t)}</a></li>' for t, h in related) + "</ul>\n</section>")
    parts.append(f"</article>\n<footer>{esc(FOOTER_LICENCE)} Built {build_date.isoformat()}.</footer>")
    return page(a.title, "\n".join(parts), "../S/style.css")


def render_section(s: Section, articles: list[Article]) -> str:
    items = "".join(f'<li><a href="../{a.path}">{esc(a.title)}</a><div class="blurb">{esc(a.summary)}</div></li>' for a in articles)
    body = (f'<nav class="crumbs"><a href="../index.html">OfflineVault Field Guide</a></nav>\n<h1>{esc(s.title)}</h1>\n<p class="summary">{esc(s.blurb)}</p>'
            f'\n<ul class="toc">{items}</ul>')
    return page(f"{s.title} · OfflineVault Field Guide", body, "../S/style.css")


def render_index(guide: Guide, build_date: date) -> str:
    sections = []
    for s in guide.sections:
        arts = guide.in_section(s.id)
        if not arts:
            continue
        items = "".join(f'<li><a href="{a.path}">{esc(a.title)}</a></li>' for a in arts)
        sections.append(f'<h2><a href="{s.path}">{esc(s.title)}</a></h2><p class="blurb">{esc(s.blurb)}</p><ul class="toc">{items}</ul>')
    body = ("<h1>OfflineVault Field Guide</h1>\n<p class=\"summary\">Short procedures for emergencies at home, each followed by the public "
            "sources it was adapted from. Not a substitute for professional help when help is available.</p>\n" + "\n".join(sections) +
            f'\n<footer>{esc(FOOTER_LICENCE)} <a href="about.html">About this guide</a>. Built {build_date.isoformat()}.</footer>')
    return page("OfflineVault Field Guide", body, "S/style.css")


def render_about(guide: Guide, build_date: date, counts: dict) -> str:
    body = (f'<nav class="crumbs"><a href="index.html">OfflineVault Field Guide</a></nav>\n<h1>About this guide</h1>'
            f"<p>{len(guide.articles)} articles in {counts.get('sections', 0)} sections, {counts.get('images', 0)} images, {counts.get('pdfs', 0)} embedded PDFs. "
            f"Built {build_date.isoformat()} by OfflineVault's publisher from <code>scripts/content/fieldguide/</code>.</p>"
            f"<p>{esc(FOOTER_LICENCE)}</p><p>Each article has three parts: a procedure written by OfflineVault, the source passages it was adapted from "
            "(Wikipedia sections, or pages of a US Government manual), and the credit for each source with its revision or edition and licence.</p>"
            "<p>Images come from Wikimedia Commons only when their licence is public domain, CC0, CC BY or CC BY-SA; the credit sits under each image.</p>")
    return page("About · OfflineVault Field Guide", body, "S/style.css")
