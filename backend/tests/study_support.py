"""Builders of valid Stage 7 rows and the seeded Study graph of the vectors' scenario."""

import hashlib
import uuid
from dataclasses import dataclass
from typing import Any

from tasker.ids import uuid7
from tasker.study.schema import bell_id, day_rule_id, slot_date_id
from tests.api_support import DeviceClient

JPEG = b"\xff\xd8\xff\xe0" + b"jpeg-body-" * 20
PNG = b"\x89PNG\r\n\x1a\n" + b"png-body-" * 20
PDF = b"%PDF-1.7\n" + b"pdf-body-" * 50 + b"\n%%EOF\n"
TEXT = "Конспект по матанализу\n".encode() * 5


def semester_fields(dc: DeviceClient, **over: Any) -> dict[str, Any]:
    return {
        "name": "Осень 2026",
        "start_date": "2026-09-01",
        "end_date": "2026-12-31",
        "week1_start": "2026-08-31",
        "cycle_length": 2,
        "archived": False,
        "created_at": dc.created(),
        **over,
    }


def subject_fields(dc: DeviceClient, semester: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "semester_id": str(semester),
        "name": "Математический анализ",
        "archived": False,
        "created_at": dc.created(),
        **over,
    }


def bell_fields(dc: DeviceClient, semester: uuid.UUID, number: int, **over: Any) -> dict[str, Any]:
    return {
        "semester_id": str(semester),
        "number": number,
        "start_time": "08:30",
        "end_time": "10:00",
        "created_at": dc.created(),
        **over,
    }


def bell_row_id(fields: dict[str, Any]) -> uuid.UUID:
    return bell_id(fields["semester_id"], fields.get("on_date"), fields["number"])


def slot_fields(dc: DeviceClient, semester: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "semester_id": str(semester),
        "title": "Пара",
        "weekday": 1,
        "number": 1,
        "kind": "lecture",
        "created_at": dc.created(),
        **over,
    }


def rule_fields(dc: DeviceClient, semester: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "semester_id": str(semester),
        "weekday": 4,
        "title": "Подготовка к олимпиаде",
        "hide_regular": True,
        "items": [{"key": "o1", "number": 1, "title": "Подготовка к олимпиаде", "kind": "other"}],
        "created_at": dc.created(),
        **over,
    }


def rule_row_id(fields: dict[str, Any]) -> uuid.UUID:
    return day_rule_id(
        fields["semester_id"],
        fields.get("weekday"),
        fields.get("on_date"),
        fields.get("cycle_week"),
    )


def override_fields(dc: DeviceClient, slot: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "slot_id": str(slot),
        "date": "2026-09-07",
        "action": "cancel",
        "created_at": dc.created(),
        **over,
    }


def override_row_id(fields: dict[str, Any]) -> uuid.UUID:
    return slot_date_id("class_overrides", fields["slot_id"], fields["date"])


def attendance_fields(dc: DeviceClient, slot: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "slot_id": str(slot),
        "date": "2026-09-07",
        "status": "absent",
        "created_at": dc.created(),
        **over,
    }


def attendance_row_id(fields: dict[str, Any]) -> uuid.UUID:
    return slot_date_id("study_attendance", fields["slot_id"], fields["date"])


def debt_fields(dc: DeviceClient, subject: uuid.UUID, **over: Any) -> dict[str, Any]:
    return {
        "subject_id": str(subject),
        "kind": "lab",
        "title": "ЛР 3",
        "status": "open",
        "created_at": dc.created(),
        **over,
    }


def file_meta(data: bytes, **over: Any) -> dict[str, Any]:
    return {
        "file_name": "photo.jpg",
        "mime_type": "image/jpeg",
        "size_bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "upload_status": "pending",
        **over,
    }


def attachment_fields(
    dc: DeviceClient,
    data: bytes = JPEG,
    *,
    subject: uuid.UUID | None = None,
    debt: uuid.UUID | None = None,
    **over: Any,
) -> dict[str, Any]:
    owner: dict[str, Any] = {}
    if subject is not None:
        owner["subject_id"] = str(subject)
    if debt is not None:
        owner["debt_id"] = str(debt)
    return {**owner, **file_meta(data), "created_at": dc.created(), **over}


@dataclass
class StudySeed:
    semester: uuid.UUID
    math: uuid.UUID
    phys: uuid.UUID
    mon1: uuid.UUID  # Monday pair 1, math lecture, every week
    mon2: uuid.UUID  # Monday pair 2, physics lab, odd weeks
    thu1: uuid.UUID  # Thursday pair 1 (hidden by the olympiad rule)
    rule: uuid.UUID
    debt_lab: uuid.UUID
    debt_exam: uuid.UUID


def study_seed_ops(dc: DeviceClient) -> tuple[StudySeed, list[dict[str, Any]]]:
    s = StudySeed(*(uuid7() for _ in range(9)))
    rule = rule_fields(dc, s.semester)
    s.rule = rule_row_id(rule)
    ops = [
        dc.op("study_semesters", s.semester, fields=semester_fields(dc)),
        dc.op(
            "study_subjects",
            s.math,
            fields=subject_fields(
                dc, s.semester, teacher="Иванов И. И.", building="1", room="28", absence_limit=4
            ),
        ),
        dc.op(
            "study_subjects",
            s.phys,
            fields=subject_fields(
                dc, s.semester, name="Физика", building="2", room="101", absence_limit=3
            ),
        ),
    ]
    for number, start, end in (
        (1, "08:30", "10:00"),
        (2, "10:10", "11:40"),
        (3, "12:10", "13:40"),
    ):
        fields = bell_fields(dc, s.semester, number, start_time=start, end_time=end)
        ops.append(dc.op("study_bells", bell_row_id(fields), fields=fields))
    ops += [
        dc.op(
            "class_slots",
            s.mon1,
            fields=slot_fields(dc, s.semester, subject_id=str(s.math), title=None),
        ),
        dc.op(
            "class_slots",
            s.mon2,
            fields=slot_fields(
                dc,
                s.semester,
                subject_id=str(s.phys),
                title=None,
                number=2,
                kind="lab",
                cycle_week=1,
            ),
        ),
        dc.op(
            "class_slots",
            s.thu1,
            fields=slot_fields(dc, s.semester, subject_id=str(s.math), title=None, weekday=4),
        ),
        dc.op("study_day_rules", s.rule, fields=rule),
        dc.op(
            "study_debts",
            s.debt_lab,
            fields=debt_fields(dc, s.math, title="ЛР 3", due_date="2026-09-20", note="Графики"),
        ),
        dc.op(
            "study_debts",
            s.debt_exam,
            fields=debt_fields(dc, s.phys, kind="exam", title="Экзамен", status="submitted"),
        ),
    ]
    return s, ops


async def study_seed(dc: DeviceClient) -> StudySeed:
    seed, ops = study_seed_ops(dc)
    results = await dc.push_ok(ops)
    assert [r["status"] for r in results] == ["applied"] * len(ops), results
    return seed
