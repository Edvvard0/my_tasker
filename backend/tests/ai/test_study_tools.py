"""The Study read tools on seeded data: schedule, absences, debts."""

import json
import uuid
from typing import Any
from zoneinfo import ZoneInfo

import pytest

import tasker.ai.builtin  # noqa: F401 - registers the tools
from tasker.ai.agents import STUDY_TOOLS, builtin_tools
from tasker.ai.tools import TOOLS, ToolArgumentError, ToolContext
from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.study_support import (
    JPEG,
    StudySeed,
    attachment_fields,
    attendance_fields,
    attendance_row_id,
    debt_fields,
    override_fields,
    override_row_id,
    study_seed,
)


async def call(env: Env, name: str, args: dict[str, Any]) -> dict[str, Any]:
    spec = TOOLS.get(name)
    assert spec is not None
    assert spec.handler is not None
    ctx = ToolContext(env.sessionmaker, ZoneInfo("Europe/Moscow"))
    text = await spec.handler(ctx, spec.parse(args))
    assert len(text) <= 20_000
    result: dict[str, Any] = json.loads(text)
    return result


async def head(dc: DeviceClient) -> int:
    return int((await dc.pull_ok(0))["head_version"])


async def seeded(env: Env) -> tuple[DeviceClient, StudySeed]:
    phone = await env.login()
    return phone, await study_seed(phone)


def test_the_tools_are_read_tools_of_the_study_profile() -> None:
    for name in STUDY_TOOLS:
        spec = TOOLS.get(name)
        assert spec is not None
        assert spec.kind == "read"
    assert builtin_tools("study")[-3:] == STUDY_TOOLS
    assert "get_study_schedule" not in builtin_tools("finance")
    assert "get_accounts" not in builtin_tools("study")


async def test_schedule_shows_lessons_special_days_and_skips_empty_ones(env: Env) -> None:
    await seeded(env)
    result = await call(
        env, "get_study_schedule", {"from_date": "2026-09-07", "to_date": "2026-09-14"}
    )
    assert result["period"] == {"from": "2026-09-07", "to": "2026-09-14"}
    days = {d["date"]: d for d in result["days"]}
    assert sorted(days) == ["2026-09-07", "2026-09-10", "2026-09-14"]  # empty days are left out
    assert result["count"] == 3
    monday = days["2026-09-07"]
    assert (monday["kind"], monday["weekday"], monday["cycle_week"]) == ("regular", 1, 2)
    assert monday["lessons"] == [
        {
            "number": 1,
            "start": "08:30",
            "end": "10:00",
            "title": "Математический анализ",
            "kind": "lecture",
            "room": "к1 28",
            "teacher": "Иванов И. И.",
            "cancelled": False,
            "changed": False,
            "moved_from": None,
            "moved_to": None,
        }
    ]
    thursday = days["2026-09-10"]
    assert (thursday["kind"], thursday["name"]) == ("special", "Подготовка к олимпиаде")
    assert [lesson["title"] for lesson in thursday["lessons"]] == ["Подготовка к олимпиаде"]
    assert thursday["lessons"][0]["teacher"] is None
    assert [x["title"] for x in days["2026-09-14"]["lessons"]] == [
        "Математический анализ",
        "Физика",
    ]
    assert days["2026-09-14"]["lessons"][1]["room"] == "к2 101"


async def test_schedule_follows_overrides_and_holidays(env: Env) -> None:
    phone, seed = await seeded(env)
    cancel = override_fields(phone, seed.mon1, date="2026-11-02")
    await phone.push_ok([phone.op("class_overrides", override_row_id(cancel), fields=cancel)])
    result = await call(
        env, "get_study_schedule", {"from_date": "2026-11-02", "to_date": "2026-11-04"}
    )
    days = {d["date"]: d for d in result["days"]}
    assert days["2026-11-02"]["lessons"][0]["cancelled"] is True
    # 2026-11-04 is Unity Day in the shared holiday file
    assert days["2026-11-04"]["kind"] == "holiday"
    assert days["2026-11-04"]["lessons"] == []


async def test_schedule_says_how_far_the_holiday_file_reaches(env: Env) -> None:
    await seeded(env)
    covered = await call(
        env, "get_study_schedule", {"from_date": "2027-12-27", "to_date": "2027-12-31"}
    )
    assert covered["holidays_covered_until"] == "2027-12-31"
    assert "holidays_warning" not in covered
    beyond = await call(
        env, "get_study_schedule", {"from_date": "2027-12-30", "to_date": "2028-01-03"}
    )
    assert beyond["holidays_covered_until"] == "2027-12-31"
    assert "2028" in beyond["holidays_warning"]
    assert "2027" not in beyond["holidays_warning"]
    before = await call(
        env, "get_study_schedule", {"from_date": "2025-12-30", "to_date": "2026-01-02"}
    )
    assert "2025" in before["holidays_warning"]


async def test_absences_say_how_far_the_holiday_file_reaches(env: Env) -> None:
    await seeded(env)
    inside = await call(env, "get_study_absences", {"through_date": "2026-09-30"})
    assert inside["holidays_covered_until"] == "2027-12-31"
    assert "holidays_warning" not in inside
    beyond = await call(env, "get_study_absences", {"through_date": "2029-01-01"})
    assert "2028, 2029" in beyond["holidays_warning"]
    empty = await call(env, "get_study_absences", {"through_date": "2020-01-01"})
    assert "holidays_warning" not in empty  # nothing is expanded before the semester


async def test_schedule_argument_errors(env: Env) -> None:
    await seeded(env)
    for bad in (
        {"from_date": "2026-09-14", "to_date": "2026-09-07"},
        {"from_date": "2026-02-30", "to_date": "2026-03-01"},
        {"from_date": "2026-09-01", "to_date": "2026-10-02"},  # 32 days
        {"from_date": "2026-09-01"},
        {"from_date": "1.9.2026", "to_date": "2026-09-02"},
    ):
        with pytest.raises(ToolArgumentError):
            await call(env, "get_study_schedule", bad)
    thirty_one = await call(
        env, "get_study_schedule", {"from_date": "2026-09-01", "to_date": "2026-10-01"}
    )
    assert thirty_one["count"] > 0


async def test_absences_are_counted_per_subject(env: Env) -> None:
    phone, seed = await seeded(env)
    marks = [
        attendance_fields(phone, seed.mon1, date="2026-09-07", status="absent"),
        attendance_fields(phone, seed.mon1, date="2026-09-14", status="present"),
        attendance_fields(phone, seed.mon2, date="2026-09-14", status="absent"),
    ]
    await phone.push_ok(
        [phone.op("study_attendance", attendance_row_id(m), fields=m) for m in marks]
    )
    result = await call(env, "get_study_absences", {"through_date": "2026-09-14"})
    by_name = {s["subject"]: s for s in result["subjects"]}
    assert result["through"] == "2026-09-14"
    assert by_name["Математический анализ"]["absent"] == 1
    assert by_name["Математический анализ"]["present"] == 1
    assert by_name["Математический анализ"]["left"] == 3
    assert by_name["Математический анализ"]["state"] == "ok"
    assert by_name["Математический анализ"]["teacher"] == "Иванов И. И."
    assert by_name["Физика"]["absent"] == 1
    assert by_name["Физика"]["limit"] == 3
    assert by_name["Физика"]["semester"] == "Осень 2026"
    # the math lecture of Mondays 7 (absent), 14 (present), 21 and 28 (unmarked); the math pair
    # of the olympiad Thursdays is not a lesson at all
    only = await call(
        env,
        "get_study_absences",
        {"through_date": "2026-09-30", "subject_id": str(seed.math)},
    )
    assert [s["subject_id"] for s in only["subjects"]] == [str(seed.math)]
    counts = {k: only["subjects"][0][k] for k in ("present", "absent", "cancelled", "unmarked")}
    assert counts == {"present": 1, "absent": 1, "cancelled": 0, "unmarked": 2}


async def test_absences_default_to_today_and_skip_archived_subjects(env: Env) -> None:
    phone, seed = await seeded(env)
    result = await call(env, "get_study_absences", {})
    assert len(result["subjects"]) == 2
    assert result["through"] >= "2026-01-01"
    await phone.push_ok(
        [phone.op("study_subjects", seed.phys, fields={"archived": True}, base=await head(phone))]
    )
    names = [s["subject"] for s in (await call(env, "get_study_absences", {}))["subjects"]]
    assert names == ["Математический анализ"]
    with pytest.raises(ToolArgumentError):
        await call(env, "get_study_absences", {"through_date": "2026-02-30"})
    with pytest.raises(ToolArgumentError):
        await call(env, "get_study_absences", {"subject_id": "not-a-uuid"})


async def test_absences_before_any_semester(env: Env) -> None:
    await env.login()
    result = await call(env, "get_study_absences", {})
    assert result["subjects"] == []


async def test_absences_through_a_date_before_the_semester(env: Env) -> None:
    await seeded(env)
    result = await call(env, "get_study_absences", {"through_date": "2020-01-01"})
    assert {s["unmarked"] for s in result["subjects"]} == {0}


async def test_debts_open_by_default_with_overdue_and_attachments(env: Env) -> None:
    phone, seed = await seeded(env)
    late, future, undated = uuid7(), uuid7(), uuid7()
    await phone.push_ok(
        [
            phone.op(
                "study_debts",
                late,
                fields=debt_fields(
                    phone, seed.math, title="Старая", due_date="2020-01-01", note="x" * 400
                ),
            ),
            phone.op(
                "study_debts",
                future,
                fields=debt_fields(phone, seed.math, title="Далёкая", due_date="2099-12-31"),
            ),
            phone.op(
                "study_debts",
                undated,
                fields=debt_fields(phone, seed.phys, title="Без срока", kind="practice"),
            ),
            phone.op("attachments", uuid7(), fields=attachment_fields(phone, JPEG, debt=late)),
            phone.op("attachments", uuid7(), fields=attachment_fields(phone, JPEG, debt=late)),
        ]
    )
    result = await call(env, "get_study_debts", {})
    titles = [d["title"] for d in result["debts"]]
    # open ones by due date (none last): the exam is "submitted" and is left out
    assert titles == ["Старая", "ЛР 3", "Далёкая", "Без срока"]
    first = result["debts"][0]
    assert (first["overdue"], first["attachments"], first["status"]) == (True, 2, "open")
    assert len(first["note"]) == 300
    assert result["debts"][2]["overdue"] is False
    assert result["debts"][1]["subject"] == "Математический анализ"
    assert result["debts"][1]["kind"] == "lab"
    assert result["truncated"] is False
    everything = await call(env, "get_study_debts", {"status": "all"})
    assert "Экзамен" in [d["title"] for d in everything["debts"]]
    done = await call(env, "get_study_debts", {"status": "submitted"})
    assert [d["title"] for d in done["debts"]] == ["Экзамен"]
    assert done["debts"][0]["overdue"] is False
    one = await call(env, "get_study_debts", {"subject_id": str(seed.phys), "status": "all"})
    assert {d["subject"] for d in one["debts"]} == {"Физика"}
    limited = await call(env, "get_study_debts", {"limit": 2})
    assert (limited["count"], limited["truncated"]) == (2, True)


async def test_debts_of_deleted_subjects_are_hidden_and_arguments_are_checked(env: Env) -> None:
    phone, seed = await seeded(env)
    await phone.push_ok([phone.op("study_subjects", seed.phys, "delete", base=await head(phone))])
    result = await call(env, "get_study_debts", {"status": "all"})
    assert {d["subject"] for d in result["debts"]} == {"Математический анализ"}
    for bad in ({"status": "done"}, {"limit": 0}, {"limit": 101}, {"subject_id": 5}):
        with pytest.raises(ToolArgumentError):
            await call(env, "get_study_debts", bad)


async def test_a_long_list_is_clipped_and_marked(env: Env) -> None:
    phone, seed = await seeded(env)
    ops = [
        phone.op(
            "study_debts",
            uuid.UUID(int=(0x0190_0000_0000_7000_8000_0000_0000_0000 + n)),
            fields=debt_fields(phone, seed.math, title=f"Работа {n}", note="я" * 290),
        )
        for n in range(100)
    ]
    await phone.push_ok(ops)
    result = await call(env, "get_study_debts", {"limit": 100})
    assert result["truncated"] is True
    assert 0 < result["count"] < 100
    assert result["count"] == len(result["debts"])
