"""Which modules synchronise which tables. Later stages add their registrations here."""

from tasker.ai.tables import AI_TABLES
from tasker.banks.tables import BANKS_TABLES
from tasker.calendar.tables import CALENDAR_TABLES
from tasker.finance.tables import FINANCE_TABLES
from tasker.monitoring.tables import MONITORING_TABLES
from tasker.sleep.tables import SLEEP_TABLES
from tasker.study.tables import STUDY_TABLES
from tasker.sync.registry import SyncRegistry
from tasker.sync.user_settings import user_settings
from tasker.work.tables import WORK_TABLES


def build_registry() -> SyncRegistry:
    registry = SyncRegistry()
    registry.register(user_settings)
    for spec in CALENDAR_TABLES:
        registry.register(spec)
    for spec in WORK_TABLES:
        registry.register(spec)
    for spec in FINANCE_TABLES:
        registry.register(spec)
    for spec in BANKS_TABLES:
        registry.register(spec)
    for spec in STUDY_TABLES:
        registry.register(spec)
    for spec in SLEEP_TABLES:
        registry.register(spec)
    for spec in MONITORING_TABLES:
        registry.register(spec)
    for spec in AI_TABLES:
        registry.register(spec)
    return registry
