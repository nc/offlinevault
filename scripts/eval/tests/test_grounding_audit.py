"""The Python port of Grounding must give the same quotes as Core/Tests/OfflineVaultCoreTests/GroundingTests.swift."""
import sys

from conftest import EVAL

sys.path.insert(0, str(EVAL))
import grounding_audit as ga  # noqa: E402

BLEACH = ("Add 8 drops of unscented household bleach per gallon of water. Stir and let it stand for 30 minutes. If the water does not "
          "smell slightly of chlorine, repeat the dose and wait another 15 minutes.\nFor cloudy water, filter it through cloth first.")
STANDING = "Let the treated water stand for 30 minutes before drinking. Store it in clean, covered containers."


def quoted(claim, passage):
    window, matched, score, _ = ga.best_quote(claim, passage)
    ok = window is not None and score >= ga.THRESHOLD and matched >= min(3, len(ga.terms(ga.LIST_MARKER.sub("", claim))))
    return window if ok else None


def test_copied_sentence_is_the_exact_substring():
    assert quoted("Add 8 drops of unscented household bleach per gallon of water.", BLEACH) == "Add 8 drops of unscented household bleach per gallon of water."


def test_paraphrase_with_the_same_numbers_spans_two_sentences():
    q = quoted("Use 8 drops of bleach for each gallon of water, then wait 30 minutes.", BLEACH)
    assert q and q.startswith("Add 8 drops") and q.endswith("30 minutes.")


def test_number_absent_from_the_passage_is_not_quoted():
    assert quoted("Add 16 drops of unscented household bleach per gallon of water.", BLEACH) is None
    assert ga.classify("Add 16 drops of unscented household bleach per gallon of water.", BLEACH)[0] == "number-missing"


def test_two_passages_each_give_their_own_sentence():
    assert quoted("Let the water stand for 30 minutes.", BLEACH) == "Stir and let it stand for 30 minutes."
    assert quoted("Let the water stand for 30 minutes.", STANDING) == "Let the treated water stand for 30 minutes before drinking."


def test_decimals_do_not_split_a_sentence():
    assert quoted("Use 0.5 ml of the concentrate per litre.", "Use 0.5 ml of the concentrate per litre. Shake well.") == "Use 0.5 ml of the concentrate per litre."


def test_soft_wrapped_line_stays_one_sentence():
    p = ("Hypothermia\nTreatment: move the person out of wind and wet, remove wet clothing, and insulate from the\nground with anything dry. "
         "Handle severely hypothermic people gently.")
    assert quoted("Move the person out of wind and wet, remove wet clothing, and insulate from the ground.", p) == \
        "Treatment: move the person out of wind and wet, remove wet clothing, and insulate from the\nground with anything dry."


def test_short_wrapped_line_after_a_sentence_break_joins_the_next_line():
    p = ("Chemical treatment: use unscented household bleach (5–6% sodium hypochlorite). Add 2 drops\nper litre of clear water, or 4 drops per "
         "litre of cloudy water, stir and wait 30 minutes. A faint\nchlorine smell is expected; if there is none, repeat the dose and wait another 15 minutes.")
    q = quoted("For clear water, add 2 drops of bleach per litre and wait 30 minutes.", p)
    assert q and q.startswith("Add 2 drops\nper litre of clear water")


def test_two_topic_words_do_not_verify_a_claim():
    p = ("The first aid measures for a casualty with severe hypothermia are based upon the following principles: attempt to avoid further heat "
         "loss, handle the casualty gently, and transport the casualty as soon as possible.")
    assert quoted("Rub the severely hypothermic limbs.", p) is None


def test_claims_of_splits_cited_units_and_skips_unverified():
    answer = ("Treat the water first.\n1. Add 8 drops of unscented household bleach per gallon of water [1].\n2. Let the water stand for 30 minutes [1][2].\n"
              "3. Add 16 more drops if it smells of nothing [1].\nUnverified: iodine works too.\nThen drink.")
    claims = ga.claims_of(answer)
    assert [c[1] for c in claims] == [[1], [1, 2], [1]]
    assert claims[0][0] == "Add 8 drops of unscented household bleach per gallon of water."  # the list marker is prose, as in Swift
