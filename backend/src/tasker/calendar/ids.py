"""Deterministic row ids: two devices creating the same logical row offline yield one row.

Spec: ``docs/specs/stage2_calendar_tasks.md`` section 2.2 (vectors: ``calendar/ids.json``).
"""

import uuid


def namespace(table: str) -> uuid.UUID:
    return uuid.uuid5(uuid.NAMESPACE_URL, f"urn:my-tasker:{table}")


def system_calendar_id(system_key: str) -> uuid.UUID:
    return uuid.uuid5(namespace("calendars"), system_key)


def tag_id(name: str) -> uuid.UUID:
    return uuid.uuid5(namespace("tags"), name.lower())


def override_id(event_id: uuid.UUID | str, original_start: str) -> uuid.UUID:
    return uuid.uuid5(namespace("event_overrides"), f"{event_id}|{original_start}")


def completion_id(task_id: uuid.UUID | str, instance_date: str) -> uuid.UUID:
    return uuid.uuid5(namespace("task_completions"), f"{task_id}|{instance_date}")


def task_tag_id(task_id: uuid.UUID | str, tag: uuid.UUID | str) -> uuid.UUID:
    return uuid.uuid5(namespace("task_tags"), f"{task_id}|{tag}")
