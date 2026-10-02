"""The six seeded agent profiles, their default prompts, bootstrap and reset (spec stage3, 7)."""

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from tasker.ai import ids
from tasker.ai.serverwrite import WriteOp, load_changes, row_clock, write_rows
from tasker.ai.tables import ai_agent_profiles, ai_prompt_versions
from tasker.errors import ApiError
from tasker.sync.registry import SyncRegistry
from tasker.tables import app_meta

SEED_PROMPT_VERSION = 1
SEED_MARKER = "ai.seed.v1"
DEFAULT_TOOLS = ["get_tasks", "get_events", "create_task"]

_COMMON = (
    "Отвечай по-русски, кратко и по делу. Не выдумывай данные пользователя: если нужны задачи "
    "или события, запроси их инструментами. Дату в аргументах инструментов записывай в формате "
    "ГГГГ-ММ-ДД, относительные даты («завтра», «в следующий вторник») переводи, исходя из "
    "текущей даты. Задачу можно только предложить: пользователь сам одобрит её."
)


@dataclass(frozen=True, slots=True)
class SeedProfile:
    key: str
    name: str
    prompt: str
    position: int


SEED_PROFILES: tuple[SeedProfile, ...] = (
    SeedProfile(
        "general",
        "Общий",
        "Ты — личный помощник владельца приложения My Tasker. Помогай с планированием, "
        "задачами, календарём и повседневными вопросами. " + _COMMON,
        0,
    ),
    SeedProfile(
        "calendar_tasks",
        "Календарь и задачи",
        "Ты — планировщик дня и недели. Помогай разбирать входящие, расставлять приоритеты "
        "(P1 — самый высокий), раскладывать задачи по дням и находить свободные окна в "
        "расписании. Учитывай чётность недели из системной информации. " + _COMMON,
        1,
    ),
    SeedProfile(
        "work",
        "Работа",
        "Ты — помощник по рабочим проектам: сроки, доработки, заказчики, оплаты. Помогай "
        "формулировать задачи, оценивать объём и готовить сообщения заказчикам. " + _COMMON,
        2,
    ),
    SeedProfile(
        "finance",
        "Финансы",
        "Ты — помощник по личным финансам. Суммы указывай в рублях, считай аккуратно и "
        "показывай расчёт. Данные о счетах и операциях используй только из переданного "
        "контекста; ничего не угадывай. " + _COMMON,
        3,
    ),
    SeedProfile(
        "study",
        "Учёба",
        "Ты — помощник по учёбе: расписание пар, дедлайны, долги по предметам, подготовка к "
        "зачётам и экзаменам. Помогай составлять план подготовки и разбивать работы на шаги. "
        + _COMMON,
        4,
    ),
    SeedProfile(
        "sleep",
        "Сон",
        "Ты — помощник по режиму сна и энергии. Разбирай данные сна из контекста, замечай "
        "закономерности и предлагай небольшие реалистичные изменения режима. Не ставь "
        "медицинских диагнозов. " + _COMMON,
        5,
    ),
)
SEED_BY_KEY = {seed.key: seed for seed in SEED_PROFILES}


def _profile_fields(seed: SeedProfile, version: int) -> dict[str, Any]:
    return {
        "seed_key": seed.key,
        "name": seed.name,
        "topic": seed.key,
        "system_prompt": seed.prompt,
        "prompt_version": version,
        "enabled_tools": list(DEFAULT_TOOLS),
        "position": seed.position,
    }


async def _seeded(session: AsyncSession) -> bool:
    found = await session.execute(sa.select(app_meta.c.value).where(app_meta.c.key == SEED_MARKER))
    return found.first() is not None


async def ensure_seeded(session: AsyncSession, registry: SyncRegistry, now: datetime) -> None:
    """Create the six profiles (and their first prompt versions) once. Idempotent."""
    async with session.begin():
        seeded = await _seeded(session)
    if seeded:
        return
    ops: list[WriteOp] = []
    for seed in SEED_PROFILES:
        profile = ids.profile_id(seed.key)
        ops.append(WriteOp(ai_agent_profiles, profile, _profile_fields(seed, SEED_PROMPT_VERSION)))
        ops.append(
            WriteOp(
                ai_prompt_versions,
                ids.prompt_version_id(profile, SEED_PROMPT_VERSION),
                {
                    "profile_id": str(profile),
                    "version": SEED_PROMPT_VERSION,
                    "text": seed.prompt,
                    "source": "seed",
                },
            )
        )
    await write_rows(session, registry, ops, now)
    async with session.begin():
        await session.execute(
            pg_insert(app_meta)
            .values(key=SEED_MARKER, value="1")
            .on_conflict_do_nothing(index_elements=[app_meta.c.key])
        )


async def list_agents(session: AsyncSession) -> list[dict[str, str]]:
    table = ai_agent_profiles.table
    async with session.begin():
        rows = (
            await session.execute(
                sa.select(table.c.id, table.c.seed_key, table.c.name)
                .where(table.c.seed_key.is_not(None), table.c.deleted_at.is_(None))
                .order_by(table.c.position)
            )
        ).all()
    return [{"seed_key": row.seed_key, "id": str(row.id), "name": row.name} for row in rows]


async def reset_agent(
    session: AsyncSession, registry: SyncRegistry, now: datetime, seed_key: str
) -> list[dict[str, Any]]:
    """Restore the default prompt as a new version; returns the changed rows (``pull`` shape)."""
    seed = SEED_BY_KEY.get(seed_key)
    if seed is None:
        raise ApiError(404, "agent_not_found", "No such seeded agent")
    await ensure_seeded(session, registry, now)
    profile = ids.profile_id(seed.key)
    versions = ai_prompt_versions.table
    async with session.begin():
        current = (
            await session.execute(
                sa.select(ai_agent_profiles.table.c.prompt_version).where(
                    ai_agent_profiles.table.c.id == profile
                )
            )
        ).scalar_one_or_none()
        newest = (
            await session.execute(
                sa.select(sa.func.max(versions.c.version)).where(versions.c.profile_id == profile)
            )
        ).scalar_one()
        clock = await row_clock(session, ai_agent_profiles, profile)
    version = max(current or 0, newest or 0) + 1
    if clock is None:  # the tombstone was purged: recreate the profile
        profile_op = WriteOp(ai_agent_profiles, profile, _profile_fields(seed, version))
    else:
        profile_op = WriteOp(
            ai_agent_profiles,
            profile,
            {"system_prompt": seed.prompt, "prompt_version": version, "deleted_at": None},
            created=False,
            base_version=clock[0],
            after_hlc=clock[1],
        )
    version_op = WriteOp(
        ai_prompt_versions,
        ids.prompt_version_id(profile, version),
        {"profile_id": str(profile), "version": version, "text": seed.prompt, "source": "reset"},
    )
    await write_rows(session, registry, [profile_op, version_op], now)
    targets: list[tuple[Any, uuid.UUID]] = [
        (ai_agent_profiles, profile),
        (ai_prompt_versions, ids.prompt_version_id(profile, version)),
    ]
    async with session.begin():
        return await load_changes(session, targets)
