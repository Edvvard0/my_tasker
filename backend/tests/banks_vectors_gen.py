"""Builds ``shared-test-vectors/banks/*.json``: inputs are written here, expected values come from
the reference implementation (``tasker.banks``) and must be reviewed by eye.

Rebuild: ``cd backend && uv run python -m tests.banks_vectors_gen``. A test checks that the files
on disk are exactly this output.
"""

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

from tasker.banks import notifications as notif
from tasker.banks import reference as ref

OUT = Path(__file__).resolve().parents[2] / "shared-test-vectors" / "banks"
Case = tuple[str, dict[str, Any]]  # (name, input)

ACC = "00000000-0000-7000-8000-0000000000a1"
OTHER = "00000000-0000-7000-8000-0000000000a2"
T0 = "2026-10-03T11:30:00Z"


# ------------------------------------------------------------------ merchant normalization

MERCHANTS: list[Case] = [
    (name, {"text": text})
    for name, text in [
        ("plain_lowercase", "Пятёрочка"),
        ("capitals_and_yo", "ПЯТЁРОЧКА"),
        ("ascii_capitals", "PYATEROCHKA"),
        ("guillemets_quotes", "Кофейня «Бодрый день»"),
        ("ascii_quotes", 'Кафе "Берёзка"'),
        ("typographic_quotes", "Пекарня “Хлебница”"),
        ("legal_form_ooo_prefix", "ООО Ромашка"),
        ("legal_form_ooo_with_quotes", 'ООО "Ромашка"'),
        ("legal_form_ip", "ИП Петров"),
        ("legal_form_llc_latin", "Rose LLC"),
        ("legal_form_ooo_latin_lookalike", "OOO Rose"),
        ("terminal_number_trailing", "Пятёрочка 1234"),
        ("terminal_number_with_sign", "Магнит №5678"),
        ("terminal_number_hash", "Лента #17"),
        ("city_trailing", "Пятёрочка Москва"),
        ("city_trailing_latin", "PYATEROCHKA MOSKVA"),
        ("city_two_words", "Вкусвилл Санкт-Петербург"),
        ("city_three_words", "Магнит Ростов-на-Дону"),
        ("number_then_city", "PYATEROCHKA 1234 MOSKVA"),
        ("city_then_number", "Магнит Москва 99"),
        ("city_then_country", "Лента Москва RUS"),
        ("country_only_trailing", "Ozon RU"),
        ("number_in_the_middle_kept", "Магнит 5 Косметик"),
        ("leading_number_kept", "7 Эльдорадо"),
        ("star_separators", "YANDEX*5411*TAXI"),
        ("apostrophe", "McDonald's"),
        ("dots_and_commas", "Ип. Сидоров, г. Тула"),
        ("multiple_spaces_and_tabs", "  Кофе\tДом   "),
        ("nbsp", "Кофе Дом"),
        ("only_legal_form_kept", "ООО"),
        ("only_number_kept", "12345"),
        ("only_city_kept", "Москва"),
        ("empty", ""),
        ("only_punctuation", "«»—"),
        ("cjk_is_a_separator", "Sushi 寿司 Bar"),
        ("already_normal", "пятерочка"),
        ("idempotent_input", "yandex 5411 taxi"),
    ]
]


def run_merchant(given: dict[str, Any]) -> Any:
    return ref.normalize_merchant(given["text"])


# ------------------------------------------------------------------ similarity

SIMILARITY: list[Case] = [
    (name, {"a": a, "b": b})
    for name, a, b in [
        ("equal", "пятерочка", "пятерочка"),
        ("empty_left", "", "пятерочка"),
        ("empty_right", "пятерочка", ""),
        ("both_empty", "", ""),
        ("leading_words_are_prefix", "магнит", "магнит косметик"),
        ("prefix_symmetric", "магнит косметик", "магнит"),
        ("prefix_of_three_words", "кофейня бодрый", "кофейня бодрый день"),
        ("not_a_word_prefix", "маг", "магнит"),
        ("one_letter_apart", "пятерочка", "пятерочка1"),
        ("typo", "перекресток", "перекрестог"),
        ("different_scripts", "pyaterochka", "пятерочка"),
        ("unrelated", "магнит", "лукойл"),
        ("shared_word_in_the_middle", "кафе бодрый день", "бодрый день кафе"),
        ("single_letters_differ", "а", "б"),
        ("space_insensitive_core", "кофе дом", "кофедом"),
    ]
]


def run_similarity(given: dict[str, Any]) -> Any:
    return ref.similarity(given["a"], given["b"])


# ------------------------------------------------------------------ dedup hash

HASHES: list[Case] = [
    (
        name,
        {
            "account_id": ACC,
            "kind": kind,
            "amount": amount,
            "occurred_at": at,
            "merchant": merchant,
            "ordinal": ordinal,
        },
    )
    for name, kind, amount, at, merchant, ordinal in [
        ("expense_plain", "expense", 123_456, "2026-10-03T11:30:00Z", "Пятёрочка", 0),
        ("seconds_are_dropped", "expense", 123_456, "2026-10-03T11:30:59Z", "Пятёрочка", 0),
        ("next_minute_differs", "expense", 123_456, "2026-10-03T11:31:00Z", "Пятёрочка", 0),
        (
            "merchant_variants_collapse",
            "expense",
            123_456,
            "2026-10-03T11:30:00Z",
            "ПЯТЁРОЧКА 1234 Москва",
            0,
        ),
        ("income_kind_differs", "income", 123_456, "2026-10-03T11:30:00Z", "Пятёрочка", 0),
        ("amount_differs", "expense", 123_457, "2026-10-03T11:30:00Z", "Пятёрочка", 0),
        ("second_identical_one", "expense", 123_456, "2026-10-03T11:30:00Z", "Пятёрочка", 1),
        ("third_identical_one", "expense", 123_456, "2026-10-03T11:30:00Z", "Пятёрочка", 2),
        ("no_merchant", "income", 5_000_000, "2026-10-01T09:00:00Z", None, 0),
        ("date_only_noon_moscow", "expense", 49_900, "2026-10-02T09:00:00Z", "Кофе Дом", 0),
        ("fractions_of_second_dropped", "expense", 100, "2026-10-02T09:00:00.987Z", "Кофе", 0),
    ]
]


def run_hash(given: dict[str, Any]) -> Any:
    tail = ref.dedup_tail(
        given["kind"], given["amount"], given["occurred_at"], given["merchant"], given["ordinal"]
    )
    return {
        "tail": tail,
        "hash": ref.hash_of(given["account_id"], tail),
    }


# ------------------------------------------------------------------ matching


def cand(
    kind: str, amount: int, at: str, merchant: str | None = None, **over: Any
) -> dict[str, Any]:
    return {
        "kind": kind,
        "amount": amount,
        "currency": "RUB",
        "occurred_at": at,
        "date_only": False,
        "merchant": merchant,
        "external_id": None,
        **over,
    }


def day(
    kind: str, amount: int, date: str, merchant: str | None = None, **over: Any
) -> dict[str, Any]:
    """A statement line with only a date."""
    return cand(kind, amount, ref.date_only_instant(date), merchant, date_only=True, **over)


def ex(
    eid: str, kind: str, amount: int, at: str, merchant: str | None = None, **over: Any
) -> dict[str, Any]:
    return {
        "id": eid,
        "account_id": ACC,
        "kind": kind,
        "amount": amount,
        "occurred_at": at,
        "merchant": merchant,
        "source": "notification",
        "status": "draft",
        "external_id": None,
        "dedup_hash": None,
        **over,
    }


def hashed(candidate: dict[str, Any], ordinal: int = 0, account: str = ACC) -> str:
    return ref.dedup_hash(
        account,
        candidate["kind"],
        candidate["amount"],
        candidate["occurred_at"],
        candidate["merchant"],
        ordinal,
    )


def scene(candidates: list[dict[str, Any]], existing: list[dict[str, Any]]) -> dict[str, Any]:
    return {"account_id": ACC, "candidates": candidates, "existing": existing}


_BUY = cand("expense", 123_456, T0, "Пятёрочка 1234")
_BUY_DAY = day("expense", 123_456, "2026-10-03", "ПЯТЁРОЧКА")

MATCHING: list[Case] = [
    ("no_candidates", scene([], [ex("e1", "expense", 100, T0)])),
    ("nothing_existing_is_new", scene([_BUY], [])),
    (
        "notification_draft_refined_by_a_dated_statement_line",
        scene([_BUY_DAY], [ex("e1", "expense", 123_456, T0, "Пятёрочка 1234")]),
    ),
    (
        "statement_line_with_a_time_refines_the_moment",
        scene(
            [cand("expense", 123_456, "2026-10-03T11:33:10Z", "Пятёрочка")],
            [ex("e1", "expense", 123_456, T0, "Пятёрочка")],
        ),
    ),
    (
        "same_hash_is_a_duplicate",
        scene(
            [_BUY], [ex("e1", "expense", 123_456, T0, "Пятёрочка 1234", dedup_hash=hashed(_BUY))]
        ),
    ),
    (
        "same_external_id_is_a_duplicate_even_if_everything_else_differs",
        scene(
            [cand("expense", 100, T0, "A", external_id="OP-1")],
            [ex("e1", "expense", 999, "2026-09-01T00:00:00Z", "B", external_id="OP-1")],
        ),
    ),
    (
        "different_external_ids_are_two_operations",
        scene(
            [cand("expense", 100, T0, "Кофе", external_id="OP-2")],
            [ex("e1", "expense", 100, T0, "Кофе", external_id="OP-1", source="statement")],
        ),
    ),
    (
        "candidate_with_id_matches_a_draft_without_one",
        scene(
            [cand("expense", 100, T0, "Кофе", external_id="OP-2")],
            [ex("e1", "expense", 100, T0, "Кофе")],
        ),
    ),
    (
        "near_amount_is_not_a_match",
        scene(
            [cand("expense", 123_450, T0, "Пятёрочка")],
            [ex("e1", "expense", 123_456, T0, "Пятёрочка")],
        ),
    ),
    (
        "one_kopeck_apart_is_not_a_match",
        scene([cand("expense", 100_001, T0, "Кофе")], [ex("e1", "expense", 100_000, T0, "Кофе")]),
    ),
    (
        "two_equal_purchases_one_existing_draft",
        scene(
            [
                day("expense", 50_000, "2026-10-03", "Кофе Дом"),
                day("expense", 50_000, "2026-10-03", "Кофе Дом"),
            ],
            [ex("e1", "expense", 50_000, "2026-10-03T07:00:00Z", "Кофе Дом")],
        ),
    ),
    (
        "two_equal_purchases_two_existing_drafts",
        scene(
            [
                day("expense", 50_000, "2026-10-03", "Кофе Дом"),
                day("expense", 50_000, "2026-10-03", "Кофе Дом"),
            ],
            [
                ex("e1", "expense", 50_000, "2026-10-03T07:00:00Z", "Кофе Дом"),
                ex("e2", "expense", 50_000, "2026-10-03T15:00:00Z", "Кофе Дом"),
            ],
        ),
    ),
    (
        "two_equal_purchases_nothing_existing_get_different_hashes",
        scene(
            [
                day("expense", 50_000, "2026-10-03", "Кофе Дом"),
                day("expense", 50_000, "2026-10-03", "Кофе Дом"),
            ],
            [],
        ),
    ),
    (
        "reimport_of_two_equal_purchases_is_all_duplicates",
        scene(
            [
                day("expense", 50_000, "2026-10-03", "Кофе Дом"),
                day("expense", 50_000, "2026-10-03", "Кофе Дом"),
            ],
            [
                ex(
                    "e1",
                    "expense",
                    50_000,
                    "2026-10-03T09:00:00Z",
                    "Кофе Дом",
                    source="statement",
                    status="confirmed",
                    dedup_hash=hashed(day("expense", 50_000, "2026-10-03", "Кофе Дом")),
                ),
                ex(
                    "e2",
                    "expense",
                    50_000,
                    "2026-10-03T09:00:00Z",
                    "Кофе Дом",
                    source="statement",
                    status="confirmed",
                    dedup_hash=hashed(day("expense", 50_000, "2026-10-03", "Кофе Дом"), 1),
                ),
            ],
        ),
    ),
    (
        "refund_is_not_the_purchase",
        scene(
            [cand("income", 30_000, T0, "Магнит")],
            [ex("e1", "expense", 30_000, "2026-10-03T09:00:00Z", "Магнит")],
        ),
    ),
    (
        "refund_matches_the_refund_notification",
        scene(
            [day("income", 30_000, "2026-10-04", "Магнит")],
            [ex("e1", "income", 30_000, "2026-10-04T08:15:00Z", "Магнит")],
        ),
    ),
    (
        "window_edge_exactly_48_hours_matches",
        scene(
            [cand("expense", 100, "2026-10-05T11:30:00Z", "Кофе")],
            [ex("e1", "expense", 100, "2026-10-03T11:30:00Z", "Кофе")],
        ),
    ),
    (
        "window_edge_one_second_more_is_new",
        scene(
            [cand("expense", 100, "2026-10-05T11:30:01Z", "Кофе")],
            [ex("e1", "expense", 100, "2026-10-03T11:30:00Z", "Кофе")],
        ),
    ),
    (
        "foreign_currency_is_needs_review_and_never_fuzzy_matched",
        scene(
            [cand("expense", 100_000, T0, "AMAZON", currency="USD")],
            [ex("e1", "expense", 100_000, T0, "AMAZON")],
        ),
    ),
    (
        "foreign_currency_with_the_same_hash_is_still_a_duplicate",
        scene(
            [cand("expense", 100_000, T0, "AMAZON", currency="USD")],
            [
                ex(
                    "e1",
                    "expense",
                    100_000,
                    T0,
                    "AMAZON",
                    dedup_hash=hashed(cand("expense", 100_000, T0, "AMAZON")),
                )
            ],
        ),
    ),
    (
        "unknown_merchant_on_the_draft_matches",
        scene([day("expense", 7_000, "2026-10-03", "Кофе Дом")], [ex("e1", "expense", 7_000, T0)]),
    ),
    (
        "unknown_merchant_on_the_line_matches",
        scene([day("expense", 7_000, "2026-10-03")], [ex("e1", "expense", 7_000, T0, "Кофе Дом")]),
    ),
    (
        "different_names_do_not_match",
        scene(
            [day("expense", 7_000, "2026-10-03", "Лукойл")],
            [ex("e1", "expense", 7_000, T0, "Кофе Дом")],
        ),
    ),
    (
        "latin_vs_cyrillic_names_do_not_match",
        scene(
            [day("expense", 123_456, "2026-10-03", "Пятёрочка")],
            [ex("e1", "expense", 123_456, T0, "PYATEROCHKA 1234 MOSKVA")],
        ),
    ),
    (
        "manual_confirmed_row_is_merged_not_duplicated",
        scene(
            [day("expense", 7_000, "2026-10-03", "Кофе Дом")],
            [ex("e1", "expense", 7_000, T0, "кофе дом", source="manual", status="confirmed")],
        ),
    ),
    (
        "an_existing_statement_row_makes_a_fuzzy_match_a_duplicate",
        scene(
            [day("expense", 7_000, "2026-10-03", "Кофе Дом")],
            [ex("e1", "expense", 7_000, T0, "Кофе Дом", source="statement", status="confirmed")],
        ),
    ),
    (
        "another_account_is_ignored",
        scene(
            [day("expense", 7_000, "2026-10-03", "Кофе Дом")],
            [ex("e1", "expense", 7_000, T0, "Кофе Дом", account_id=OTHER)],
        ),
    ),
    (
        "better_name_wins",
        scene(
            [day("expense", 7_000, "2026-10-03", "Кофейня Бодрый день")],
            [
                ex("e1", "expense", 7_000, "2026-10-03T09:00:00Z", "Кофейня Бодрый"),
                ex("e2", "expense", 7_000, "2026-10-03T09:00:00Z", "Кофейня Бодрый день"),
            ],
        ),
    ),
    (
        "equal_names_the_closer_time_wins",
        scene(
            [cand("expense", 7_000, "2026-10-03T12:00:00Z", "Кофе Дом")],
            [
                ex("e1", "expense", 7_000, "2026-10-03T08:00:00Z", "Кофе Дом"),
                ex("e2", "expense", 7_000, "2026-10-03T11:00:00Z", "Кофе Дом"),
            ],
        ),
    ),
    (
        "a_row_taken_by_hash_is_not_reused_by_a_fuzzy_match",
        scene(
            [cand("expense", 100, T0, "Кофе"), day("expense", 100, "2026-10-03", "Кофе")],
            [
                ex(
                    "e1",
                    "expense",
                    100,
                    T0,
                    "Кофе",
                    dedup_hash=hashed(cand("expense", 100, T0, "Кофе")),
                )
            ],
        ),
    ),
    (
        "income_transfer_between_own_banks_is_just_an_income_here",
        scene(
            [day("income", 1_000_000, "2026-10-03", "Перевод с карты Т-Банк")],
            [ex("e1", "income", 1_000_000, T0, "Перевод с карты Т-Банк")],
        ),
    ),
]


def run_matching(given: dict[str, Any]) -> Any:
    return ref.classify_candidates(given["account_id"], given["candidates"], given["existing"])


# ------------------------------------------------------------------ own-account transfers


def row(rid: str, kind: str, account: str, amount: int, at: str, **over: Any) -> dict[str, Any]:
    return {
        "id": rid,
        "kind": kind,
        "account_id": account,
        "amount": amount,
        "occurred_at": at,
        "currency": "RUB",
        "date_only": False,
        "debt_id": None,
        **over,
    }


TRANSFERS: list[Case] = [
    ("empty", {"transactions": [], "window_seconds": 600}),
    (
        "basic_pair",
        {
            "transactions": [
                row("o", "expense", "a1", 500_000, "2026-10-03T11:30:00Z"),
                row("i", "income", "a2", 500_000, "2026-10-03T11:30:40Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "order_of_input_does_not_matter",
        {
            "transactions": [
                row("i", "income", "a2", 500_000, "2026-10-03T11:30:40Z"),
                row("o", "expense", "a1", 500_000, "2026-10-03T11:30:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "income_first_in_time_still_pairs",
        {
            "transactions": [
                row("o", "expense", "a1", 500_000, "2026-10-03T11:35:00Z"),
                row("i", "income", "a2", 500_000, "2026-10-03T11:30:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "window_edge_exactly_ten_minutes",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T11:30:00Z"),
                row("i", "income", "a2", 100, "2026-10-03T11:40:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "one_second_past_the_window",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T11:30:00Z"),
                row("i", "income", "a2", 100, "2026-10-03T11:40:01Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "same_account_is_a_refund_not_a_transfer",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T11:30:00Z"),
                row("i", "income", "a1", 100, "2026-10-03T11:31:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "different_amounts",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T11:30:00Z"),
                row("i", "income", "a2", 101, "2026-10-03T11:30:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "two_incomes_the_closer_one_pairs",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T11:30:00Z"),
                row("i1", "income", "a2", 100, "2026-10-03T11:36:00Z"),
                row("i2", "income", "a3", 100, "2026-10-03T11:32:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "two_separate_pairs",
        {
            "transactions": [
                row("o1", "expense", "a1", 100, "2026-10-03T11:30:00Z"),
                row("i1", "income", "a2", 100, "2026-10-03T11:31:00Z"),
                row("o2", "expense", "a1", 100, "2026-10-03T15:30:00Z"),
                row("i2", "income", "a2", 100, "2026-10-03T15:30:30Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "dates_only_on_the_same_day_pair",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T09:00:00Z", date_only=True),
                row("i", "income", "a2", 100, "2026-10-03T14:20:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "date_only_on_another_day_does_not_pair",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T09:00:00Z", date_only=True),
                row("i", "income", "a2", 100, "2026-10-04T09:00:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "date_only_uses_the_moscow_day",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T09:00:00Z", date_only=True),
                row("i", "income", "a2", 100, "2026-10-03T21:30:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "foreign_currency_is_skipped",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T11:30:00Z", currency="USD"),
                row("i", "income", "a2", 100, "2026-10-03T11:30:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "debt_movements_are_skipped",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T11:30:00Z", debt_id="d1"),
                row("i", "income", "a2", 100, "2026-10-03T11:30:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "existing_transfers_are_not_touched",
        {
            "transactions": [
                row("t", "transfer", "a1", 100, "2026-10-03T11:30:00Z"),
                row("i", "income", "a2", 100, "2026-10-03T11:30:00Z"),
            ],
            "window_seconds": 600,
        },
    ),
    (
        "a_wider_window",
        {
            "transactions": [
                row("o", "expense", "a1", 100, "2026-10-03T11:30:00Z"),
                row("i", "income", "a2", 100, "2026-10-03T11:50:00Z"),
            ],
            "window_seconds": 3600,
        },
    ),
]


def run_transfers(given: dict[str, Any]) -> Any:
    return ref.match_transfers(given["transactions"], given["window_seconds"])


# ------------------------------------------------------------------ notification parsing


def _notification_cases() -> list[Case]:
    doc = notif.load_rules()
    cases: list[Case] = []
    for bank in doc["banks"]:
        package = bank["packages"][0]
        for rule in bank["rules"]:
            for number, sample in enumerate(rule["samples"], start=1):
                cases.append(
                    (
                        f"{rule['id']}#{number}",
                        {"package": package, "title": sample["title"], "text": sample["text"]},
                    )
                )
    first = doc["banks"][0]["packages"][0]
    second = doc["banks"][1]["packages"][0]
    cases.extend(
        [
            (
                "unknown_package",
                {
                    "package": "com.example.other",
                    "title": "Покупка",
                    "text": "Покупка на 1 ₽, X. Карта *1234",
                },
            ),
            (
                "unrecognized_text",
                {"package": first, "title": "Покупка", "text": "Что-то совсем другое"},
            ),
            (
                "title_must_match",
                {
                    "package": first,
                    "title": "Другое",
                    "text": "Покупка на 500 ₽, Магнит. Карта *1234",
                },
            ),
            (
                "whitespace_is_normalized",
                {
                    "package": first,
                    "title": " Покупка ",
                    "text": "Покупка  на\u00a01\u202f234,56 ₽,\nПятёрочка.\tКарта *1234. "
                    "Доступно 10 000,50 ₽",
                },
            ),
            (
                "amount_without_kopecks_and_spaces",
                {
                    "package": second,
                    "title": "ВТБ",
                    "text": "Оплата 1 234 567 RUB. Карта *5678. Магнит. Баланс 5 RUB",
                },
            ),
            (
                "amount_with_one_decimal_digit",
                {
                    "package": second,
                    "title": "ВТБ",
                    "text": "Оплата 10,5 RUB. Карта *5678. Магнит. Баланс 100,5 RUB",
                },
            ),
            (
                "amount_with_dot_decimal",
                {
                    "package": second,
                    "title": "VTB",
                    "text": "Karta *5678. Oplata 1000.05 RUB. SHOP. Dostupno 2000.10 RUB",
                },
            ),
            (
                "merchant_with_dots",
                {
                    "package": first,
                    "title": "Покупка",
                    "text": "Покупка на 100 ₽, ООО Ромашка. Мск. Карта *1234. Доступно 1 ₽",
                },
            ),
            (
                "a_different_banks_text_is_not_parsed",
                {
                    "package": second,
                    "title": "Покупка",
                    "text": "Покупка на 500 ₽, Магнит. Карта *1234",
                },
            ),
            ("empty_text", {"package": first, "title": "", "text": ""}),
        ]
    )
    return cases


NOTIFICATIONS: list[Case] = _notification_cases()


def run_notification(given: dict[str, Any]) -> Any:
    return notif.parse_notification(given["package"], given["title"], given["text"])


# ------------------------------------------------------------------ automatic categories

U_PYAT = "00000000-0000-7000-8000-00000000c001"
U_COFFEE = "00000000-0000-7000-8000-00000000c002"
U_LONG = "00000000-0000-7000-8000-00000000c003"


def urule(rid: str, key: str, match: str, kind: str, category: str) -> dict[str, Any]:
    return {
        "id": rid,
        "merchant_key": key,
        "match_type": match,
        "kind": kind,
        "category_id": category,
    }


CATEGORIES: list[Case] = [
    (name, {"merchant": merchant, "mcc": mcc, "kind": kind, "user_rules": rules})
    for name, merchant, mcc, kind, rules in [
        ("keyword_cyrillic", "Пятёрочка 1234 Москва", None, "expense", []),
        ("keyword_latin", "PYATEROCHKA 1234 MOSKVA", None, "expense", []),
        ("keyword_two_words", "Яндекс Такси", None, "expense", []),
        ("keyword_inside_a_longer_name", "ООО Кафе Бодрый день", None, "expense", []),
        ("keyword_apostrophe_name", "McDonald's", None, "expense", []),
        ("keyword_income_salary", "Зарплата", None, "income", []),
        ("income_keyword_not_for_expense", "Зарплата", None, "expense", []),
        ("expense_keyword_not_for_income", "Пятёрочка", None, "income", []),
        ("mcc_when_no_keyword", "ABC SHOP", "5411", "expense", []),
        ("mcc_wrong_kind", "ABC SHOP", "5411", "income", []),
        ("keyword_beats_mcc", "Лукойл", "5411", "expense", []),
        ("unknown_mcc", "ABC SHOP", "0000", "expense", []),
        ("no_merchant_no_mcc", None, None, "expense", []),
        ("word_must_be_a_whole_token", "Магнитогорск", None, "expense", []),
        (
            "user_exact_rule_beats_the_dictionary",
            "Пятёрочка Москва",
            None,
            "expense",
            [urule("r1", "пятерочка", "exact", "expense", U_PYAT)],
        ),
        (
            "user_exact_rule_needs_the_whole_name",
            "Пятёрочка Экспресс",
            "5411",
            "expense",
            [urule("r1", "пятерочка", "exact", "expense", U_PYAT)],
        ),
        (
            "user_contains_rule",
            "Кофейня Кофе Хаус",
            None,
            "expense",
            [urule("r1", "кофе хаус", "contains", "expense", U_COFFEE)],
        ),
        (
            "user_rule_of_the_other_kind_is_ignored",
            "Кофе Хаус",
            None,
            "income",
            [urule("r1", "кофе хаус", "exact", "expense", U_COFFEE)],
        ),
        (
            "user_exact_beats_contains",
            "Кофе Хаус",
            None,
            "expense",
            [
                urule("r2", "кофе", "contains", "expense", U_COFFEE),
                urule("r1", "кофе хаус", "exact", "expense", U_LONG),
            ],
        ),
        (
            "user_longer_contains_wins",
            "Кофе Хаус Центр",
            None,
            "expense",
            [
                urule("r1", "кофе", "contains", "expense", U_COFFEE),
                urule("r2", "кофе хаус", "contains", "expense", U_LONG),
            ],
        ),
    ]
]


def run_category(given: dict[str, Any]) -> Any:
    return ref.suggest_category(given["merchant"], given["mcc"], given["kind"], given["user_rules"])


FILES: dict[str, tuple[str, list[Case], Callable[[dict[str, Any]], Any]]] = {
    "merchants": (
        "normalize_merchant(text): the merchant key used by hashes, matching and rules",
        MERCHANTS,
        run_merchant,
    ),
    "similarity": (
        "similarity(a, b) of two normalized names: integer 0..100",
        SIMILARITY,
        run_similarity,
    ),
    "dedup_hash": (
        "dedup_tail(kind, amount, occurred_at, merchant, ordinal) and the hash of account_id|tail",
        HASHES,
        run_hash,
    ),
    "matching": (
        "classify_candidates(account_id, candidates, existing): new / duplicate / merge",
        MATCHING,
        run_matching,
    ),
    "transfers": (
        "match_transfers(transactions, window_seconds): own-account transfer suggestions",
        TRANSFERS,
        run_transfers,
    ),
    "notification_parse": (
        "parse_notification(package, title, text) with shared-data/banks/notification_rules.json",
        NOTIFICATIONS,
        run_notification,
    ),
    "category_suggest": (
        "suggest_category(merchant, mcc, kind, user_rules) with the starter dictionary",
        CATEGORIES,
        run_category,
    ),
}


def build() -> dict[str, str]:
    """File name -> exact text of the file."""
    files = {}
    for name, (description, cases, run) in FILES.items():
        names = [case_name for case_name, _ in cases]
        assert len(names) == len(set(names)), f"duplicate case names in {name}"
        document = {
            "description": description,
            "cases": [{"name": n, "input": given, "expected": run(given)} for n, given in cases],
        }
        files[f"{name}.json"] = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    return files


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for file_name, text in build().items():
        (OUT / file_name).write_text(text, encoding="utf-8")
    print(f"wrote {len(FILES)} files to {OUT}")  # noqa: T201


if __name__ == "__main__":
    main()
