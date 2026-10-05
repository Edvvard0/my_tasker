"""Server-only tables of Stage 9 (not synchronised; clients read them through the API).

``monitor_results`` is the raw series of the engine (kept 48 hours), ``monitor_rollups`` the
hourly totals behind "availability %" (kept 180 days), ``monitor_state`` the alert state of a
service, ``monitor_incidents`` the incident journal, ``monitor_outbox`` the queue of Telegram
messages (unique ``dedup_key``: the same message is never queued twice).
"""

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, TIMESTAMP, UUID

from tasker.tables import metadata

monitor_results = sa.Table(
    "monitor_results",
    metadata,
    sa.Column("check_id", UUID(as_uuid=True), nullable=False),
    sa.Column("at", TIMESTAMP(timezone=True), nullable=False),
    sa.Column("ok", sa.Boolean, nullable=False),
    sa.Column("duration_ms", sa.BigInteger),
    sa.Column("error", sa.Text),
    sa.PrimaryKeyConstraint("check_id", "at"),
)
sa.Index("ix_monitor_results_at", monitor_results.c.at)

monitor_rollups = sa.Table(
    "monitor_rollups",
    metadata,
    sa.Column("check_id", UUID(as_uuid=True), nullable=False),
    sa.Column("hour_start", TIMESTAMP(timezone=True), nullable=False),
    sa.Column("total", sa.BigInteger, nullable=False),
    sa.Column("ok", sa.BigInteger, nullable=False),
    sa.Column("ms_sum", sa.BigInteger, nullable=False),
    sa.Column("ms_count", sa.BigInteger, nullable=False),
    sa.PrimaryKeyConstraint("check_id", "hour_start"),
)
sa.Index("ix_monitor_rollups_hour_start", monitor_rollups.c.hour_start)

monitor_state = sa.Table(
    "monitor_state",
    metadata,
    sa.Column("service_id", UUID(as_uuid=True), primary_key=True),
    sa.Column("state", JSONB, nullable=False),
    sa.Column("updated_at", TIMESTAMP(timezone=True), nullable=False),
)

monitor_incidents = sa.Table(
    "monitor_incidents",
    metadata,
    sa.Column("id", UUID(as_uuid=True), primary_key=True),
    sa.Column("service_id", UUID(as_uuid=True), nullable=False),
    sa.Column("n", sa.BigInteger, nullable=False),
    sa.Column("started_at", TIMESTAMP(timezone=True), nullable=False),
    sa.Column("ended_at", TIMESTAMP(timezone=True)),
    sa.Column("reason", sa.Text),
    sa.Column("check_ids", JSONB, nullable=False),
    sa.UniqueConstraint("service_id", "n", name="uq_monitor_incidents_service_n"),
)
sa.Index("ix_monitor_incidents_started_at", monitor_incidents.c.started_at)

monitor_outbox = sa.Table(
    "monitor_outbox",
    metadata,
    sa.Column("id", sa.BigInteger, sa.Identity(always=True), primary_key=True),
    sa.Column("dedup_key", sa.Text, nullable=False),
    sa.Column("kind", sa.Text, nullable=False),
    sa.Column("text", sa.Text, nullable=False),
    sa.Column("created_at", TIMESTAMP(timezone=True), nullable=False),
    sa.Column("expires_at", TIMESTAMP(timezone=True), nullable=False),
    sa.Column("next_attempt_at", TIMESTAMP(timezone=True), nullable=False),
    sa.Column("attempts", sa.BigInteger, nullable=False, server_default="0"),
    sa.Column("sent_at", TIMESTAMP(timezone=True)),
    sa.Column("last_error", sa.Text),
    sa.UniqueConstraint("dedup_key", name="uq_monitor_outbox_dedup_key"),
)
sa.Index("ix_monitor_outbox_due", monitor_outbox.c.sent_at, monitor_outbox.c.next_attempt_at)
