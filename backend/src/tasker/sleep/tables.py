"""Synchronised tables of Stage 8: sleep and the two daily rituals (spec stage8_sleep_rituals.md).

One row per date in every table (deterministic ids). Links to tasks are soft (plain uuids inside
json lists or in a plain column): the tables have no parents, so no cascades.
"""

from tasker.sleep.schema import (
    CHECKIN_COLUMNS,
    PLAN_COLUMNS,
    SLEEP_COLUMNS,
    checkin_id_rule,
    checkin_problem,
    daily_plan_id_rule,
    plan_problem,
    sleep_entry_id_rule,
    sleep_problem,
)
from tasker.sync.registry import SyncTableSpec, define_sync_table
from tasker.tables import metadata

sleep_entries: SyncTableSpec = define_sync_table(
    metadata,
    "sleep_entries",
    SLEEP_COLUMNS,
    id_rule=sleep_entry_id_rule,
    validators=(sleep_problem,),
)
daily_plans: SyncTableSpec = define_sync_table(
    metadata,
    "daily_plans",
    PLAN_COLUMNS,
    id_rule=daily_plan_id_rule,
    validators=(plan_problem,),
)
evening_checkins: SyncTableSpec = define_sync_table(
    metadata,
    "evening_checkins",
    CHECKIN_COLUMNS,
    id_rule=checkin_id_rule,
    validators=(checkin_problem,),
)

SLEEP_TABLES: tuple[SyncTableSpec, ...] = (sleep_entries, daily_plans, evening_checkins)
