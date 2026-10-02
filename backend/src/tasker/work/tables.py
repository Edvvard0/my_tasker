"""New synchronised tables of Stage 4. ``projects`` and ``people`` are extended in place
(``tasker.calendar.tables``) with the columns of ``tasker.work.schema``.

Cascades (spec stage4_work.md, 2): project -> change_requests, payment_allocations, time_entries;
payment -> payment_allocations. Everything else links softly (plain uuid columns).
"""

from tasker.sync.registry import SyncTableSpec, define_sync_table
from tasker.tables import metadata
from tasker.work.schema import (
    ALLOCATION_COLUMNS,
    CHANGE_REQUEST_COLUMNS,
    PAYMENT_COLUMNS,
    TIME_ENTRY_COLUMNS,
    change_request_problem,
    payment_problem,
    time_entry_problem,
)

change_requests: SyncTableSpec = define_sync_table(
    metadata,
    "change_requests",
    CHANGE_REQUEST_COLUMNS,
    validators=(change_request_problem,),
)

payments: SyncTableSpec = define_sync_table(
    metadata, "payments", PAYMENT_COLUMNS, validators=(payment_problem,)
)

payment_allocations: SyncTableSpec = define_sync_table(
    metadata, "payment_allocations", ALLOCATION_COLUMNS
)

time_entries: SyncTableSpec = define_sync_table(
    metadata, "time_entries", TIME_ENTRY_COLUMNS, validators=(time_entry_problem,)
)

# Parents first (``projects`` is registered by the calendar module before these).
WORK_TABLES: tuple[SyncTableSpec, ...] = (
    change_requests,
    payments,
    payment_allocations,
    time_entries,
)
