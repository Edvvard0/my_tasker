"""Which modules synchronise which tables. Later stages add their registrations here."""

from tasker.sync.registry import SyncRegistry
from tasker.sync.user_settings import user_settings


def build_registry() -> SyncRegistry:
    registry = SyncRegistry()
    registry.register(user_settings)
    return registry
