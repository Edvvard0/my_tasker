"""stage 1 hardening: server epoch, refresh grace, index names and tombstone index

* ``app_meta.server_epoch``: random id of this database's history (spec 3.10).
* ``devices.prev_refresh_token_hash`` / ``prev_rotated_at``: the 60 s refresh grace (spec 1.3).
* ``user_settings``: index name follows the metadata convention, plus the partial tombstone
  index used by the purge job. New synchronised tables get both from ``define_sync_table``.

Revision ID: 0006
Revises: 0005
Create Date: 2026-09-30
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("devices", sa.Column("prev_refresh_token_hash", sa.Text()))
    op.add_column("devices", sa.Column("prev_rotated_at", sa.DateTime(timezone=True)))
    op.execute(
        "INSERT INTO app_meta (key, value) VALUES ('server_epoch', gen_random_uuid()::text)"
        " ON CONFLICT (key) DO NOTHING"
    )
    op.execute(
        "ALTER INDEX IF EXISTS user_settings_server_version"
        " RENAME TO ix_user_settings_server_version"
    )
    op.create_index(
        "user_settings_tombstones",
        "user_settings",
        ["deleted_at"],
        postgresql_where=sa.text("deleted_at IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("user_settings_tombstones", table_name="user_settings")
    op.execute(
        "ALTER INDEX IF EXISTS ix_user_settings_server_version"
        " RENAME TO user_settings_server_version"
    )
    op.execute("DELETE FROM app_meta WHERE key IN ('server_epoch', 'db_fingerprint')")
    op.drop_column("devices", "prev_rotated_at")
    op.drop_column("devices", "prev_refresh_token_hash")
