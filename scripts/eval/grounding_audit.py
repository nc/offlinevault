#!/usr/bin/env python3
"""Why did a cited claim get no quote? Holds each claim of an answer against the passage it cites.

    grounding_audit.py --results results/<run>.json --capture build/eval/<capture>-answers.json [--ids a,b] [--out FILE]

`--results` holds the answers to audit (claims and the labels they cite); `--capture` is a later batch run of the same
questions whose `sources[].text` carries the retrieved passages (retrieval is deterministic, so the passages pair with
the earlier answers by location). Each cited claim is classed as one of:

    quoted            the app did quote it (counted only when auditing the capture itself)
    number-missing    a number in the claim is nowhere in the passage
    wrong-passage     the passage shares fewer than a fifth of the claim's terms
    paraphrase        the passage is on topic but shares under 45 percent of the claim's terms in any 1 to 3 sentence window
    window            every claim term is in the passage, but spread beyond any 1 to 3 sentence window (sentence split or soft wrap)
    three-term        the best window reaches the threshold but matches fewer than three terms
    port-would-quote  this Python port of Grounding finds a quote the app did not (a port or app discrepancy to look at)
    no-passage        the cited label was not among the retrieved passages

This is a Python port of Core/Sources/OfflineVaultCore/LLM/Grounding.swift and CitationVerifier.terms. `--self-check`
compares the port against the app's quotes on the capture file itself and prints the disagreement count.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

THRESHOLD = 0.45
STOP = {"the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "be", "it", "this", "that", "as", "at", "by",
        "from", "not", "do", "if", "you", "your", "can", "will", "must", "should", "than", "then", "into", "over", "under", "about", "when",
        "where", "which", "who", "has", "have", "had", "was", "were", "its", "their", "they", "them", "there", "here", "also", "any", "all",
        "each", "may", "more", "most", "only", "other", "some", "such", "so", "no", "one", "two", "use", "used"}
CITATION = r"\[\d{1,2}(?:\s*,\s*\d{1,2})*\]"
SENTENCE = re.compile(rf"(?:[^.!?\n\[]|[.!?](?![\s\[]|$)|\[(?!\d{{1,2}}(?:\s*,\s*\d{{1,2}})*\]))+[.!?]*(?:\s*,?\s*{CITATION})*[.!?]*\n?|\n")
CITATION_RE = re.compile(rf"\s*,?\s*{CITATION}")
NUMBER = re.compile(r"\d[\d,]*(?:\.\d+)?")
LIST_MARKER = re.compile(r"^\s*(?:[-*•]|\d{1,2}[.)]|\**step \d{1,2}:?\**)\s*", re.IGNORECASE)


def terms(s: str) -> set[str]:
    return {w[:6] for w in re.split(r"[^0-9a-z]+", s.lower()) if len(w) >= 3 and w not in STOP}


def numbers(s: str) -> set[str]:
    return {m.group().replace(",", "").strip(".") for m in NUMBER.finditer(s)}


def units(s: str) -> list[str]:
    out, cursor = [], 0
    for m in SENTENCE.finditer(s):
        if m.start() > cursor:
            out.append(s[cursor:m.start()])
        out.append(m.group())
        cursor = m.end()
    if cursor < len(s):
        out.append(s[cursor:])
    return out


def cited_labels(unit: str) -> list[int]:
    labels: list[int] = []
    for m in CITATION_RE.finditer(unit):
        for n in re.findall(r"\d+", m.group()):
            if int(n) not in labels:
                labels.append(int(n))
    return labels


def claim_text(unit: str) -> str:
    return CITATION_RE.sub("", unit).strip()


def continues_in_lowercase(all_units: list[str], i: int) -> bool:
    for u in all_units[i + 1:]:
        stripped = u.lstrip()
        if not stripped:
            continue
        return stripped[0].islower() or stripped[0].isdigit()
    return False


def sentence_ranges(text: str) -> list[tuple[int, int]]:
    all_units = units(text)
    ranges: list[tuple[int, int]] = []
    start, wrapped = 0, False
    for i, unit in enumerate(all_units):
        lo, hi = start, start + len(unit)
        start = hi
        while lo < hi and text[lo].isspace():
            lo += 1
        while hi > lo and text[hi - 1].isspace():
            hi -= 1
        if hi <= lo:
            continue
        if wrapped and ranges:
            ranges[-1] = (ranges[-1][0], hi)
        else:
            ranges.append((lo, hi))
        ends_line, punctuated = unit.endswith("\n"), text[hi - 1] in ".!?:"
        wrapped = ends_line and not punctuated and (hi - lo >= 40 or continues_in_lowercase(all_units, i))
    return ranges


def best_quote(claim: str, passage: str) -> tuple[str | None, int, float, int]:
    """(window text, matched terms, score, window size) for the best 1 to 3 sentence window holding every claim number."""
    body = LIST_MARKER.sub("", claim)
    claim_terms, claim_numbers = terms(body), numbers(body)
    if not claim_terms:
        return None, 0, 0.0, 0
    sentences = sentence_ranges(passage)
    best = None
    for size in (1, 2, 3):
        if len(sentences) < size:
            break
        for i in range(len(sentences) - size + 1):
            window = passage[sentences[i][0]:sentences[i + size - 1][1]]
            if not claim_numbers <= numbers(window):
                continue
            matched = len(claim_terms & terms(window))
            rank = matched - 1.5 * (size - 1)
            if rank > (best[3] if best else 0):
                best = (window, matched, matched / len(claim_terms), rank, size)
    if not best:
        return None, 0, 0.0, 0
    return best[0], best[1], best[2], best[4]


def classify(claim: str, passage: str) -> tuple[str, dict]:
    body = LIST_MARKER.sub("", claim)
    claim_terms, claim_numbers = terms(body), numbers(body)
    window, matched, score, size = best_quote(claim, passage)
    whole = len(claim_terms & terms(passage)) / len(claim_terms) if claim_terms else 0
    info = {"window": window, "matched": matched, "score": round(score, 2), "size": size, "whole_passage_overlap": round(whole, 2),
            "claim_numbers": sorted(claim_numbers), "passage_has_numbers": claim_numbers <= numbers(passage)}
    if window and score >= THRESHOLD and matched >= min(3, len(claim_terms)):
        return "port-would-quote", info
    if claim_numbers and not claim_numbers <= numbers(passage):
        return "number-missing", info
    if window and score >= THRESHOLD:
        return "three-term", info
    if whole >= THRESHOLD:
        return "window", info
    if whole >= 0.2:
        return "paraphrase", info
    return "wrong-passage", info


def claims_of(answer: str) -> list[tuple[str, list[int]]]:
    out = []
    for unit in units(answer):
        labels = cited_labels(unit)
        text = claim_text(unit)
        if labels and not text.startswith("Unverified:"):
            out.append((text, labels))
    return out


def audit(results_items: list[dict], capture: list[dict], ids: set[str] | None) -> tuple[list[str], Counter]:
    by_id = {c["id"]: c for c in capture}
    lines, counts = [], Counter()
    for item in results_items:
        if ids and item["id"] not in ids:
            continue
        cap = by_id.get(item["id"])
        if not cap:
            lines.append(f"\n## {item['id']}: no capture\n")
            continue
        text_by_location = {s["location"]: s.get("text", "") for s in cap["sources"]}
        passage_by_label = {s["label"]: text_by_location.get(s["location"]) for s in item["sources"]}
        lines.append(f"\n## {item['id']} ({item['section']}, {item['outcome']}, {len(item['quotes'])} quotes in the run)\n")
        for claim, labels in claims_of(item["answer"]):
            verdicts = []
            for label in labels:
                passage = passage_by_label.get(label)
                if passage is None:
                    verdicts.append(("no-passage", label, {}))
                    continue
                kind, info = classify(claim, passage)
                verdicts.append((kind, label, info))
            # A claim with several citations is as good as its best passage.
            order = ["port-would-quote", "three-term", "window", "paraphrase", "number-missing", "wrong-passage", "no-passage"]
            kind, label, info = sorted(verdicts, key=lambda v: order.index(v[0]))[0]
            counts[kind] += 1
            lines.append(f"- **{kind}** [{label}] {claim}")
            if kind in ("window", "three-term", "port-would-quote") and info.get("window"):
                lines.append(f"  - best window ({info['size']} sentence(s), {info['matched']} terms, score {info['score']}): "
                             f"{info['window'].strip()[:400]!r}")
            elif kind == "number-missing":
                lines.append(f"  - claim numbers {info['claim_numbers']}; best window score {info['score']}")
            elif kind in ("paraphrase", "wrong-passage"):
                lines.append(f"  - whole-passage term overlap {info['whole_passage_overlap']}, best window score {info['score']}")
    return lines, counts


def self_check(capture: list[dict]) -> tuple[int, int, list[str]]:
    """Does the port quote what the app quoted? Returns (agreements, disagreements, notes)."""
    agree, disagree, notes = 0, 0, []
    for cap in capture:
        passage_by_label = {s["label"]: s.get("text", "") for s in cap["sources"]}
        app_quotes = {q["text"] for q in cap["quotes"]}
        port_quotes = set()
        for claim, labels in claims_of(cap["answer"]):
            for label in labels:
                passage = passage_by_label.get(label)
                if passage is None:
                    continue
                window, matched, score, _ = best_quote(claim, passage)
                if window and score >= THRESHOLD and matched >= min(3, len(terms(LIST_MARKER.sub("", claim)))):
                    port_quotes.add(window)
        a, d = len(app_quotes & port_quotes), len(app_quotes ^ port_quotes)
        agree += a
        disagree += d
        if d:
            notes.append(f"{cap['id']}: app only {sorted(app_quotes - port_quotes)[:2]} | port only {sorted(port_quotes - app_quotes)[:2]}")
    return agree, disagree, notes


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results", required=True)
    ap.add_argument("--capture", required=True)
    ap.add_argument("--ids")
    ap.add_argument("--out")
    ap.add_argument("--self-check", action="store_true")
    a = ap.parse_args(argv)
    capture = json.loads(Path(a.capture).read_text())
    items = json.loads(Path(a.results).read_text())["items"]
    ids = {i.strip() for i in a.ids.split(",")} if a.ids else None
    lines, counts = audit(items, capture, ids)
    head = ["# Grounding audit", "", f"Answers from `{a.results}`, passages from `{a.capture}`.", "",
            "| Class | Claims |", "|---|---|"] + [f"| {k} | {v} |" for k, v in counts.most_common()]
    if a.self_check:
        agree, disagree, notes = self_check(capture)
        head += ["", f"Self-check of this port against the app's own quotes on the capture: {agree} quotes agree, {disagree} differ."]
        head += [f"- {n}" for n in notes[:10]]
    text = "\n".join(head + lines) + "\n"
    if a.out:
        Path(a.out).write_text(text)
        print(f"wrote {a.out}: {dict(counts)}")
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
