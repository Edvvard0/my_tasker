"""Fixed and deterministic identifiers of the AI tables (spec stage3, 1)."""

import uuid

from tasker.calendar.ids import namespace

# The virtual device that authors server-written rows (messages, proposals, seeded profiles).
# Not a row of ``devices``: it has no tokens, no cursor and never delays the tombstone purge.
SERVER_DEVICE_ID = uuid.UUID("00000000-0000-7000-8000-000000000a11")


def profile_id(seed_key: str) -> uuid.UUID:
    return uuid.uuid5(namespace("ai_agent_profiles"), seed_key)


def prompt_version_id(profile: uuid.UUID | str, version: int) -> uuid.UUID:
    return uuid.uuid5(namespace("ai_prompt_versions"), f"{profile}|{version}")


def favorite_id(model_id: str) -> uuid.UUID:
    return uuid.uuid5(namespace("ai_model_favorites"), model_id)
