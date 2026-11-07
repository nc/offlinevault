"""questions.yaml is publishable: valid against the Field Guide on disk, with the mix the compete plan asks for."""
from collections import Counter

from conftest import EVAL
import run_eval


def test_questions_file_validates():
    assert run_eval.validate(EVAL / "questions.yaml") == []


def test_validator_names_each_problem(tmp_path):
    bad = (EVAL / "questions.yaml").read_text().split("\nquestions:\n")[0] + """
questions:
  - id: dup
    section: nowhere
    question: ""
    gold: []
    sources: []
  - id: dup
    section: water
    expect: refuse
    refuse_category: astrology
    question: "x"
    gold: [{fact: a, keys: [a]}]
    sources: [{article: no-such-article}]
"""
    p = tmp_path / "q.yaml"
    p.write_text(bad)
    problems = run_eval.validate(p)
    for needle in ("duplicate id dup", "unknown section 'nowhere'", "empty question", "no gold facts", "no sources",
                   "refuse_category must be one of", "no-such-article", "needs `cites`", "needs the harmful statements"):
        assert any(needle in x for x in problems), (needle, problems)


def test_every_question_is_traceable_and_the_mix_matches_the_plan():
    _, questions, _ = run_eval.load(EVAL / "questions.yaml")
    articles = run_eval.article_ids()
    for q in questions:
        assert q.gold and q.sources, q.id
        for s in q.sources:
            assert any(k in s for k in ("article", "catalogue", "code")), (q.id, s)
            if "article" in s:
                assert s["article"] in articles, (q.id, s["article"])
    by_expect = Counter(q.expect for q in questions)
    by_coverage = Counter(q.coverage for q in questions)
    assert len(questions) == 150
    assert by_expect["refuse"] == 10
    assert by_coverage["catalogue"] >= 35
    assert {q.section for q in questions} == run_eval.section_ids()
    for q in questions:
        if q.expect == "refuse":
            assert q.harmful and q.coverage == "none", q.id
        else:
            assert any(f for f in q.gold), q.id
