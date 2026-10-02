"""Which modules synchronise which tables. Later stages add their registrations here."""

from tasker.ai.tables import AI_TABLES
from tasker.calendar.tables import CALENDAR_TABLES
from tasker.sync.registry import SyncRegistry
from tasker.sync.user_settings import user_settings


def build_registry() -> SyncRegistry:
    registry = SyncRegistry()
    registry.register(user_settings)
    for spec in CALENDAR_TABLES:
        registry.register(spec)
    for spec in AI_TABLES:
        registry.register(spec)
    return registry
