"""Builds ``shared-test-vectors/study/*.json``: inputs are written here, expected values come from
the reference implementation (``tasker.study.reference``) and must be reviewed by eye.

Rebuild: ``cd backend && uv run python -m tests.study_vectors_gen``. A test checks that the files
on disk are exactly this output.
"""

import copy
import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

from tasker.study import reference as ref

OUT = Path(__file__).resolve().parents[2] / "shared-test-vectors" / "study"
Case = tuple[str, dict[str, Any]]  # (name, input)

SEM = "sem1"
MATH, PHYS, PROG = "math", "phys", "prog"


def sem(sid: str = SEM, **over: Any) -> dict[str, Any]:
    return {
        "id": sid,
        "start_date": "2026-09-01",
        "end_date": "2026-12-31",
        "week1_start": "2026-08-31",
        "cycle_length": 2,
        "week_shifts": None,
        "archived": False,
        **over,
    }


def subject(
    sid: str, name: str, building: str | None, room: str | None, limit: int | None = None
) -> dict[str, Any]:
    return {
        "id": sid,
        "semester_id": SEM,
        "name": name,
        "building": building,
        "room": room,
        "absence_limit": limit,
    }


def bell(
    number: int, start: str, end: str, on_date: str | None = None, semester: str = SEM
) -> dict[str, Any]:
    return {
        "semester_id": semester,
        "on_date": on_date,
        "number": number,
        "start_time": start,
        "end_time": end,
    }


def slot(
    sid: str,
    weekday: int,
    number: int | None,
    subject_id: str | None,
    kind: str = "lecture",
    **over: Any,
) -> dict[str, Any]:
    return {
        "id": sid,
        "semester_id": SEM,
        "subject_id": subject_id,
        "title": None,
        "weekday": weekday,
        "number": number,
        "start_time": None,
        "end_time": None,
        "kind": kind,
        "building": None,
        "room": None,
        "cycle_week": None,
        **over,
    }


def item(key: str, number: int | None, title: str, **over: Any) -> dict[str, Any]:
    return {
        "key": key,
        "number": number,
        "start_time": None,
        "end_time": None,
        "title": title,
        "kind": "other",
        "building": "1",
        "room": "12",
        "cycle_week": None,
        **over,
    }


def rule(
    rid: str,
    weekday: int | None = None,
    on_date: str | None = None,
    items: list[dict[str, Any]] | None = None,
    hide_regular: bool = True,
    title: str = "Подготовка к олимпиаде",
    cycle_week: int | None = None,
) -> dict[str, Any]:
    return {
        "id": rid,
        "semester_id": SEM,
        "weekday": weekday,
        "on_date": on_date,
        "cycle_week": cycle_week,
        "title": title,
        "hide_regular": hide_regular,
        "items": items if items is not None else [],
    }


def override(oid: str, slot_id: str, date: str, action: str, **over: Any) -> dict[str, Any]:
    return {
        "id": oid,
        "slot_id": slot_id,
        "date": date,
        "action": action,
        "new_date": None,
        "start_time": None,
        "end_time": None,
        "building": None,
        "room": None,
        "subject_id": None,
        "title": None,
        "lesson_kind": None,
        **over,
    }


THURSDAY_ITEMS = [
    item("o1", 1, "Подготовка к олимпиаде"),
    item("o2", 2, "Подготовка к олимпиаде"),
    item("o3", 3, "Подготовка к олимпиаде"),
]


def base() -> dict[str, Any]:
    """A semester from 2026-09-01 (Tue) with a two-week cycle (week 1 = the week of 2026-08-31)."""
    return {
        "semesters": [sem()],
        "subjects": [
            subject(MATH, "Математический анализ", "1", "28", 4),
            subject(PHYS, "Физика", "2", "101", 3),
            subject(PROG, "Программирование", None, None, None),
        ],
        "bells": [
            bell(1, "08:30", "10:00"),
            bell(2, "10:10", "11:40"),
            bell(3, "12:10", "13:40"),
            bell(4, "13:50", "15:20"),
            bell(5, "15:30", "17:00"),
        ],
        "slots": [
            slot("s-mon-1", 1, 1, MATH, "lecture"),
            slot("s-mon-2", 1, 2, PHYS, "lab", building="2", room="101", cycle_week=1),
            slot("s-tue-3", 2, 3, PROG, "practice", building="1", room="30", cycle_week=2),
            slot("s-wed-1", 3, 1, MATH, "practice"),
            slot("s-thu-1", 4, 1, MATH, "lecture"),
            slot("s-thu-2", 4, 2, PHYS, "lecture"),
            slot("s-thu-3", 4, 3, PROG, "lecture"),
            slot(
                "s-fri-x",
                5,
                None,
                None,
                "other",
                title="Кружок",
                start_time="09:00",
                end_time="10:30",
            ),
            slot("s-sat-1", 6, 1, PROG, "lecture", building="1", room="12"),
        ],
        "day_rules": [rule("r-thu", weekday=4, items=copy.deepcopy(THURSDAY_ITEMS))],
        "overrides": [],
        "holidays": {},
    }


def scene(dates: list[str], **over: Any) -> dict[str, Any]:
    data = base()
    data.update(copy.deepcopy(over))
    data["dates"] = dates
    return data


def with_slots(*extra: dict[str, Any]) -> list[dict[str, Any]]:
    return [*base()["slots"], *extra]


def without_bell(number: int) -> list[dict[str, Any]]:
    return [b for b in base()["bells"] if b["number"] != number]


WEEK = [f"2026-09-{day:02d}" for day in range(7, 14)]

EXPAND: list[Case] = [
    ("before_the_semester", scene(["2026-08-31"])),
    ("after_the_semester", scene(["2027-01-01"])),
    ("first_and_last_day", scene(["2026-09-01", "2026-12-31"])),
    ("monday_of_an_odd_week_has_the_lecture_and_the_lab", scene(["2026-09-14"])),
    ("monday_of_an_even_week_has_no_lab", scene(["2026-09-07"])),
    ("tuesday_practice_is_for_even_weeks_only", scene(["2026-09-01", "2026-09-08"])),
    ("wednesday_every_week", scene(["2026-09-02", "2026-09-09"])),
    ("thursday_is_olympiad_preparation", scene(["2026-09-03", "2026-09-10"])),
    ("friday_circle_with_its_own_time_and_no_subject", scene(["2026-09-04"])),
    ("saturday_is_a_teaching_day", scene(["2026-09-05"])),
    ("sunday_is_empty", scene(["2026-09-06"])),
    ("a_whole_even_week", scene(WEEK)),
    ("holiday_removes_the_lessons", scene(["2026-09-14"], holidays={"2026-09-14": "Праздник"})),
    (
        "holiday_beats_the_weekday_rule_of_a_thursday",
        scene(["2026-09-10"], holidays={"2026-09-10": "Праздник"}),
    ),
    (
        "a_rule_for_the_date_beats_the_holiday",
        scene(
            ["2026-09-14"],
            holidays={"2026-09-14": "Праздник"},
            day_rules=[
                rule(
                    "r-date",
                    on_date="2026-09-14",
                    items=[item("e1", 1, "Дежурство")],
                    title="Особый день",
                )
            ],
        ),
    ),
    (
        "a_rule_for_the_date_beats_the_weekday_rule",
        scene(
            ["2026-09-17", "2026-09-24"],
            day_rules=[
                rule("r-thu", weekday=4, items=copy.deepcopy(THURSDAY_ITEMS)),
                rule(
                    "r-date",
                    on_date="2026-09-17",
                    items=[item("e1", 4, "Экскурсия")],
                    title="Экскурсия",
                ),
            ],
        ),
    ),
    (
        "a_rule_that_keeps_the_regular_lessons_adds_its_own",
        scene(
            ["2026-09-16"],
            day_rules=[
                rule(
                    "r-date",
                    on_date="2026-09-16",
                    hide_regular=False,
                    items=[item("x", None, "Консультация", start_time="18:00", end_time="19:30")],
                    title="Консультация",
                )
            ],
        ),
    ),
    (
        "a_weekday_rule_for_even_weeks_only",
        scene(
            ["2026-09-03", "2026-09-10"],
            day_rules=[rule("r-thu", weekday=4, cycle_week=2, items=copy.deepcopy(THURSDAY_ITEMS))],
        ),
    ),
    (
        "a_rule_item_for_odd_weeks_only",
        scene(
            ["2026-09-03", "2026-09-10"],
            day_rules=[
                rule(
                    "r-thu",
                    weekday=4,
                    items=[item("o1", 1, "Первая", cycle_week=1), item("o2", 2, "Вторая")],
                )
            ],
        ),
    ),
    (
        "a_rule_without_items_is_a_free_day",
        scene(["2026-09-03"], day_rules=[rule("r-thu", weekday=4)]),
    ),
    (
        "a_specific_weekday_rule_beats_the_general_one",
        scene(
            ["2026-09-03", "2026-09-10"],
            day_rules=[
                rule("r-a", weekday=4, items=[item("g", 1, "Общее")], title="Общее"),
                rule(
                    "r-b", weekday=4, cycle_week=2, items=[item("s", 1, "Особое")], title="Особое"
                ),
            ],
        ),
    ),
    (
        "cancelled_lesson_stays_in_the_list_marked_cancelled",
        scene(
            ["2026-09-07", "2026-09-14"],
            overrides=[override("o-1", "s-mon-1", "2026-09-07", "cancel")],
        ),
    ),
    (
        "cancelling_a_lesson_that_does_not_occur_shows_nothing",
        scene(["2026-09-07"], overrides=[override("o-1", "s-mon-2", "2026-09-07", "cancel")]),
    ),
    (
        "cancel_ignores_the_other_fields",
        scene(
            ["2026-09-07"],
            overrides=[
                override(
                    "o-1",
                    "s-mon-1",
                    "2026-09-07",
                    "cancel",
                    room="999",
                    start_time="01:00",
                    end_time="02:00",
                )
            ],
        ),
    ),
    (
        "changed_room_replaces_the_pair",
        scene(
            ["2026-09-09"],
            overrides=[
                override("o-1", "s-wed-1", "2026-09-09", "change", building="2", room="301")
            ],
        ),
    ),
    (
        "changed_room_without_a_building_does_not_mix_with_the_old_one",
        scene(
            ["2026-09-07"],
            overrides=[override("o-1", "s-mon-1", "2026-09-07", "change", room="305")],
        ),
    ),
    (
        "changed_time_moves_the_lesson_in_the_list",
        scene(
            ["2026-09-09"],
            slots=with_slots(slot("s-wed-5", 3, 5, PROG, "lecture")),
            overrides=[
                override(
                    "o-1", "s-wed-1", "2026-09-09", "change", start_time="16:00", end_time="17:30"
                )
            ],
        ),
    ),
    (
        "changed_subject_and_kind",
        scene(
            ["2026-09-09"],
            overrides=[
                override(
                    "o-1", "s-wed-1", "2026-09-09", "change", subject_id=PHYS, lesson_kind="lab"
                )
            ],
        ),
    ),
    (
        "changed_title_replaces_the_name",
        scene(
            ["2026-09-09"],
            overrides=[
                override("o-1", "s-wed-1", "2026-09-09", "change", title="Контрольная работа")
            ],
        ),
    ),
    (
        "move_to_another_date_with_its_own_time",
        scene(
            ["2026-09-09", "2026-09-11"],
            overrides=[
                override(
                    "o-1",
                    "s-wed-1",
                    "2026-09-09",
                    "move",
                    new_date="2026-09-11",
                    start_time="14:00",
                    end_time="15:30",
                )
            ],
        ),
    ),
    (
        "move_without_a_time_uses_the_bell_of_the_new_date",
        scene(
            ["2026-09-09", "2026-09-12"],
            bells=[*base()["bells"], bell(1, "11:00", "12:30", on_date="2026-09-12")],
            overrides=[override("o-1", "s-wed-1", "2026-09-09", "move", new_date="2026-09-12")],
        ),
    ),
    (
        "a_moved_lesson_shows_on_a_holiday",
        scene(
            ["2026-09-11"],
            holidays={"2026-09-11": "Праздник"},
            overrides=[override("o-1", "s-wed-1", "2026-09-09", "move", new_date="2026-09-11")],
        ),
    ),
    (
        "a_regular_lesson_moved_away_from_an_olympiad_thursday_still_arrives",
        scene(
            ["2026-09-10", "2026-09-11"],
            overrides=[override("o-1", "s-thu-1", "2026-09-10", "move", new_date="2026-09-11")],
        ),
    ),
    (
        "bells_changed_for_all_lessons",
        scene(
            ["2026-09-14"],
            bells=[bell(1, "09:00", "10:30"), bell(2, "10:40", "12:10"), *base()["bells"][2:]],
        ),
    ),
    (
        "bells_changed_for_one_date_only",
        scene(
            ["2026-09-14", "2026-09-21"],
            bells=[*base()["bells"], bell(1, "07:50", "09:20", on_date="2026-09-14")],
        ),
    ),
    (
        "a_missing_bell_leaves_the_time_empty_and_sorts_last",
        scene(["2026-09-14"], bells=without_bell(2)),
    ),
    (
        "the_slots_own_time_beats_the_bell",
        scene(
            ["2026-09-14"],
            slots=[
                slot("s-mon-1", 1, 1, MATH, "lecture", start_time="09:15", end_time="10:45"),
                *base()["slots"][1:],
            ],
        ),
    ),
    (
        "a_slot_room_beats_the_subject_default",
        scene(
            ["2026-09-02"],
            slots=with_slots(slot("s-wed-2", 3, 2, MATH, "lecture", building="2", room="5")),
        ),
    ),
    (
        "no_alternation_when_the_cycle_is_one_week",
        scene(["2026-09-07", "2026-09-08", "2026-09-14"], semesters=[sem(cycle_length=1)]),
    ),
    (
        "a_three_week_cycle",
        scene(
            ["2026-09-01", "2026-09-08", "2026-09-15", "2026-09-22"],
            semesters=[sem(cycle_length=3)],
            slots=with_slots(slot("s-tue-w3", 2, 5, MATH, "lecture", cycle_week=3)),
        ),
    ),
    (
        "a_parity_shift_flips_the_weeks_from_its_monday",
        scene(
            ["2026-09-28", "2026-10-05", "2026-10-12"],
            semesters=[sem(week_shifts=[{"from": "2026-10-07", "weeks": 1}])],
        ),
    ),
    (
        "a_slot_of_another_semester_is_ignored",
        scene(
            ["2026-09-14"],
            semesters=[sem(), sem("sem2", start_date="2027-02-01", end_date="2027-06-30")],
            slots=[
                *base()["slots"],
                {**slot("s-other", 1, 1, None, title="Чужая"), "semester_id": "sem2"},
            ],
        ),
    ),
    (
        "the_next_semester_has_its_own_slots_and_cycle",
        scene(
            ["2027-02-01", "2027-02-08"],
            semesters=[
                sem(),
                sem(
                    "sem2", start_date="2027-02-01", end_date="2027-06-30", week1_start="2027-02-01"
                ),
            ],
            slots=[
                *base()["slots"],
                {
                    **slot("s-other", 1, 1, None, title="Весенняя", cycle_week=2),
                    "semester_id": "sem2",
                },
            ],
            bells=[*base()["bells"], bell(1, "09:00", "10:30", semester="sem2")],
        ),
    ),
    (
        "an_archived_semester_is_ignored",
        scene(["2026-09-14"], semesters=[sem(archived=True)]),
    ),
    (
        "overlapping_semesters_the_latest_start_wins",
        scene(
            ["2026-10-05"],
            semesters=[
                sem(),
                sem(
                    "sem2", start_date="2026-10-01", end_date="2026-12-31", week1_start="2026-10-05"
                ),
            ],
            slots=[
                *base()["slots"],
                {**slot("s-new", 1, 2, None, title="Новая"), "semester_id": "sem2"},
            ],
        ),
    ),
    (
        "two_lessons_at_the_same_time_keep_a_stable_order",
        scene(
            ["2026-09-07"],
            slots=with_slots(
                slot("s-a", 1, 1, PROG, "practice"), slot("s-b", 1, 1, PHYS, "lecture")
            ),
        ),
    ),
    (
        "the_override_of_another_date_does_not_apply",
        scene(["2026-09-14"], overrides=[override("o-1", "s-mon-1", "2026-09-07", "cancel")]),
    ),
]


OVERLAP_SEMESTERS = [
    sem(),
    sem("sem2", start_date="2026-10-01", end_date="2026-12-31", week1_start="2026-10-05"),
]

EXPAND += [
    (
        "a_move_of_a_lesson_on_the_wrong_cycle_week_shows_nothing_ghostly",
        scene(
            ["2026-09-07", "2026-09-11"],
            overrides=[override("o-1", "s-mon-2", "2026-09-07", "move", new_date="2026-09-11")],
        ),
    ),
    (
        "a_move_from_a_weekday_the_lesson_does_not_have_shows_nothing_ghostly",
        scene(
            ["2026-09-08", "2026-09-11"],
            overrides=[override("o-1", "s-wed-1", "2026-09-08", "move", new_date="2026-09-11")],
        ),
    ),
    (
        "a_move_from_a_date_before_the_semester_shows_nothing_ghostly",
        scene(
            ["2026-08-26", "2026-09-04"],
            overrides=[override("o-1", "s-wed-1", "2026-08-26", "move", new_date="2026-09-04")],
        ),
    ),
    (
        "a_move_to_a_date_after_the_semester_is_ignored_and_the_lesson_stays",
        scene(
            ["2026-12-30", "2027-01-02"],
            overrides=[override("o-1", "s-wed-1", "2026-12-30", "move", new_date="2027-01-02")],
        ),
    ),
    (
        "a_move_into_another_overlapping_semester_is_ignored_and_the_lesson_stays",
        scene(
            ["2026-09-30", "2026-10-02"],
            semesters=OVERLAP_SEMESTERS,
            slots=[
                *base()["slots"],
                {**slot("s-new", 1, 2, None, title="Новая"), "semester_id": "sem2"},
            ],
            overrides=[override("o-1", "s-wed-1", "2026-09-30", "move", new_date="2026-10-02")],
        ),
    ),
]


def run_expand(given: dict[str, Any]) -> Any:
    return [
        ref.expand_day(
            day,
            given["semesters"],
            given["subjects"],
            given["bells"],
            given["slots"],
            given["day_rules"],
            given["overrides"],
            given["holidays"],
        )
        for day in given["dates"]
    ]


# ------------------------------------------------------------------ attendance


def att(slot_id: str, date: str, status: str) -> dict[str, Any]:
    return {"slot_id": slot_id, "date": date, "status": status}


def attended(through: str, attendance: list[dict[str, Any]], **over: Any) -> dict[str, Any]:
    data = scene([], **over)
    del data["dates"]
    data["through"] = through
    data["attendance"] = attendance
    return data


ATTENDANCE: list[Case] = [
    ("nothing_marked_everything_is_unmarked", attended("2026-09-14", [])),
    (
        "present_and_absent_are_counted",
        attended(
            "2026-09-14",
            [
                att("s-mon-1", "2026-09-07", "present"),
                att("s-mon-1", "2026-09-14", "absent"),
                att("s-wed-1", "2026-09-02", "absent"),
            ],
        ),
    ),
    (
        "a_lesson_cancelled_by_an_override_is_never_an_absence",
        attended(
            "2026-09-14",
            [att("s-mon-1", "2026-09-07", "absent")],
            overrides=[override("o-1", "s-mon-1", "2026-09-07", "cancel")],
        ),
    ),
    (
        "a_lesson_marked_cancelled_is_not_an_absence",
        attended(
            "2026-09-14",
            [att("s-mon-1", "2026-09-07", "cancelled"), att("s-wed-1", "2026-09-09", "cancelled")],
        ),
    ),
    (
        "olympiad_thursdays_do_not_count_at_all",
        attended(
            "2026-09-17",
            [att("s-thu-1", "2026-09-03", "absent"), att("s-thu-2", "2026-09-10", "absent")],
        ),
    ),
    (
        "lessons_on_holidays_do_not_exist",
        attended(
            "2026-09-14",
            [att("s-mon-1", "2026-09-14", "absent")],
            holidays={"2026-09-14": "Праздник"},
        ),
    ),
    (
        "a_moved_lesson_counts_once_and_its_mark_belongs_to_the_original_date",
        attended(
            "2026-09-12",
            [att("s-wed-1", "2026-09-09", "absent")],
            overrides=[override("o-1", "s-wed-1", "2026-09-09", "move", new_date="2026-09-11")],
        ),
    ),
    (
        "a_moved_lesson_in_the_future_is_not_counted_yet",
        attended(
            "2026-09-10",
            [],
            overrides=[override("o-1", "s-wed-1", "2026-09-09", "move", new_date="2026-09-11")],
        ),
    ),
    (
        "a_replaced_subject_gets_the_lesson",
        attended(
            "2026-09-09",
            [att("s-wed-1", "2026-09-09", "absent")],
            overrides=[override("o-1", "s-wed-1", "2026-09-09", "change", subject_id=PHYS)],
        ),
    ),
    *(
        (
            f"limit_4_with_{count}_absences_is_{state}",
            attended(
                "2026-10-05",
                [
                    att("s-mon-1", day, "absent")
                    for day in (
                        "2026-09-07",
                        "2026-09-14",
                        "2026-09-21",
                        "2026-09-28",
                        "2026-10-05",
                    )[:count]
                ],
            ),
        )
        for count, state in ((0, "ok"), (2, "ok"), (3, "near"), (4, "reached"), (5, "over"))
    ),
    (
        "limit_1_and_limit_2_boundaries",
        attended(
            "2026-09-14",
            [att("s-mon-2", "2026-09-14", "absent"), att("s-wed-1", "2026-09-02", "absent")],
            subjects=[
                subject(MATH, "Математический анализ", "1", "28", 2),
                subject(PHYS, "Физика", "2", "101", 1),
                subject(PROG, "Программирование", None, None, 5),
            ],
        ),
    ),
    (
        "a_subject_without_a_limit",
        attended("2026-09-14", [att("s-tue-3", "2026-09-08", "absent")]),
    ),
    ("through_before_the_semester", attended("2026-08-31", [])),
    ("through_after_the_end_is_clipped", attended("2030-01-01", [])),
    (
        "a_mark_for_a_lesson_that_does_not_occur_is_ignored",
        attended("2026-09-14", [att("s-mon-2", "2026-09-07", "absent")]),
    ),
    (
        "the_same_slot_on_two_dates_is_two_marks",
        attended(
            "2026-09-14",
            [att("s-wed-1", "2026-09-02", "present"), att("s-wed-1", "2026-09-09", "absent")],
        ),
    ),
    (
        "subjects_of_two_semesters_are_counted_apart",
        attended(
            "2027-02-15",
            [att("s-new", "2027-02-08", "absent")],
            semesters=[
                sem(),
                sem(
                    "sem2", start_date="2027-02-01", end_date="2027-06-30", week1_start="2027-02-01"
                ),
            ],
            subjects=[
                *base()["subjects"],
                {**subject("hist", "История", None, None, 2), "semester_id": "sem2"},
            ],
            slots=[
                *base()["slots"],
                {**slot("s-new", 1, 1, "hist"), "semester_id": "sem2"},
            ],
            bells=[*base()["bells"], bell(1, "09:00", "10:30", semester="sem2")],
        ),
    ),
]


ATTENDANCE += [
    (
        "a_ghost_move_is_not_a_lesson_and_not_counted",
        attended(
            "2026-09-14",
            [],
            overrides=[override("o-1", "s-wed-1", "2026-09-08", "move", new_date="2026-09-11")],
        ),
    ),
    (
        "a_move_beyond_the_semester_leaves_the_lesson_counted_where_it_was",
        attended(
            "2027-01-05",
            [att("s-wed-1", "2026-12-30", "absent")],
            overrides=[override("o-1", "s-wed-1", "2026-12-30", "move", new_date="2027-01-02")],
        ),
    ),
    (
        "overlapping_semesters_count_a_date_in_the_winning_semester_only",
        attended(
            "2026-10-12",
            [att("s-mon-1", "2026-10-05", "absent"), att("s-new", "2026-10-05", "absent")],
            semesters=OVERLAP_SEMESTERS,
            subjects=[
                *base()["subjects"],
                {**subject("hist", "История", None, None, 2), "semester_id": "sem2"},
            ],
            slots=[
                *base()["slots"],
                {**slot("s-new", 1, 1, "hist"), "semester_id": "sem2"},
            ],
            bells=[*base()["bells"], bell(1, "09:00", "10:30", semester="sem2")],
        ),
    ),
]


def run_attendance(given: dict[str, Any]) -> Any:
    return ref.attendance_summary(
        given["through"],
        given["semesters"],
        given["subjects"],
        given["bells"],
        given["slots"],
        given["day_rules"],
        given["overrides"],
        given["holidays"],
        given["attendance"],
    )


# ------------------------------------------------------------------ rooms and bells

ROOM_TEXTS = [
    ("k1_28", "к1 28"),
    ("capital_k2_101", "К2 101"),
    ("latin_k", "k1 28"),
    ("latin_capital_k", "K2 101"),
    ("k_space_digit", "к 1 28"),
    ("k_dash", "к1-28"),
    ("k_dot", "к1.28"),
    ("k_slash", "к1/28"),
    ("k_comma", "к2, 101"),
    ("korp_kab", "корп. 2 каб. 101"),
    ("korpus_aud", "Корпус 1 ауд. 305"),
    ("korp_without_dots", "корп 1 каб 12"),
    ("k_with_kab", "к1 каб28"),
    ("digits_dash", "1-28"),
    ("digits_space", "2 101"),
    ("digits_slash", "1/28"),
    ("room_with_a_letter", "к2 101а"),
    ("capital_room_letter", "к1 28Б"),
    ("bare_room", "28"),
    ("bare_room_with_letter", "305а"),
    ("free_text", "Спортзал"),
    ("free_text_with_yo", "Актовый зал Ёлка"),
    ("two_digit_building", "к12 5"),
    ("glued_digits_are_not_split", "к128"),
    ("extra_spaces", "  к1   28  "),
    ("nbsp", "к1 28"),
    ("empty", ""),
    ("blank", "   "),
    ("too_long", "очень длинное название аудитории"),
]
ROOM_FORMATS = [
    ("format_both", "1", "28"),
    ("format_building_only", "2", None),
    ("format_room_only", None, "28"),
    ("format_text_room", None, "Спортзал"),
    ("format_nothing", None, None),
    ("format_empty_strings", "", ""),
]
ROOMS: list[Case] = [
    *((f"parse_{name}", {"op": "parse", "text": text}) for name, text in ROOM_TEXTS),
    *((name, {"op": "format", "building": b, "room": r}) for name, b, r in ROOM_FORMATS),
]


def run_room(given: dict[str, Any]) -> Any:
    if given["op"] == "format":
        return ref.format_room(given["building"], given["room"])
    return ref.parse_room(given["text"])


BELLS: list[Case] = [
    (name, {"first_start": start, "duration": duration, "breaks": breaks, "count": count})
    for name, start, duration, breaks, count in [
        ("classic_ninety_minutes", "08:30", 90, [10, 10, 30, 10, 10], 6),
        ("one_break_for_all", "09:00", 80, 10, 4),
        ("zero_breaks", "08:00", 45, 0, 3),
        ("single_pair", "08:30", 90, [], 1),
        ("a_long_break_list_is_cut", "08:30", 90, [10, 10, 10, 10, 10, 10, 10], 3),
        ("too_few_breaks", "08:30", 90, [10], 3),
        ("break_too_long", "08:30", 90, [241], 2),
        ("pair_too_long", "08:30", 301, 10, 2),
        ("pair_too_short", "08:30", 0, 10, 2),
        ("too_many_pairs", "08:30", 40, 5, 13),
        ("no_pairs", "08:30", 90, 10, 0),
        ("bad_time", "8:30", 90, 10, 2),
        ("ends_after_midnight", "20:00", 90, 10, 4),
        ("ends_exactly_at_2359", "22:29", 90, 0, 1),
        ("one_minute_past_2359", "22:30", 90, 0, 1),
    ]
]


def run_bells(given: dict[str, Any]) -> Any:
    found = ref.generate_bells(
        given["first_start"], given["duration"], given["breaks"], given["count"]
    )
    return {"error": True} if found is None else found


# ------------------------------------------------------------------ week cycle

CYCLES: list[Case] = [
    (name, {"semester": semester, "dates": dates})
    for name, semester, dates in [
        (
            "two_week_cycle_from_the_anchor",
            sem(),
            ["2026-08-31", "2026-09-06", "2026-09-07", "2026-09-13", "2026-09-14"],
        ),
        (
            "anchor_in_the_middle_of_a_week",
            sem(week1_start="2026-09-03"),
            ["2026-08-31", "2026-09-07"],
        ),
        (
            "dates_before_the_anchor",
            sem(week1_start="2026-09-14"),
            ["2026-09-07", "2026-08-31", "2026-08-24"],
        ),
        ("one_week_cycle", sem(cycle_length=1), ["2026-09-01", "2026-09-08"]),
        (
            "three_week_cycle",
            sem(cycle_length=3),
            ["2026-09-01", "2026-09-08", "2026-09-15", "2026-09-22"],
        ),
        (
            "shift_applies_from_its_monday",
            sem(week_shifts=[{"from": "2026-10-07", "weeks": 1}]),
            ["2026-10-04", "2026-10-05", "2026-10-11", "2026-10-12"],
        ),
        (
            "negative_and_double_shifts",
            sem(
                week_shifts=[
                    {"from": "2026-10-05", "weeks": 2},
                    {"from": "2026-11-02", "weeks": -1},
                ]
            ),
            ["2026-10-05", "2026-11-01", "2026-11-02"],
        ),
    ]
]


def run_cycle(given: dict[str, Any]) -> Any:
    return [ref.week_number(day, given["semester"]) for day in given["dates"]]


FILES: dict[str, tuple[str, list[Case], Callable[[dict[str, Any]], Any]]] = {
    "expand": (
        "expand_day(date, semesters, subjects, bells, slots, day_rules, overrides, holidays) for "
        "every date of input.dates: the schedule of a date",
        EXPAND,
        run_expand,
    ),
    "attendance": (
        "attendance_summary(through, semesters, subjects, bells, slots, day_rules, overrides, "
        "holidays, attendance): counters per subject",
        ATTENDANCE,
        run_attendance,
    ),
    "rooms": (
        "parse_room(text) (op parse) and format_room(building, room) (op format)",
        ROOMS,
        run_room,
    ),
    "bells": (
        "generate_bells(first_start, duration, breaks, count)",
        BELLS,
        run_bells,
    ),
    "cycle": (
        "week_number(date, semester): the cycle week of every date of input.dates",
        CYCLES,
        run_cycle,
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
