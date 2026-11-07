#!/usr/bin/env python3
"""OfflineVault accuracy eval: send every question to an answer provider, score deterministically, publish the failures.

    run_eval.py validate [--questions FILE]                      check questions.yaml against the Field Guide on disk
    run_eval.py run --provider stub --answers FILE [opts]        score canned answers (tests, dry runs)
    run_eval.py run --provider http --url URL [opts]             score a live endpoint (see README.md for the contract)
    run_eval.py run --provider file --answers FILE [opts]        score the app's batch output (OFFLINEVAULT_ASK_OUT, a JSON array)
    run_eval.py export --out FILE [--ids --section --limit]      write [{id, question}] for the app's batch mode
    run_eval.py report results/a.json results/b.json ...         Markdown comparing several runs, with every wrong or harmful answer

Options for run: --models NAME[,NAME]  --run-id ID  --out DIR  --ids ID,ID  --section S  --limit N  --timeout SEC
                 --judge-url URL | --judge-answers FILE   optional second-pass judge, reported beside the deterministic score

Standard library plus PyYAML only.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scoring import OUTCOMES, Answer, Fact, Question, Scorer, Verdict  # noqa: E402

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
QUESTIONS = HERE / "questions.yaml"
ARTICLES = ROOT / "scripts" / "content" / "fieldguide" / "articles"
SECTIONS = ROOT / "scripts" / "content" / "fieldguide" / "sections.yaml"
CATALOGUE = ROOT / "scripts" / "content" / "catalogue-spec.json"
PROMPTING = ROOT / "Core" / "Sources" / "OfflineVaultCore" / "LLM" / "Prompting.swift"

EXPECTS = ("answer", "refuse")
COVERAGES = ("fieldguide", "catalogue", "none")


# ---------------------------------------------------------------- loading and validation

def load(path: Path = QUESTIONS) -> tuple[dict, list[Question], Scorer]:
    config = yaml.safe_load(path.read_text())
    scorer = Scorer.from_config(config)
    questions = [parse_question(raw, scorer) for raw in config.get("questions") or []]
    return config, questions, scorer


def parse_question(raw: dict, scorer: Scorer) -> Question:
    return Question(
        id=str(raw["id"]), section=str(raw["section"]), question=str(raw["question"]),
        expect=str(raw.get("expect", "answer")), coverage=str(raw.get("coverage", "fieldguide")),
        gold=tuple(Fact.parse(f, scorer.norm) for f in raw.get("gold") or []),
        harmful=tuple(Fact.parse(f, scorer.norm) for f in raw.get("harmful") or []),
        sources=tuple(raw.get("sources") or []), refuse_category=raw.get("refuse_category"), notes=raw.get("notes"),
    )


def article_ids() -> dict[str, str]:
    return {p.stem: p.parent.name for p in ARTICLES.glob("*/*.yaml")}


def section_ids() -> set[str]:
    return {s["id"] for s in yaml.safe_load(SECTIONS.read_text())["sections"]}


def catalogue_ids() -> set[str]:
    return {e["id"] for e in json.loads(CATALOGUE.read_text())["entries"]}


def refuse_categories() -> set[str]:
    text = PROMPTING.read_text()
    start = text.index("enum HighStakes")
    line = text[start:].split("\n", 2)[1]
    return {c.strip() for c in line.split("case", 1)[1].split(",")}


def validate(path: Path = QUESTIONS) -> list[str]:
    """Every problem named with its question id. An empty list means the file is publishable."""
    problems: list[str] = []
    try:
        config, questions, _ = load(path)
    except Exception as e:  # noqa: BLE001  the loader's own message is the diagnosis
        return [f"cannot load {path}: {e}"]
    articles, sections, catalogue, categories = article_ids(), section_ids(), catalogue_ids(), refuse_categories()
    seen: Counter[str] = Counter(q.id for q in questions)
    problems += [f"duplicate id {i}" for i, n in seen.items() if n > 1]
    for q in questions:
        p = problems.append
        if q.section not in sections:
            p(f"{q.id}: unknown section {q.section!r}")
        if q.expect not in EXPECTS:
            p(f"{q.id}: expect must be one of {EXPECTS}")
        if q.coverage not in COVERAGES:
            p(f"{q.id}: coverage must be one of {COVERAGES}")
        if not q.question.strip():
            p(f"{q.id}: empty question")
        if not q.gold:
            p(f"{q.id}: no gold facts")
        if not q.sources:
            p(f"{q.id}: no sources")
        if q.expect == "refuse":
            if q.refuse_category not in categories:
                p(f"{q.id}: refuse_category must be one of {sorted(categories)}")
            if not q.harmful:
                p(f"{q.id}: a refuse question needs the harmful statements a wrong answer would contain")
        elif q.refuse_category:
            p(f"{q.id}: refuse_category only applies to expect: refuse")
        for s in q.sources:
            if not isinstance(s, dict):
                p(f"{q.id}: source must be a mapping, got {s!r}")
                continue
            if "article" in s:
                if s["article"] not in articles:
                    p(f"{q.id}: Field Guide article {s['article']!r} does not exist on disk")
                if not s.get("cites"):
                    p(f"{q.id}: source {s['article']} needs `cites` (the manual the article's sources block names)")
            elif "catalogue" in s:
                if s["catalogue"] not in catalogue:
                    p(f"{q.id}: catalogue entry {s['catalogue']!r} is not in catalogue-spec.json")
                if not s.get("title"):
                    p(f"{q.id}: catalogue source needs `title`")
            elif "code" in s:
                if not (ROOT / s["code"]).exists():
                    p(f"{q.id}: code source {s['code']} does not exist")
            else:
                p(f"{q.id}: source needs one of article / catalogue / code")
        if q.coverage == "fieldguide" and not any(isinstance(s, dict) and "article" in s for s in q.sources):
            p(f"{q.id}: coverage fieldguide but no article source")
    return problems


# ---------------------------------------------------------------- providers

def stub_provider(answers_path: Path):
    canned = json.loads(Path(answers_path).read_text())

    def ask(q: Question) -> Answer:
        raw = canned.get(q.id)
        if raw is None:
            return Answer(error="no canned answer")
        if isinstance(raw, str):
            return Answer(text=raw)
        return Answer(text=raw.get("answer", ""), quotes=raw.get("quotes") or [], sources=raw.get("sources") or [])
    return ask


def file_provider(answers_path: Path):
    """The app's batch output: a JSON array of {id, question, answer, quotes, sources, refused, seconds}, one per question."""
    records = {str(r["id"]): r for r in json.loads(Path(answers_path).read_text())}

    def ask(q: Question) -> Answer:
        r = records.get(q.id)
        if r is None:
            return Answer(error="no answer in file")
        return Answer(text=str(r.get("answer", "")), quotes=r.get("quotes") or [], sources=r.get("sources") or [],
                      error=r.get("error"), refused=bool(r.get("refused")), seconds=r.get("seconds"))
    return ask


def http_provider(url: str, timeout: float):
    def ask(q: Question) -> Answer:
        body = json.dumps({"id": q.id, "question": q.question}).encode()
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = json.loads(resp.read().decode())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
            return Answer(error=str(e))
        return Answer(text=str(raw.get("answer", "")), quotes=raw.get("quotes") or [], sources=raw.get("sources") or [])
    return ask


def http_judge(url: str, timeout: float):
    def judge(q: Question, a: Answer, v: Verdict) -> dict:
        body = json.dumps({"id": q.id, "question": q.question, "answer": a.text, "expect": q.expect,
                           "gold": [f.text for f in q.gold], "harmful": [f.text for f in q.harmful]}).encode()
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
            return {"error": str(e)}
    return judge


def stub_judge(path: Path):
    canned = json.loads(Path(path).read_text())
    return lambda q, a, v: canned.get(q.id, {"error": "no canned judgement"})


# ---------------------------------------------------------------- running and reporting

def run(questions: list[Question], scorer: Scorer, ask, meta: dict, judge=None) -> dict:
    items = []
    for q in questions:
        a = ask(q)
        v = scorer.score(q, a)
        item = {"id": q.id, "section": q.section, "expect": q.expect, "coverage": q.coverage, "question": q.question,
                "outcome": v.outcome, "matched": v.matched, "missing": v.missing, "harmful_hits": v.harmful_hits,
                "refusal_marker": v.refusal_marker, "grounded": v.grounded, "grounding": v.grounding,
                "answer": a.text, "quotes": a.quotes, "sources": a.sources, "error": a.error,
                "refused": a.refused, "seconds": a.seconds}
        if judge:
            item["judge"] = judge(q, a, v)
        items.append(item)
        print(f"  {q.id:28} {v.outcome}", file=sys.stderr)
    result = {**meta, "totals": totals(items), "by_section": by_section(items), "items": items}
    return result


def totals(items: list[dict]) -> dict:
    counts = Counter(i["outcome"] for i in items)
    answerable = [i for i in items if i["expect"] == "answer"]
    refusable = [i for i in items if i["expect"] == "refuse"]
    graded = [i["grounding"] for i in items if i["grounding"] is not None]
    judged = Counter(str((i.get("judge") or {}).get("verdict", "none")) for i in items if "judge" in i)
    timed = sorted(i["seconds"] for i in items if i.get("seconds") is not None)
    return {
        "questions": len(items),
        "outcomes": {o: counts.get(o, 0) for o in OUTCOMES},
        "accuracy": _ratio(counts["supported"], len(answerable)),
        "accuracy_with_partial": _ratio(counts["supported"] + 0.5 * counts["partial"], len(answerable)),
        "harmful": counts["harmful"],
        "refusal_accuracy": _ratio(counts["refused-correctly"], len(refusable)),
        "grounding": (sum(graded) / len(graded)) if graded else None,
        "errors": sum(1 for i in items if i["error"]),
        "judge": dict(judged) if judged else None,
        "median_seconds": _median(timed),
    }


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    mid = len(values) // 2
    return round(values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2, 1)


def by_section(items: list[dict]) -> dict:
    groups: dict[str, list[dict]] = defaultdict(list)
    for i in items:
        groups[i["section"]].append(i)
    return {s: totals(g) for s, g in sorted(groups.items())}


def _ratio(n: float, d: int) -> float | None:
    return round(n / d, 4) if d else None


def markdown(result: dict) -> str:
    t = result["totals"]
    lines = [f"# Eval run `{result['run_id']}`", "",
             f"Models: {', '.join(result['models']) or 'unspecified'}. Provider: {result['provider']}. "
             f"Questions file: {result['questions_file']} (sha256 {result['questions_sha256'][:12]}). Run at {result['created']}.", "",
             "## Totals", "",
             "| Model | Questions | Supported | Partial | Wrong | Harmful | Refused correctly | Refused wrongly | Not refused | Accuracy | With partial | Grounding |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    o = t["outcomes"]
    for model in result["models"] or ["unspecified"]:
        lines.append(f"| {model} | {t['questions']} | {o['supported']} | {o['partial']} | {o['wrong']} | {o['harmful']} | "
                     f"{o['refused-correctly']} | {o['refused-wrongly']} | {o['not-refused']} | {_pct(t['accuracy'])} | "
                     f"{_pct(t['accuracy_with_partial'])} | {_pct(t['grounding'])} |")
    if t["judge"]:
        lines += ["", "Judge model verdicts (second pass, informational, never replaces the row above): " +
                  ", ".join(f"{k} {v}" for k, v in sorted(t["judge"].items()))]
    if t.get("median_seconds") is not None:
        lines += ["", f"Median seconds per answer: {t['median_seconds']}."]
    lines += ["", "## By section", "",
              "| Section | Questions | Supported | Partial | Wrong | Harmful | Refused correctly | Refused wrongly | Not refused | Accuracy |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    for s, st in result["by_section"].items():
        so = st["outcomes"]
        lines.append(f"| {s} | {st['questions']} | {so['supported']} | {so['partial']} | {so['wrong']} | {so['harmful']} | "
                     f"{so['refused-correctly']} | {so['refused-wrongly']} | {so['not-refused']} | {_pct(st['accuracy'])} |")
    failures = [i for i in result["items"] if i["outcome"] in ("wrong", "harmful", "refused-wrongly", "not-refused")]
    lines += ["", f"## Failures ({len(failures)})", "",
              "Every wrong, harmful, wrongly refused or not-refused answer, with the model's full text."]
    for i in failures:
        lines += ["", f"### {i['id']} ({i['section']}, {i['outcome']})", "", f"**Q:** {i['question']}", ""]
        if i["harmful_hits"]:
            lines.append("**Harmful statements matched:** " + "; ".join(i["harmful_hits"]))
        if i["missing"]:
            lines.append("**Gold facts missing:** " + "; ".join(i["missing"]))
        if i["matched"]:
            lines.append("**Gold facts present:** " + "; ".join(i["matched"]))
        if i["error"]:
            lines.append(f"**Provider error:** {i['error']}")
        if i.get("judge"):
            lines.append(f"**Judge:** {json.dumps(i['judge'])}")
        lines += ["", "**Model answer:**", ""] + ["> " + ln for ln in (i["answer"] or "(empty)").splitlines()]
    partials = [i for i in result["items"] if i["outcome"] == "partial"]
    if partials:
        lines += ["", f"## Partial ({len(partials)})", "", "| Id | Missing gold facts |", "|---|---|"]
        lines += [f"| {i['id']} | {'; '.join(i['missing'])} |" for i in partials]
    return "\n".join(lines) + "\n"


def triaged(result: dict, overrides: dict) -> dict:
    """The run with each listed item's outcome replaced by a reviewer's call, and the totals recomputed."""
    items = [{**i, "outcome": overrides[i["id"]]["outcome"]} if i["id"] in overrides else i for i in result["items"]]
    return {**result, "items": items, "totals": totals(items), "by_section": by_section(items)}


def _totals_row(r: dict) -> str:
    t, o = r["totals"], r["totals"]["outcomes"]
    median = t.get("median_seconds")
    return (f"| {r['run_id']} | {', '.join(r['models'])} | {t['questions']} | {o['supported']} | {o['partial']} | {o['wrong']} | "
            f"{o['harmful']} | {o['refused-correctly']} | {o['refused-wrongly']} | {o['not-refused']} | {_pct(t['accuracy'])} | "
            f"{_pct(t['accuracy_with_partial'])} | {_pct(t['grounding'])} | {'n/a' if median is None else median} |")


TOTALS_HEADER = ["| Run | Model | Questions | Supported | Partial | Wrong | Harmful | Refused correctly | Refused wrongly | Not refused | "
                 "Accuracy | With partial | Grounding | Median s |",
                 "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]


def comparison(results: list[dict], intro: str = "", triage: dict | None = None) -> str:
    """Every run side by side, then every wrong or harmful answer of every run with the gold fact it missed.

    `triage` maps run id to {question id: {outcome, reason}}: a reviewer's calls on scorer false positives. The raw table
    stays as scored; a second table shows the totals with those calls applied, and every call is listed under it."""
    lines = ["# Eval results", "",
             "One row per run of `scripts/eval/questions.yaml` (see `rubric.md` for the outcomes). Each run's full results, "
             "including every answer and its quotes, sit in `<run-id>.json` and `<run-id>.md` beside this file.", ""]
    if intro:
        lines += [intro.strip(), ""]
    lines += ["## As scored", ""] + TOTALS_HEADER + [_totals_row(r) for r in results]
    if triage:
        lines += ["", "## After triage", "",
                  "The same runs with the reviewer's calls below applied (a scorer false positive rescored, a refusal rerun substituted). "
                  "Every call is listed so the reader can disagree.", ""] + TOTALS_HEADER
        lines += [_totals_row(triaged(r, triage.get(r["run_id"], {}))) for r in results]
        for r in results:
            raw = {i["id"]: i["outcome"] for i in r["items"]}
            for qid, call in triage.get(r["run_id"], {}).items():
                if qid in raw:
                    lines.append(f"- `{r['run_id']}` {qid}: {raw[qid]} to {call['outcome']}. {call['reason']}")
    sections = sorted({s for r in results for s in r["by_section"]})
    lines += ["", "## Accuracy by section", "", "| Section | " + " | ".join(r["run_id"] for r in results) + " |",
              "|---|" + "---|" * len(results)]
    for s in sections:
        lines.append(f"| {s} | " + " | ".join(_pct(r["by_section"].get(s, {}).get("accuracy")) for r in results) + " |")
    for r in results:
        failures = [i for i in r["items"] if i["outcome"] in ("wrong", "harmful")]
        lines += ["", f"## Wrong and harmful answers: {r['run_id']} ({len(failures)})"]
        for i in failures:
            lines += ["", f"### {i['id']} ({i['section']}, {i['outcome']})", "", f"**Q:** {i['question']}", ""]
            if i["harmful_hits"]:
                lines.append("**Harmful statements matched:** " + "; ".join(i["harmful_hits"]))
            if i["missing"]:
                lines.append("**Gold facts missing:** " + "; ".join(i["missing"]))
            if i["error"]:
                lines.append(f"**Provider error:** {i['error']}")
            lines += ["", "**Model answer:**", ""] + ["> " + ln for ln in (i["answer"] or "(empty)").splitlines()]
    return "\n".join(lines) + "\n"


def _pct(x) -> str:
    return "n/a" if x is None else f"{100 * x:.0f}%"


# ---------------------------------------------------------------- CLI

def cmd_validate(a) -> int:
    problems = validate(Path(a.questions))
    for p in problems:
        print("  " + p)
    _, questions, _ = load(Path(a.questions)) if not problems else (None, [], None)
    if not problems:
        print(f"ok: {len(questions)} questions, " + ", ".join(f"{k} {v}" for k, v in sorted(Counter(q.expect for q in questions).items())))
    return 1 if problems else 0


def cmd_run(a) -> int:
    qpath = Path(a.questions)
    problems = validate(qpath)
    if problems:
        print("questions file is not valid:\n  " + "\n  ".join(problems))
        return 2
    _, questions, scorer = load(qpath)
    questions = narrow(questions, a)
    if a.provider in ("stub", "file"):
        if not a.answers:
            print(f"--provider {a.provider} needs --answers FILE")
            return 2
        ask = (stub_provider if a.provider == "stub" else file_provider)(Path(a.answers))
    else:
        if not a.url:
            print("--provider http needs --url URL")
            return 2
        ask = http_provider(a.url, a.timeout)
    judge = http_judge(a.judge_url, a.timeout) if a.judge_url else (stub_judge(Path(a.judge_answers)) if a.judge_answers else None)
    models = [m.strip() for m in (a.models or "").split(",") if m.strip()]
    created = datetime.now(timezone.utc).replace(microsecond=0)
    run_id = a.run_id or f"{created.strftime('%Y%m%dT%H%M%SZ')}-{a.provider}" + (f"-{models[0]}" if models else "")
    import hashlib
    meta = {"run_id": run_id, "created": created.isoformat(), "provider": a.provider, "models": models,
            "endpoint": a.url, "questions_file": str(qpath.relative_to(ROOT) if qpath.is_relative_to(ROOT) else qpath),
            "questions_sha256": hashlib.sha256(qpath.read_bytes()).hexdigest(), "judge": a.judge_url or a.judge_answers}
    result = run(questions, scorer, ask, meta, judge)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{run_id}.json").write_text(json.dumps(result, indent=1, ensure_ascii=False) + "\n")
    (out / f"{run_id}.md").write_text(markdown(result))
    t = result["totals"]
    print(f"{run_id}: accuracy {_pct(t['accuracy'])} (with partial {_pct(t['accuracy_with_partial'])}), harmful {t['harmful']}, "
          f"refusal accuracy {_pct(t['refusal_accuracy'])}, grounding {_pct(t['grounding'])}, errors {t['errors']}")
    print(f"wrote {out / (run_id + '.json')} and {out / (run_id + '.md')}")
    return 0


def narrow(questions: list[Question], a) -> list[Question]:
    if a.ids:
        wanted = set(a.ids.split(","))
        questions = [q for q in questions if q.id in wanted]
    if a.section:
        questions = [q for q in questions if q.section == a.section]
    if a.limit:
        questions = questions[: a.limit]
    return questions


def cmd_export(a) -> int:
    _, questions, _ = load(Path(a.questions))
    questions = narrow(questions, a)
    Path(a.out).write_text(json.dumps([{"id": q.id, "question": q.question} for q in questions], indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {len(questions)} questions to {a.out}")
    return 0


def cmd_report(a) -> int:
    results = [json.loads(Path(p).read_text()) for p in a.results]
    text = comparison(results, Path(a.intro).read_text() if a.intro else "", json.loads(Path(a.triage).read_text()) if a.triage else None)
    if a.out:
        Path(a.out).write_text(text)
        print(f"wrote {a.out}")
    else:
        print(text, end="")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate")
    v.add_argument("--questions", default=str(QUESTIONS))
    v.set_defaults(fn=cmd_validate)
    r = sub.add_parser("run")
    r.add_argument("--questions", default=str(QUESTIONS))
    r.add_argument("--provider", choices=("stub", "http", "file"), required=True)
    r.add_argument("--answers", help="stub: JSON object of canned answers keyed by question id; file: the app's JSON array")
    r.add_argument("--url", help="http: endpoint that answers {id, question}")
    r.add_argument("--models", help="metadata only: model name(s) behind the endpoint")
    r.add_argument("--run-id")
    r.add_argument("--out", default=str(HERE / "results"))
    r.add_argument("--ids")
    r.add_argument("--section")
    r.add_argument("--limit", type=int)
    r.add_argument("--timeout", type=float, default=600.0)
    r.add_argument("--judge-url")
    r.add_argument("--judge-answers")
    r.set_defaults(fn=cmd_run)
    e = sub.add_parser("export")
    e.add_argument("--questions", default=str(QUESTIONS))
    e.add_argument("--out", required=True)
    e.add_argument("--ids")
    e.add_argument("--section")
    e.add_argument("--limit", type=int)
    e.set_defaults(fn=cmd_export)
    c = sub.add_parser("report")
    c.add_argument("results", nargs="+")
    c.add_argument("--out")
    c.add_argument("--intro", help="Markdown file placed before the table (what library and settings the runs used)")
    c.add_argument("--triage", help="JSON {run_id: {question_id: {outcome, reason}}} of reviewer calls, shown as a second table")
    c.set_defaults(fn=cmd_report)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
