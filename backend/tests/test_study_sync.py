"""Stage 7 tables through the real sync engine: round trip, cascades, trash, deterministic ids,
offline merges and the physical purge."""

from typing import Any

from tasker.ids import uuid7
from tasker.study import reference as ref
from tasker.study.tables import STUDY_TABLES
from tasker.sync.modules import build_registry
from tasker.sync.purge import purge_tombstones
from tests.api_support import DeviceClient, Env
from tests.study_support import (
    JPEG,
    PDF,
    attachment_fields,
    attendance_fields,
    attendance_row_id,
    bell_fields,
    bell_row_id,
    override_fields,
    override_row_id,
    rule_fields,
    rule_row_id,
    slot_fields,
    study_seed,
)
from tests.test_calendar_sync import deleted, pull_rows

STUDY_NAMES = (
    "study_semesters",
    "study_subjects",
    "study_bells",
    "class_slots",
    "study_day_rules",
    "class_overrides",
    "study_attendance",
    "study_debts",
    "attachments",
)


async def head(dc: DeviceClient) -> int:
    return int((await dc.pull_ok(0))["head_version"])


def live(rows: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    return [dict(r) for r in rows.values() if r["deleted_at"] is None]


def test_registry_has_the_study_tables_parents_first() -> None:
    names = [spec.name for spec in build_registry().tables()]
    assert [spec.name for spec in STUDY_TABLES] == list(STUDY_NAMES)
    for parent, child in (
        ("study_semesters", "study_subjects"),
        ("study_semesters", "class_slots"),
        ("study_subjects", "class_slots"),
        ("class_slots", "class_overrides"),
        ("class_slots", "study_attendance"),
        ("study_subjects", "study_debts"),
        ("study_debts", "attachments"),
    ):
        assert names.index(parent) < names.index(child)


async def test_the_schedule_survives_the_round_trip(env: Env) -> None:
    """Rows pulled by a second device give the Thursday of the customer."""
    phone = await env.login()
    seed = await study_seed(phone)
    pc = await env.login("PC")
    rows = await pull_rows(pc)

    def day(date: str) -> dict[str, Any]:
        return ref.expand_day(
            date,
            live(rows["study_semesters"]),
            live(rows["study_subjects"]),
            live(rows["study_bells"]),
            live(rows["class_slots"]),
            live(rows["study_day_rules"]),
            [],
            {},
        )

    thursday = day("2026-09-10")
    assert thursday["day"]["kind"] == "special"
    assert [x["title"] for x in thursday["lessons"]] == ["Подготовка к олимпиаде"]
    monday = day("2026-09-14")  # odd week: lecture and lab
    assert [(x["start"], x["title"], x["room_text"]) for x in monday["lessons"]] == [
        ("08:30", "Математический анализ", "к1 28"),
        ("10:10", "Физика", "к2 101"),
    ]
    assert [x["title"] for x in day("2026-09-07")["lessons"]] == ["Математический анализ"]
    assert str(rows["study_day_rules"][str(seed.rule)]["items"][0]["key"]) == "o1"
    assert rows["study_semesters"][str(seed.semester)]["week_shifts"] is None


async def test_bells_are_deterministic_so_two_devices_make_one_row(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    seed = await study_seed(phone)
    again = bell_fields(pc, seed.semester, 1, start_time="08:30", end_time="10:00")
    (result,) = await pc.push_ok([pc.op("study_bells", bell_row_id(again), fields=again)])
    assert result["status"] == "applied"
    assert await env.scalar("SELECT count(*) FROM study_bells") == 3
    # the same number for one date is another row
    dated = bell_fields(
        pc, seed.semester, 1, on_date="2026-09-14", start_time="07:50", end_time="09:20"
    )
    await pc.push_ok([pc.op("study_bells", bell_row_id(dated), fields=dated)])
    assert await env.scalar("SELECT count(*) FROM study_bells") == 4


async def test_two_devices_marking_the_same_lesson_merge_into_one_mark(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    seed = await study_seed(phone)
    first = attendance_fields(phone, seed.mon1, status="absent")
    row = attendance_row_id(first)
    await phone.push_ok([phone.op("study_attendance", row, fields=first)])
    second = attendance_fields(pc, seed.mon1, status="present")
    (result,) = await pc.push_ok([pc.op("study_attendance", row, fields=second)])
    assert result["status"] == "applied"
    assert await env.scalar("SELECT count(*) FROM study_attendance") == 1
    seen = await head(phone)
    # a note on one device and a status on the other merge field by field
    await phone.push_ok([phone.op("study_attendance", row, fields={"note": "болел"}, base=seen)])
    await pc.push_ok([pc.op("study_attendance", row, fields={"status": "cancelled"}, base=seen)])
    mark = (await pull_rows(phone))["study_attendance"][str(row)]
    assert (mark["status"], mark["note"]) == ("cancelled", "болел")


async def test_two_devices_overriding_the_same_lesson_make_one_override(env: Env) -> None:
    phone, pc = await env.login(), await env.login("PC")
    seed = await study_seed(phone)
    cancel = override_fields(phone, seed.mon1)
    row = override_row_id(cancel)
    await phone.push_ok([phone.op("class_overrides", row, fields=cancel)])
    change = override_fields(pc, seed.mon1, action="change", room="305")
    await pc.push_ok([pc.op("class_overrides", row, fields=change)])
    assert await env.scalar("SELECT count(*) FROM class_overrides") == 1
    rule = rule_fields(pc, seed.semester, weekday=4)
    assert rule_row_id(rule) == seed.rule
    (same,) = await pc.push_ok([pc.op("study_day_rules", seed.rule, fields=rule)])
    assert same["status"] == "applied"
    assert await env.scalar("SELECT count(*) FROM study_day_rules") == 1


async def test_deleting_a_semester_trashes_everything_under_it(env: Env) -> None:
    phone = await env.login()
    seed = await study_seed(phone)
    mark = attendance_fields(phone, seed.mon1)
    cancel = override_fields(phone, seed.mon1)
    attachment = uuid7()
    await phone.push_ok(
        [
            phone.op("study_attendance", attendance_row_id(mark), fields=mark),
            phone.op("class_overrides", override_row_id(cancel), fields=cancel),
            phone.op(
                "attachments", attachment, fields=attachment_fields(phone, JPEG, debt=seed.debt_lab)
            ),
        ]
    )
    await phone.push_ok(
        [phone.op("study_semesters", seed.semester, "delete", base=await head(phone))]
    )
    for table in STUDY_NAMES:
        total = int(await env.scalar(f"SELECT count(*) FROM {table}"))  # noqa: S608
        assert await deleted(env, table) == total > 0, table
    await phone.push_ok(
        [
            phone.op(
                "study_semesters",
                seed.semester,
                fields={"deleted_at": None},
                base=await head(phone),
            )
        ]
    )
    for table in STUDY_NAMES:
        assert await deleted(env, table) == 0, table


async def test_deleting_a_subject_takes_its_slots_debts_files_and_their_children(env: Env) -> None:
    phone = await env.login()
    seed = await study_seed(phone)
    mark = attendance_fields(phone, seed.mon1)
    keep = attendance_fields(phone, seed.mon2)
    on_subject, on_debt = uuid7(), uuid7()
    await phone.push_ok(
        [
            phone.op("study_attendance", attendance_row_id(mark), fields=mark),
            phone.op("study_attendance", attendance_row_id(keep), fields=keep),
            phone.op(
                "attachments", on_subject, fields=attachment_fields(phone, JPEG, subject=seed.math)
            ),
            phone.op(
                "attachments",
                on_debt,
                fields=attachment_fields(
                    phone, PDF, debt=seed.debt_lab, file_name="t.pdf", mime_type="application/pdf"
                ),
            ),
        ]
    )
    await phone.push_ok([phone.op("study_subjects", seed.math, "delete", base=await head(phone))])
    assert await deleted(env, "study_subjects") == 1
    assert await deleted(env, "class_slots") == 2  # Monday lecture and the Thursday pair
    assert await deleted(env, "study_debts") == 1
    assert await deleted(env, "attachments") == 2
    assert await deleted(env, "study_attendance") == 1  # only the math lecture's mark
    assert await deleted(env, "study_semesters") == 0
    assert await deleted(env, "study_day_rules") == 0
    rows = await pull_rows(phone)
    assert rows["class_slots"][str(seed.mon2)]["deleted_at"] is None
    await phone.push_ok(
        [phone.op("study_subjects", seed.math, fields={"deleted_at": None}, base=await head(phone))]
    )
    for table in (
        "study_subjects",
        "class_slots",
        "study_debts",
        "attachments",
        "study_attendance",
    ):
        assert await deleted(env, table) == 0, table


async def test_deleting_a_slot_removes_its_history_and_a_debt_its_files(env: Env) -> None:
    phone = await env.login()
    seed = await study_seed(phone)
    mark = attendance_fields(phone, seed.mon1)
    cancel = override_fields(phone, seed.mon1)
    on_debt = uuid7()
    await phone.push_ok(
        [
            phone.op("study_attendance", attendance_row_id(mark), fields=mark),
            phone.op("class_overrides", override_row_id(cancel), fields=cancel),
            phone.op(
                "attachments", on_debt, fields=attachment_fields(phone, JPEG, debt=seed.debt_lab)
            ),
        ]
    )
    await phone.push_ok([phone.op("class_slots", seed.mon1, "delete", base=await head(phone))])
    assert await deleted(env, "study_attendance") == 1
    assert await deleted(env, "class_overrides") == 1
    assert await deleted(env, "class_slots") == 1
    await phone.push_ok([phone.op("study_debts", seed.debt_lab, "delete", base=await head(phone))])
    assert await deleted(env, "attachments") == 1
    assert await deleted(env, "study_debts") == 1


async def test_a_slot_of_a_deleted_semester_is_created_in_the_trash(env: Env) -> None:
    phone = await env.login()
    seed = await study_seed(phone)
    await phone.push_ok(
        [phone.op("study_semesters", seed.semester, "delete", base=await head(phone))]
    )
    late = uuid7()
    (result,) = await phone.push_ok(
        [phone.op("class_slots", late, fields=slot_fields(phone, seed.semester))]
    )
    assert result["status"] == "applied"
    assert (await pull_rows(phone))["class_slots"][str(late)]["deleted_at"] is not None


async def test_purge_removes_children_before_parents(env: Env) -> None:
    phone = await env.login()
    seed = await study_seed(phone)
    mark = attendance_fields(phone, seed.mon1)
    await phone.push_ok([phone.op("study_attendance", attendance_row_id(mark), fields=mark)])
    await phone.push_ok(
        [phone.op("study_semesters", seed.semester, "delete", base=await head(phone))]
    )
    top = await head(phone)
    env.clock.advance(days=31)
    await phone.refresh()
    await phone.pull_ok(top)
    total = sum([int(await env.scalar(f"SELECT count(*) FROM {t}")) for t in STUDY_NAMES])  # noqa: S608
    purged = await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now())
    assert purged == total > 0
    for table in STUDY_NAMES:
        assert await env.scalar(f"SELECT count(*) FROM {table}") == 0  # noqa: S608


async def test_a_young_trash_is_kept(env: Env) -> None:
    phone = await env.login()
    seed = await study_seed(phone)
    await phone.push_ok([phone.op("study_subjects", seed.phys, "delete", base=await head(phone))])
    top = await head(phone)
    env.clock.advance(days=29)
    await phone.refresh()
    await phone.pull_ok(top)
    assert await purge_tombstones(env.sessionmaker, env.rt.registry, env.clock.now()) == 0
