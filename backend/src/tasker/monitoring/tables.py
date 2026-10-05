"""Synchronised tables of Stage 9 (spec stage9_monitoring.md, section 2).

Cascades: server -> services -> checks. ``monitor_services.work_project_id`` links softly to a
Work project (a plain uuid, no foreign key).
"""

from tasker.monitoring import (
    storage,  # noqa: F401  (declares the server-only tables on the metadata)
)
from tasker.monitoring.schema import (
    CHECK_COLUMNS,
    SERVER_COLUMNS,
    SERVICE_COLUMNS,
    check_problem,
    server_problem,
    service_problem,
)
from tasker.sync.registry import SyncTableSpec, define_sync_table
from tasker.tables import metadata

monitor_servers: SyncTableSpec = define_sync_table(
    metadata, "monitor_servers", SERVER_COLUMNS, validators=(server_problem,)
)
monitor_services: SyncTableSpec = define_sync_table(
    metadata, "monitor_services", SERVICE_COLUMNS, validators=(service_problem,)
)
monitor_checks: SyncTableSpec = define_sync_table(
    metadata, "monitor_checks", CHECK_COLUMNS, validators=(check_problem,)
)

# Parents first.
MONITORING_TABLES: tuple[SyncTableSpec, ...] = (monitor_servers, monitor_services, monitor_checks)
