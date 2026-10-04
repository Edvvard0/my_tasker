"""Server-side validation of the Stage 7 tables, driven through the real push endpoint."""

import uuid
from dataclasses import dataclass
from typing import Any

import pytest

from tasker.ids import uuid7
from tests.api_support import DeviceClient, Env
from tests.study_support import (
    JPEG,
    PDF,
    attachment_fields,
    attendance_fields,
    attendance_row_id,
    bell_fields,
    bell_row_id,
    debt_fields,
    file_meta,
    override_fields,
    override_row_id,
    rule_fields,
    rule_row_id,
    semester_fields,
    slot_fields,
    subject_fields,
)
from tests.test_work_validation import Case, run_cases


@pytest.fixture
async def phone(env: Env) -> DeviceClient:
    return await env.login()


@dataclass
class Graph:
    semester: uuid.UUID
    subject: uuid.UUID
    slot: uuid.UUID
    debt: uuid.UUID


@pytest.fixture
async def graph(phone: DeviceClient) -> Graph:
    g = Graph(uuid7(), uuid7(), uuid7(), uuid7())
    await phone.push_ok(
        [
            phone.op("study_semesters", g.semester, fields=semester_fields(phone)),
            phone.op("study_subjects", g.subject, fields=subject_fields(phone, g.semester)),
            phone.op(
                "class_slots",
                g.slot,
                fields=slot_fields(phone, g.semester, subject_id=str(g.subject), title=None),
            ),
            phone.op("study_debts", g.debt, fields=debt_fields(phone, g.subject)),
        ]
    )
    return g


async def test_semester_columns(phone: DeviceClient) -> None:
    def case(label: str, expected: str | None, **over: Any) -> Case:
        return (label, "study_semesters", None, semester_fields(phone, **over), expected)

    shifts = [{"from": "2026-10-05", "weeks": 1}, {"from": "2026-11-02", "weeks": -2}]
    await run_cases(
        phone,
        [
            case("plain semester", None),
            case("with shifts", None, week_shifts=shifts),
            case("one-day semester", None, start_date="2026-09-01", end_date="2026-09-01"),
            case("cycle of one", None, cycle_length=1),
            case("cycle of eight", None, cycle_length=8),
            case("cycle of nine", "invalid_field", cycle_length=9),
            case("cycle of zero", "invalid_field", cycle_length=0),
            case("float cycle", "invalid_field", cycle_length=2.5),
            case("blank name", "validation_failed", name="  "),
            case("long name", "invalid_field", name="x" * 101),
            case("end before start", "validation_failed", end_date="2026-08-31"),
            case("more than 400 days", "validation_failed", end_date="2027-10-10"),
            case("exactly 400 days", None, end_date="2027-10-06"),
            case("not a date", "invalid_field", start_date="1.9.2026"),
            case("february 30", "validation_failed", start_date="2026-02-30"),
            case("anchor is not a date", "validation_failed", week1_start="2026-13-01"),
            case("shifts not a list", "validation_failed", week_shifts={"from": "2026-10-05"}),
            case(
                "shift with extra key",
                "validation_failed",
                week_shifts=[{"from": "2026-10-05", "weeks": 1, "x": 1}],
            ),
            case(
                "shift with a bad date",
                "validation_failed",
                week_shifts=[{"from": "x", "weeks": 1}],
            ),
            case(
                "shift too far",
                "validation_failed",
                week_shifts=[{"from": "2026-10-05", "weeks": 9}],
            ),
            case(
                "shift float",
                "validation_failed",
                week_shifts=[{"from": "2026-10-05", "weeks": 1.5}],
            ),
            case("shift not an object", "validation_failed", week_shifts=[1]),
            case(
                "too many shifts",
                "validation_failed",
                week_shifts=[{"from": "2026-10-05", "weeks": 1}] * 31,
            ),
            case("archived must be a bool", "invalid_field", archived="no"),
        ],
    )
    fields = semester_fields(phone)
    del fields["week1_start"]
    (result,) = await phone.push_ok([phone.op("study_semesters", uuid7(), fields=fields)])
    assert (result["status"], result["code"]) == ("rejected", "missing_fields")


async def test_subject_columns(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, **over: Any) -> Case:
        return (
            label,
            "study_subjects",
            None,
            subject_fields(phone, graph.semester, **over),
            expected,
        )

    await run_cases(
        phone,
        [
            case("plain", None),
            case(
                "full",
                None,
                teacher="Иванов Иван Иванович",
                building="2",
                room="305а",
                absence_limit=5,
                note="Заметка",
            ),
            case("blank name", "validation_failed", name=" "),
            case("limit zero", "invalid_field", absence_limit=0),
            case("limit 1000", "invalid_field", absence_limit=1000),
            case("building with a space", "invalid_field", building="к 1"),
            case("building too long", "invalid_field", building="12345678901"),
            case("room too long", "invalid_field", room="x" * 21),
            case("long teacher", "invalid_field", teacher="x" * 201),
            case("long note", "invalid_field", note="x" * 5001),
            (
                "missing parent",
                "study_subjects",
                None,
                subject_fields(phone, uuid7()),
                "parent_not_found",
            ),
        ],
    )


async def test_bell_columns_and_deterministic_ids(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, number: int = 1, **over: Any) -> Case:
        fields = bell_fields(phone, graph.semester, number, **over)
        return (label, "study_bells", bell_row_id(fields), fields, expected)

    await run_cases(
        phone,
        [
            case("regular bell", None),
            case("bell for one date", None, 2, on_date="2026-09-14"),
            case("number 12", None, 12),
            case("number 13", "invalid_field", 13),
            case("number 0", "invalid_field", 0),
            case("end before start", "validation_failed", 3, start_time="10:00", end_time="09:00"),
            case("zero length", "validation_failed", 4, start_time="10:00", end_time="10:00"),
            case("24:00", "invalid_field", 5, end_time="24:00"),
            case("8:30 without a zero", "invalid_field", 6, start_time="8:30"),
            case("bad date", "validation_failed", 7, on_date="2026-02-30"),
        ],
    )
    fields = bell_fields(phone, graph.semester, 9)
    (wrong,) = await phone.push_ok([phone.op("study_bells", uuid7(), fields=fields)])
    assert (wrong["status"], wrong["code"]) == ("rejected", "invalid_id")
    other_day = bell_fields(phone, graph.semester, 9, on_date="2026-09-14")
    (mismatch,) = await phone.push_ok(
        [phone.op("study_bells", bell_row_id(fields), fields=other_day)]
    )
    assert mismatch["code"] == "invalid_id"  # the id belongs to the grid, not to that date


async def test_slot_columns(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, **over: Any) -> Case:
        return (label, "class_slots", None, slot_fields(phone, graph.semester, **over), expected)

    subject = str(graph.subject)
    await run_cases(
        phone,
        [
            case("title only", None),
            case("subject only", None, subject_id=subject, title=None),
            case("subject and title", None, subject_id=subject, title="Лекция"),
            case(
                "own time instead of a number",
                None,
                number=None,
                start_time="09:00",
                end_time="10:30",
            ),
            case("alternating", None, cycle_week=2, building="1", room="28"),
            case("neither subject nor title", "validation_failed", title=None),
            case("blank title", "validation_failed", title=" "),
            case(
                "blank title next to a subject", "validation_failed", subject_id=subject, title=" "
            ),
            case("neither number nor time", "validation_failed", number=None),
            case("only a start", "validation_failed", start_time="09:00"),
            case("end before start", "validation_failed", start_time="10:00", end_time="09:00"),
            case("weekday 0", "invalid_field", weekday=0),
            case("weekday 8", "invalid_field", weekday=8),
            case("unknown kind", "invalid_field", kind="seminar"),
            case("kinds are all valid", None, kind="lab"),
            case("cycle week 9", "invalid_field", cycle_week=9),
            case("subject does not exist", "parent_not_found", subject_id=str(uuid7()), title=None),
            case("bad time", "invalid_field", number=None, start_time="25:00", end_time="26:00"),
        ],
    )


async def test_day_rule_columns_and_ids(phone: DeviceClient, graph: Graph) -> None:
    item = {"key": "a", "title": "Занятие", "kind": "other", "number": 1}

    def case(label: str, expected: str | None, **over: Any) -> Case:
        fields = rule_fields(phone, graph.semester, **over)
        return (label, "study_day_rules", rule_row_id(fields), fields, expected)

    await run_cases(
        phone,
        [
            case("weekday rule", None),
            case("rule for a date", None, weekday=None, on_date="2026-09-17"),
            case("rule for even weeks", None, weekday=2, cycle_week=2),
            case("no items", None, weekday=3, items=[]),
            case("both weekday and date", "validation_failed", on_date="2026-09-30"),
            case("neither", "validation_failed", weekday=None),
            case(
                "cycle week with a date",
                "validation_failed",
                weekday=None,
                on_date="2026-09-18",
                cycle_week=1,
            ),
            case("bad date", "validation_failed", weekday=None, on_date="2026-02-30"),
            case("weekday 9", "invalid_field", weekday=9),
            case("blank title", "validation_failed", weekday=5, title=" "),
            case("items not a list", "validation_failed", weekday=6, items={"a": 1}),
            case("item key twice", "validation_failed", weekday=7, items=[item, item]),
            case(
                "item without a key",
                "validation_failed",
                weekday=1,
                items=[{**item, "key": "Bad Key"}],
            ),
            case(
                "item without a title",
                "validation_failed",
                weekday=2,
                cycle_week=1,
                items=[{**item, "title": ""}],
            ),
            case(
                "item with an unknown kind",
                "validation_failed",
                weekday=3,
                cycle_week=1,
                items=[{**item, "kind": "x"}],
            ),
            case(
                "item without number or time",
                "validation_failed",
                weekday=4,
                cycle_week=1,
                items=[{"key": "a", "title": "T", "kind": "other"}],
            ),
            case(
                "item with a time",
                None,
                weekday=5,
                cycle_week=1,
                items=[
                    {
                        "key": "a",
                        "title": "T",
                        "kind": "lab",
                        "start_time": "09:00",
                        "end_time": "10:30",
                        "room": "5",
                        "building": "1",
                        "cycle_week": 2,
                    }
                ],
            ),
            case(
                "item time order",
                "validation_failed",
                weekday=6,
                cycle_week=1,
                items=[
                    {
                        "key": "a",
                        "title": "T",
                        "kind": "lab",
                        "start_time": "10:00",
                        "end_time": "09:00",
                    }
                ],
            ),
            case(
                "item bad time",
                "validation_failed",
                weekday=7,
                cycle_week=1,
                items=[
                    {"key": "a", "title": "T", "kind": "lab", "start_time": "9", "end_time": "10"}
                ],
            ),
            case(
                "item number 13",
                "validation_failed",
                weekday=1,
                cycle_week=2,
                items=[{**item, "number": 13}],
            ),
            case(
                "item cycle week 9",
                "validation_failed",
                weekday=2,
                cycle_week=3,
                items=[{**item, "cycle_week": 9}],
            ),
            case(
                "item room too long",
                "validation_failed",
                weekday=3,
                cycle_week=2,
                items=[{**item, "room": "x" * 21}],
            ),
            case(
                "item with a stranger key",
                "validation_failed",
                weekday=4,
                cycle_week=2,
                items=[{**item, "color": "red"}],
            ),
            case("item not an object", "validation_failed", weekday=5, cycle_week=2, items=["x"]),
            case(
                "13 items",
                "validation_failed",
                weekday=6,
                cycle_week=2,
                items=[{**item, "key": f"k{n}"} for n in range(13)],
            ),
            case(
                "12 items",
                None,
                weekday=7,
                cycle_week=2,
                items=[{**item, "key": f"k{n}"} for n in range(12)],
            ),
        ],
    )
    fields = rule_fields(phone, graph.semester, weekday=2)
    (wrong,) = await phone.push_ok([phone.op("study_day_rules", uuid7(), fields=fields)])
    assert wrong["code"] == "invalid_id"


async def test_override_columns_and_ids(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, day: str = "2026-09-07", **over: Any) -> Case:
        fields = override_fields(phone, graph.slot, date=day, **over)
        return (label, "class_overrides", override_row_id(fields), fields, expected)

    await run_cases(
        phone,
        [
            case("cancel", None),
            case(
                "cancel ignores the other fields",
                None,
                "2026-09-08",
                room="9",
                start_time="08:00",
                end_time="09:00",
            ),
            case("change room", None, "2026-09-09", action="change", building="2", room="301"),
            case(
                "change time and subject",
                None,
                "2026-09-10",
                action="change",
                start_time="14:00",
                end_time="15:30",
                subject_id=str(uuid7()),
                title="Контрольная",
                lesson_kind="lab",
            ),
            case("move", None, "2026-09-11", action="move", new_date="2026-09-14"),
            case(
                "move to the same day",
                "validation_failed",
                "2026-09-12",
                action="move",
                new_date="2026-09-12",
            ),
            case("move without a date", "validation_failed", "2026-09-13", action="move"),
            case(
                "move to a bad date",
                "validation_failed",
                "2026-09-14",
                action="move",
                new_date="2026-02-30",
            ),
            case(
                "new date on a change",
                "validation_failed",
                "2026-09-15",
                action="change",
                new_date="2026-09-16",
            ),
            case(
                "only a start",
                "validation_failed",
                "2026-09-16",
                action="change",
                start_time="14:00",
            ),
            case(
                "time order",
                "validation_failed",
                "2026-09-17",
                action="change",
                start_time="15:00",
                end_time="14:00",
            ),
            case("unknown action", "invalid_field", "2026-09-18", action="skip"),
            case("blank title", "validation_failed", "2026-09-19", action="change", title=" "),
            case("unknown kind", "invalid_field", "2026-09-20", action="change", lesson_kind="x"),
            case("bad date", "validation_failed", "2026-02-30"),
        ],
    )
    fields = override_fields(phone, graph.slot, date="2026-10-01")
    (wrong,) = await phone.push_ok([phone.op("class_overrides", uuid7(), fields=fields)])
    assert wrong["code"] == "invalid_id"
    orphan = override_fields(phone, uuid7(), date="2026-10-02")
    (missing,) = await phone.push_ok(
        [phone.op("class_overrides", override_row_id(orphan), fields=orphan)]
    )
    assert missing["code"] == "parent_not_found"


async def test_attendance_columns_and_ids(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, day: str = "2026-09-07", **over: Any) -> Case:
        fields = attendance_fields(phone, graph.slot, date=day, **over)
        return (label, "study_attendance", attendance_row_id(fields), fields, expected)

    await run_cases(
        phone,
        [
            case("absent", None),
            case("present with a note", None, "2026-09-14", status="present", note="Был"),
            case("cancelled", None, "2026-09-21", status="cancelled"),
            case("unknown status", "invalid_field", "2026-09-28", status="late"),
            case(
                "unmarked is the absence of a row", "invalid_field", "2026-10-05", status="unmarked"
            ),
            case("bad date", "validation_failed", "2026-02-30"),
            case("long note", "invalid_field", "2026-10-12", note="x" * 501),
        ],
    )
    fields = attendance_fields(phone, graph.slot, date="2026-11-02")
    (wrong,) = await phone.push_ok([phone.op("study_attendance", uuid7(), fields=fields)])
    assert wrong["code"] == "invalid_id"


async def test_debt_columns(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, **over: Any) -> Case:
        return (label, "study_debts", None, debt_fields(phone, graph.subject, **over), expected)

    await run_cases(
        phone,
        [
            case("lab", None),
            case("every kind", None, kind="coursework"),
            case(
                "full",
                None,
                kind="rgr",
                status="credited",
                due_date="2026-12-01",
                done_date="2026-11-20",
                note="n",
                task_id=str(uuid7()),
            ),
            case("unknown kind", "invalid_field", kind="essay"),
            case("unknown status", "invalid_field", status="done"),
            case("blank title", "validation_failed", title=" "),
            case("long title", "invalid_field", title="x" * 201),
            case("bad due date", "validation_failed", due_date="2026-02-30"),
            case("bad done date", "validation_failed", done_date="2026-13-01"),
            case("not a date", "invalid_field", due_date="20.12.2026"),
            case("task id is not a uuid", "invalid_field", task_id="t1"),
            (
                "missing parent",
                "study_debts",
                None,
                debt_fields(phone, uuid7()),
                "parent_not_found",
            ),
        ],
    )


async def test_attachment_columns(phone: DeviceClient, graph: Graph) -> None:
    def case(label: str, expected: str | None, data: bytes = JPEG, **over: Any) -> Case:
        subject = None if "debt_id" in over or "subject_id" in over else graph.subject
        return (
            label,
            "attachments",
            None,
            attachment_fields(phone, data, subject=subject, **over),
            expected,
        )

    pdf = {"file_name": "task.pdf", "mime_type": "application/pdf"}
    await run_cases(
        phone,
        [
            case("a photo of a subject", None),
            case("a pdf of a debt", None, PDF, debt_id=str(graph.debt), **pdf),
            case("upper case extension", None, file_name="IMG_1.JPG"),
            case("jpeg extension", None, file_name="img.jpeg"),
            case("heic", None, file_name="img.heic", mime_type="image/heic"),
            case("heif mime", None, file_name="img.heif", mime_type="image/heif"),
            case("a name with spaces and cyrillic", None, file_name="Задание №3 (вариант 2).jpg"),
            case("no owner", "validation_failed", subject_id=None, debt_id=None),
            case(
                "two owners",
                "validation_failed",
                subject_id=str(graph.subject),
                debt_id=str(graph.debt),
            ),
            case("extension does not fit the type", "validation_failed", file_name="x.png"),
            case("no extension", "validation_failed", file_name="photo"),
            case("path separator", "validation_failed", file_name="a/b.jpg"),
            case("backslash", "validation_failed", file_name="a\\b.jpg"),
            case("control character", "validation_failed", file_name="a\tb.jpg"),
            case("dot name", "validation_failed", file_name=".."),
            case("blank name", "validation_failed", file_name="   "),
            case("long name", "invalid_field", file_name="x" * 252 + ".jpg"),
            case(
                "exe is not allowed",
                "invalid_field",
                mime_type="application/x-msdownload",
                file_name="a.exe",
            ),
            case(
                "svg is not allowed", "invalid_field", mime_type="image/svg+xml", file_name="a.svg"
            ),
            case(
                "regex-lookalike mime",
                "invalid_field",
                mime_type="applicationXpdf",
                file_name="a.pdf",
            ),
            case("zero size", "invalid_field", size_bytes=0),
            case("25 MiB", None, size_bytes=25 * 1024 * 1024),
            case("over 25 MiB", "invalid_field", size_bytes=25 * 1024 * 1024 + 1),
            case("bad hash", "invalid_field", sha256="abc"),
            case("upper case hash", "invalid_field", sha256="A" * 64),
            case("unknown upload status", "invalid_field", upload_status="done"),
            case("uploaded status", None, upload_status="uploaded"),
            case("owner does not exist", "parent_not_found", subject_id=str(uuid7())),
        ],
    )
    for name, mime in (
        ("a.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ("a.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        ("a.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ("a.doc", "application/msword"),
        ("a.xls", "application/vnd.ms-excel"),
        ("a.ppt", "application/vnd.ms-powerpoint"),
        ("a.txt", "text/plain"),
        ("a.zip", "application/zip"),
        ("a.webp", "image/webp"),
        ("a.png", "image/png"),
    ):
        await run_cases(phone, [case(name, None, file_name=name, mime_type=mime)])


async def test_immutable_columns(phone: DeviceClient, graph: Graph) -> None:
    meta = file_meta(JPEG)
    attachment = uuid7()
    (made,) = await phone.push_ok(
        [
            phone.op(
                "attachments",
                attachment,
                fields=attachment_fields(phone, JPEG, subject=graph.subject),
            )
        ]
    )
    other = uuid7()
    edits: list[tuple[str, uuid.UUID, dict[str, Any]]] = [
        ("attachments", attachment, {"sha256": "0" * 64}),
        ("attachments", attachment, {"size_bytes": meta["size_bytes"] + 1}),
        ("attachments", attachment, {"mime_type": "image/png"}),
        ("attachments", attachment, {"subject_id": str(other)}),
        ("attachments", attachment, {"debt_id": str(graph.debt)}),
        ("study_subjects", graph.subject, {"semester_id": str(other)}),
        ("class_slots", graph.slot, {"semester_id": str(other)}),
        ("study_debts", graph.debt, {"subject_id": str(other)}),
    ]
    for table, row_id, fields in edits:
        (result,) = await phone.push_ok([phone.op(table, row_id, fields=fields, base=1)])
        assert result["code"] == "immutable_field", (table, fields)
    assert made["status"] == "applied"
    (renamed,) = await phone.push_ok(
        [
            phone.op(
                "attachments",
                attachment,
                fields={"file_name": "renamed.jpg", "upload_status": "uploaded"},
                base=1,
            )
        ]
    )
    assert renamed["status"] == "applied"
