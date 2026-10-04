"""Synchronised tables of Stage 7 (spec stage7_study.md, sections 1 and 2).

Cascades: semester -> subjects, bells, slots, day rules; subject -> slots, debts, attachments;
slot -> overrides, attendance; debt -> attachments. Links to overridden subjects and to tasks are
soft (plain uuid columns).
"""

from tasker.study.schema import (
    ATTACHMENT_COLUMNS,
    ATTENDANCE_COLUMNS,
    BELL_COLUMNS,
    DAY_RULE_COLUMNS,
    DEBT_COLUMNS,
    OVERRIDE_COLUMNS,
    SEMESTER_COLUMNS,
    SLOT_COLUMNS,
    SUBJECT_COLUMNS,
    attachment_problem,
    attendance_id_rule,
    attendance_problem,
    bell_id_rule,
    bell_problem,
    day_rule_id_rule,
    day_rule_problem,
    debt_problem,
    override_id_rule,
    override_problem,
    semester_problem,
    slot_problem,
    subject_problem,
)
from tasker.sync.registry import SyncTableSpec, define_sync_table
from tasker.tables import metadata

study_semesters: SyncTableSpec = define_sync_table(
    metadata, "study_semesters", SEMESTER_COLUMNS, validators=(semester_problem,)
)
study_subjects: SyncTableSpec = define_sync_table(
    metadata, "study_subjects", SUBJECT_COLUMNS, validators=(subject_problem,)
)
study_bells: SyncTableSpec = define_sync_table(
    metadata,
    "study_bells",
    BELL_COLUMNS,
    id_rule=bell_id_rule,
    validators=(bell_problem,),
)
class_slots: SyncTableSpec = define_sync_table(
    metadata, "class_slots", SLOT_COLUMNS, validators=(slot_problem,)
)
study_day_rules: SyncTableSpec = define_sync_table(
    metadata,
    "study_day_rules",
    DAY_RULE_COLUMNS,
    id_rule=day_rule_id_rule,
    validators=(day_rule_problem,),
)
class_overrides: SyncTableSpec = define_sync_table(
    metadata,
    "class_overrides",
    OVERRIDE_COLUMNS,
    id_rule=override_id_rule,
    validators=(override_problem,),
)
study_attendance: SyncTableSpec = define_sync_table(
    metadata,
    "study_attendance",
    ATTENDANCE_COLUMNS,
    id_rule=attendance_id_rule,
    validators=(attendance_problem,),
)
study_debts: SyncTableSpec = define_sync_table(
    metadata, "study_debts", DEBT_COLUMNS, validators=(debt_problem,)
)
attachments: SyncTableSpec = define_sync_table(
    metadata, "attachments", ATTACHMENT_COLUMNS, validators=(attachment_problem,)
)

# Parents first.
STUDY_TABLES: tuple[SyncTableSpec, ...] = (
    study_semesters,
    study_subjects,
    study_bells,
    class_slots,
    study_day_rules,
    class_overrides,
    study_attendance,
    study_debts,
    attachments,
)
