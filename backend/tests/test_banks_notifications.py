"""The bank notification rules: the data file, every rule on its own samples, the engine."""

import copy
import re
from typing import Any

import pytest

from tasker.banks import notifications as notif
from tasker.banks import reference as ref
from tasker.datafiles import load_json
from tasker.finance.presets import PRESET_KEYS

DOC = notif.load_rules()
RULES = [(bank["id"], bank["packages"][0], rule) for bank in DOC["banks"] for rule in bank["rules"]]
SAMPLES = [
    pytest.param(package, rule, sample, id=f"{rule['id']}#{n}")
    for _bank, package, rule in RULES
    for n, sample in enumerate(rule["samples"], start=1)
]


def test_the_file_is_marked_synthetic_and_valid() -> None:
    assert DOC["synthetic"] is True
    assert notif.rules_problems(DOC) == []
    banks = {bank["id"] for bank in DOC["banks"]}
    assert {"tbank", "vtb"} <= banks


def test_every_rule_kind_is_covered_by_the_starter_set() -> None:
    kinds = {rule["kind"] for _b, _p, rule in RULES}
    assert kinds == {"expense", "income", "ignore"}
    assert any(rule.get("refund") for _b, _p, rule in RULES)
    assert any("time" in rule.get("groups", {}) for _b, _p, rule in RULES)
    assert any("balance" in rule.get("groups", {}) for _b, _p, rule in RULES)


@pytest.mark.parametrize(("package", "rule", "sample"), SAMPLES)
def test_every_sample_of_every_rule(
    package: str, rule: dict[str, Any], sample: dict[str, Any]
) -> None:
    result = notif.parse_notification(package, sample["title"], sample["text"])
    assert result["rule_id"] == rule["id"]
    for key, value in sample["expected"].items():
        assert result[key] == value, (key, result)


def test_every_rule_has_samples() -> None:
    assert all(len(rule["samples"]) >= 1 for _b, _p, rule in RULES)
    assert sum(len(rule["samples"]) for _b, _p, rule in RULES) >= 25


def test_parsed_results_have_the_documented_shape() -> None:
    result = notif.parse_notification(
        "com.idamob.tinkoff.android",
        "Покупка",
        "Покупка на 1 234,56 ₽, Пятёрочка. Карта *1234. Доступно 10 000,50 ₽",
    )
    assert set(result) == {
        "status",
        "bank",
        "rule_id",
        "kind",
        "refund",
        "amount",
        "currency",
        "card_last4",
        "merchant",
        "balance",
        "time",
        "needs_review",
        "review_reason",
    }
    assert isinstance(result["amount"], int)


def test_unknown_package_and_unrecognised_text() -> None:
    other = notif.parse_notification("com.example.app", "x", "y")
    assert (other["status"], other["reason"], other["bank"]) == ("ignored", "unknown_package", None)
    lost = notif.parse_notification("com.idamob.tinkoff.android", "Покупка", "странный текст")
    assert (lost["status"], lost["bank"], lost["reason"]) == ("unrecognized", "tbank", "no_rule")


def test_the_title_must_match_a_rule_that_names_titles() -> None:
    text = "Покупка на 500 ₽, Магнит. Карта *1234"
    assert (
        notif.parse_notification("com.idamob.tinkoff.android", "Покупка", text)["status"]
        == "parsed"
    )
    assert (
        notif.parse_notification("com.idamob.tinkoff.android", "Реклама", text)["status"]
        == "unrecognized"
    )


def test_text_is_cleaned_before_matching() -> None:
    assert notif.normalize_text(" a b c\td\r\ne f  g ") == "a b c d e f g"
    assert notif.normalize_text("") == ""
    assert notif.normalize_text("\n\n") == ""
    assert notif.normalize_text("a\x0bb") == "a b"


@pytest.mark.parametrize(
    "bad",
    [
        r"\d+",
        r"\w",
        r"\s",
        r"\b",
        r"(?=x)",
        r"(?<n>x)",
        r"(?P<n>x)",
        r"(?i)x",
        "x" + chr(92),
        # possessive quantifiers (Python 3.11+ only)
        "a*+",
        "a++",
        "a?+",
        "a{1,2}+",
        "(?:ab)*+c",
        "[0-9]++",
        # a quantifier after a quantifier, a lazy one after a lazy one
        "a+*",
        "a*??",
        "a{2}{3}",
        "a+{2}",
        # braces that Dart reads as text
        "a{,3}",
        "a{x}",
        "a{",
        "a{1,2",
        # nested, empty and unclosed classes
        "[[a]",
        "[a[b]]",
        "[]a]",
        "[^]a]",
        "[abc",
    ],
)
def test_the_pattern_subset_rejects_runtime_dependent_constructs(bad: str) -> None:
    assert notif.pattern_problem(bad) is not None


@pytest.mark.parametrize(
    "good",
    [
        r"^Оплата ([0-9]+) ₽\.$",
        r"(?:a|b)+?c{1,2}",
        r"\*\(\)\[\]\{\}\|\^\$\.\\",
        r"[0-9 ]*",
        r"a??b*?c+?d{2}e{2,}f{1,3}?",
        r"[+*?{}(]+",  # specials are plain inside a class
        r"[^\]\[]x\{,3\}",
        r"a+(?:b?)*",  # a quantifier after a closing parenthesis is a new quantifier
    ],
)
def test_the_pattern_subset_accepts_the_portable_forms(good: str) -> None:
    assert notif.pattern_problem(good) is None


def test_every_pattern_of_the_data_file_is_portable() -> None:
    for _b, _p, rule in RULES:
        assert notif.pattern_problem(rule["pattern"]) is None, rule["id"]
        # no digit classes beyond [0-9], no \d: the rule engine of Dart agrees with Python
        assert "\\d" not in rule["pattern"]


def _doc_with(rule: dict[str, Any]) -> dict[str, Any]:
    doc = copy.deepcopy(DOC)
    doc["banks"][0]["rules"].append(rule)
    return doc


def _rule(**over: Any) -> dict[str, Any]:
    rule: dict[str, Any] = {
        "id": "t.x",
        "kind": "expense",
        "title": None,
        "pattern": "^Pay ([0-9]+) (₽|USD|XXX)$",
        "groups": {"amount": 1, "currency": 2},
        "samples": [{"title": "t", "text": "Pay 5 ₽", "expected": {}}],
    }
    rule.update(over)
    return rule


def test_the_validator_reports_what_is_wrong_with_a_rule() -> None:
    def problems(**over: Any) -> list[str]:
        return notif.rules_problems(_doc_with(_rule(**over)))

    assert problems() == []
    assert any("duplicate id" in p for p in problems(id="tbank.purchase"))
    assert any("unknown kind" in p for p in problems(kind="refund"))
    assert any("not allowed" in p for p in problems(pattern=r"^\d+ ([0-9]+) (₽)$"))
    assert any("does not compile" in p for p in problems(pattern="(["))
    assert any("unknown group name" in p for p in problems(groups={"amount": 1, "city": 2}))
    assert any("points to 9" in p for p in problems(groups={"amount": 9}))
    assert any("needs an amount" in p for p in problems(groups={"currency": 2}))
    assert any("exclusive" in p for p in problems(currency_fixed="RUB"))
    assert any("at least one sample" in p for p in problems(samples=[]))
    assert any(
        "not matched by its own rule" in p
        for p in problems(samples=[{"title": "t", "text": "nothing", "expected": {}}])
    )


def test_the_validator_notices_a_package_listed_twice() -> None:
    doc = copy.deepcopy(DOC)
    doc["banks"][1]["packages"].append(doc["banks"][0]["packages"][0])
    assert any("listed twice" in p for p in notif.rules_problems(doc))


def test_the_engine_on_synthetic_rules() -> None:
    def run(rule: dict[str, Any], text: str, title: str = "t") -> dict[str, Any]:
        doc = {"currencies": {"₽": "RUB", "USD": "USD"}, "banks": []}
        return notif.parse_with(doc, None, title, text, rule)

    # an unknown currency symbol, a fixed currency, ignore_case, a bad amount, a bad time
    assert run(_rule(), "Pay 5 XXX")["reason"] == "unknown_currency"
    fixed = _rule(
        pattern="^pay ([0-9]+)$", groups={"amount": 1}, currency_fixed="USD", ignore_case=True
    )
    got = run(fixed, "PAY 7")
    assert (got["currency"], got["needs_review"], got["review_reason"]) == (
        "USD",
        True,
        "foreign_currency",
    )
    assert run(_rule(), "PAY 5 ₽")["status"] == "unrecognized"  # case-sensitive by default
    bad_amount = _rule(pattern="^Pay (x?[0-9]*)$", groups={"amount": 1})
    assert run(bad_amount, "Pay x")["reason"] == "bad_amount"
    late = _rule(pattern="^([0-9]+) at ([0-9]{2}:[0-9]{2})$", groups={"amount": 1, "time": 2})
    assert run(late, "5 at 25:61")["time"] is None
    assert run(late, "5 at 23:59")["time"] == "23:59"
    no_card = _rule(pattern="^([0-9]+) \\*([0-9]{4})?$", groups={"amount": 1, "card_last4": 2})
    assert run(no_card, "5 *")["card_last4"] is None
    assert run(_rule(kind="ignore", pattern="^spam"), "spam!")["status"] == "ignored"


def test_group_that_did_not_participate_is_none() -> None:
    rule = _rule(pattern="^([0-9]+)(?: from (.+))?$", groups={"amount": 1, "merchant": 2})
    doc: dict[str, Any] = {"currencies": {}, "banks": []}
    assert notif.parse_with(doc, None, "t", "5", rule)["merchant"] is None
    assert notif.parse_with(doc, None, "t", "5 from Bob", rule)["merchant"] == "Bob"


def test_merchant_and_card_come_out_clean() -> None:
    result = notif.parse_notification(
        "ru.vtb24.mobilebanking.android",
        "ВТБ",
        "Оплата 1 500 RUB. Карта *5678. PYATEROCHKA 1234 MOSKVA. Баланс 20 000,10 RUB",
    )
    assert result["card_last4"] == "5678"
    assert ref.normalize_merchant(result["merchant"]) == "pyaterochka"


def test_unknown_group_of_regex_special_chars_in_rules_file_are_escaped() -> None:
    for _b, _p, rule in RULES:
        re.compile(rule["pattern"])


# ------------------------------------------------------------------ the other data files


def test_category_dictionary_uses_preset_keys_and_normalized_words() -> None:
    data = load_json(ref.DICTIONARY_FILE)
    for entry in data["keywords"]:
        assert entry["key"] in PRESET_KEYS, entry["key"]
        for word in entry["words"]:
            assert " ".join(ref.fold_words(word)) == word, word
    for mcc, key in data["mcc"].items():
        assert re.fullmatch(r"[0-9]{4}", mcc)
        assert key in PRESET_KEYS, key


def test_normalization_data_is_already_normalized() -> None:
    data = load_json(ref.NORMALIZATION_FILE)
    for word in [*data["legal_forms"], *data["country_codes"]]:
        assert ref.fold_words(word) == [word]
    for city in data["cities"]:
        assert ref.fold_words(" ".join(city)) == city


def test_every_starter_keyword_is_found_by_the_suggester() -> None:
    data = load_json(ref.DICTIONARY_FILE)
    for entry in data["keywords"]:
        kind = entry["key"].split(".", 1)[0]
        for word in entry["words"]:
            found = ref.suggest_category(word, None, kind)
            # an earlier entry may own the word (file order is the priority)
            assert found["source"] == "keyword", word
