import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';
import 'package:my_tasker/core/db/migration_steps.dart';
import 'package:my_tasker/core/db/sync_tables.dart';
import 'package:my_tasker/features/ai_chat/data/ai_tables.dart';
import 'package:my_tasker/features/banks/data/banks_tables.dart';
import 'package:my_tasker/features/finance/data/finance_tables.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_tables.dart';
import 'package:my_tasker/features/sleep/data/sleep_tables.dart';
import 'package:my_tasker/features/study/data/study_tables.dart';
import 'package:my_tasker/features/work/data/work_tables.dart';

part 'app_database.g.dart';

/// Локальные настройки устройства (ключ-значение): адрес сервера,
/// отпечаток сертификата и т. п. Не синхронизируется с сервером.
// DSL-описание таблицы исполняется только генератором кода (drift_dev).
// coverage:ignore-start
class LocalSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}
// coverage:ignore-end

/// Локальная БД приложения (Drift).
///
/// * v1 — `local_settings`;
/// * v2 — синхронизация: `sync_outbox`, `sync_meta`, `user_settings`;
/// * v3 — Этап 2 (календарь и задачи): `calendars`, `events`,
///   `event_overrides`, `projects`, `people`, `tags`, `tasks`, `subtasks`,
///   `task_tags`, `task_completions` (`calendar_tables.dart`).
///
/// * v4 — Этап 3 (ИИ-чат): `ai_agent_profiles`, `ai_prompt_versions`,
///   `ai_context_presets`, `ai_model_favorites`, `ai_conversations`,
///   `ai_messages`, `ai_tool_proposals` (`features/ai_chat/data/ai_tables.dart`).
/// * v5 — Этап 4 (Работа): `projects` и `people` получают необязательные
///   колонки (`ALTER TABLE ADD COLUMN`), новые таблицы `change_requests`,
///   `payments`, `payment_allocations`, `time_entries`
///   (`features/work/data/work_tables.dart`).
/// * v6 — Этап 5 (Финансы): `accounts`, `categories`, `transactions`,
///   `balance_checkpoints`, `debts`, `debt_repayments`, `goals`
///   (`features/finance/data/finance_tables.dart`).
/// * v7 — Этап 6 (Банки): синхронизируемая `merchant_category_rules` и
///   локальная (не синхронизируется) `bank_notifications` — сырые
///   уведомления на 30 дней (`features/banks/data/banks_tables.dart`).
/// * v8 — Этап 7 (Учёба): `study_semesters`, `study_subjects`,
///   `study_bells`, `class_slots`, `study_day_rules`, `class_overrides`,
///   `study_attendance`, `study_debts`, `attachments`
///   (`features/study/data/study_tables.dart`).
/// * v9 — Этап 8 (Сон и ритуалы): `sleep_entries`, `daily_plans`,
///   `evening_checkins` (`features/sleep/data/sleep_tables.dart`).
/// * v10 — Этап 9 (Серверы): `monitor_servers`, `monitor_services`,
///   `monitor_checks` (`features/monitoring/data/monitoring_tables.dart`).
///
/// Правила миграций: любое изменение схемы = `schemaVersion + 1` и новый шаг
/// в [migrationSteps]; шаги применяются последовательно. Откат версии
/// приложения (схема БД новее кода) Drift тоже передаёт в `onUpgrade`
/// (`from > to`) — [runMigrationSteps] отвечает на него ошибкой.
@DriftDatabase(
  tables: [
    LocalSettings,
    SyncOutbox,
    SyncMeta,
    UserSettings,
    Calendars,
    Events,
    EventOverrides,
    Projects,
    People,
    Tags,
    Tasks,
    Subtasks,
    TaskTags,
    TaskCompletions,
    AiAgentProfiles,
    AiPromptVersions,
    AiContextPresets,
    AiModelFavorites,
    AiConversations,
    AiMessages,
    AiToolProposals,
    ChangeRequests,
    Payments,
    PaymentAllocations,
    TimeEntries,
    Accounts,
    Categories,
    FinTransactions,
    BalanceCheckpoints,
    Debts,
    DebtRepayments,
    Goals,
    MerchantCategoryRules,
    BankNotifications,
    StudySemesters,
    StudySubjects,
    StudyBells,
    ClassSlots,
    StudyDayRules,
    ClassOverrides,
    StudyAttendance,
    StudyDebts,
    Attachments,
    SleepEntries,
    DailyPlans,
    EveningCheckins,
    MonitorServers,
    MonitorServices,
    MonitorChecks,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Текущая версия схемы (то же значение, что и [schemaVersion]).
  static const int currentSchemaVersion = 10;

  @override
  int get schemaVersion => currentSchemaVersion;

  /// Шаги миграции по целевой версии. Шага для v1 нет: её создаёт `onCreate`.
  static final Map<int, MigrationStep> migrationSteps = {
    2: (m) async {
      final db = m.database as AppDatabase;
      await m.createTable(db.syncOutbox);
      await m.createTable(db.syncMeta);
      await m.createTable(db.userSettings);
    },
    3: (m) async {
      final db = m.database as AppDatabase;
      await m.createTable(db.calendars);
      await m.createTable(db.events);
      await m.createTable(db.eventOverrides);
      await m.createTable(db.projects);
      await m.createTable(db.people);
      await m.createTable(db.tags);
      await m.createTable(db.tasks);
      await m.createTable(db.subtasks);
      await m.createTable(db.taskTags);
      await m.createTable(db.taskCompletions);
      await m.createIndex(db.eventsCalendarIdx);
      await m.createIndex(db.eventOverridesEventIdx);
      await m.createIndex(db.tasksDueDateIdx);
      await m.createIndex(db.tasksDueAtIdx);
      await m.createIndex(db.subtasksTaskIdx);
      await m.createIndex(db.taskTagsTaskIdx);
      await m.createIndex(db.taskCompletionsTaskIdx);
    },
    4: (m) async {
      final db = m.database as AppDatabase;
      await m.createTable(db.aiAgentProfiles);
      await m.createTable(db.aiPromptVersions);
      await m.createTable(db.aiContextPresets);
      await m.createTable(db.aiModelFavorites);
      await m.createTable(db.aiConversations);
      await m.createTable(db.aiMessages);
      await m.createTable(db.aiToolProposals);
      await m.createIndex(db.aiPromptVersionsProfileIdx);
      await m.createIndex(db.aiMessagesConversationIdx);
      await m.createIndex(db.aiToolProposalsMessageIdx);
    },
    5: (m) async {
      final db = m.database as AppDatabase;
      // Расширение таблиц Этапа 2: все колонки необязательные, строки
      // и id остаются как были. Если таблицы создал шаг 3 этой же цепочки
      // (обновление с v2), колонки в них уже есть.
      await addColumnIfMissing(m, db.projects, db.projects.clientId);
      await addColumnIfMissing(m, db.projects, db.projects.status);
      await addColumnIfMissing(m, db.projects, db.projects.payType);
      await addColumnIfMissing(m, db.projects, db.projects.baseAmount);
      await addColumnIfMissing(m, db.projects, db.projects.hourlyRate);
      await addColumnIfMissing(m, db.projects, db.projects.startDate);
      await addColumnIfMissing(m, db.projects, db.projects.deadlineDate);
      await addColumnIfMissing(m, db.projects, db.projects.completedDate);
      await addColumnIfMissing(m, db.projects, db.projects.description);
      await addColumnIfMissing(m, db.projects, db.projects.links);
      await addColumnIfMissing(m, db.people, db.people.role);
      await addColumnIfMissing(m, db.people, db.people.contact);
      await m.createTable(db.changeRequests);
      await m.createTable(db.payments);
      await m.createTable(db.paymentAllocations);
      await m.createTable(db.timeEntries);
      await m.createIndex(db.changeRequestsProjectIdx);
      await m.createIndex(db.paymentsPaidAtIdx);
      await m.createIndex(db.paymentAllocationsPaymentIdx);
      await m.createIndex(db.paymentAllocationsProjectIdx);
      await m.createIndex(db.timeEntriesProjectIdx);
      await m.createIndex(db.timeEntriesStartedIdx);
    },
    6: (m) async {
      final db = m.database as AppDatabase;
      await m.createTable(db.accounts);
      await m.createTable(db.categories);
      await m.createTable(db.finTransactions);
      await m.createTable(db.balanceCheckpoints);
      await m.createTable(db.debts);
      await m.createTable(db.debtRepayments);
      await m.createTable(db.goals);
      await m.createIndex(db.transactionsAccountIdx);
      await m.createIndex(db.transactionsOccurredIdx);
      await m.createIndex(db.balanceCheckpointsAccountIdx);
      await m.createIndex(db.debtRepaymentsDebtIdx);
    },
    7: (m) async {
      final db = m.database as AppDatabase;
      await m.createTable(db.merchantCategoryRules);
      await m.createTable(db.bankNotifications);
      await m.createIndex(db.bankNotificationsReceivedIdx);
      await m.createIndex(db.bankNotificationsStateIdx);
    },
    8: (m) async {
      final db = m.database as AppDatabase;
      await m.createTable(db.studySemesters);
      await m.createTable(db.studySubjects);
      await m.createTable(db.studyBells);
      await m.createTable(db.classSlots);
      await m.createTable(db.studyDayRules);
      await m.createTable(db.classOverrides);
      await m.createTable(db.studyAttendance);
      await m.createTable(db.studyDebts);
      await m.createTable(db.attachments);
      await m.createIndex(db.studySubjectsSemesterIdx);
      await m.createIndex(db.studyBellsSemesterIdx);
      await m.createIndex(db.classSlotsSemesterIdx);
      await m.createIndex(db.classSlotsSubjectIdx);
      await m.createIndex(db.studyDayRulesSemesterIdx);
      await m.createIndex(db.classOverridesSlotIdx);
      await m.createIndex(db.studyAttendanceSlotIdx);
      await m.createIndex(db.studyDebtsSubjectIdx);
      await m.createIndex(db.attachmentsSubjectIdx);
      await m.createIndex(db.attachmentsDebtIdx);
    },
    9: (m) async {
      final db = m.database as AppDatabase;
      await m.createTable(db.sleepEntries);
      await m.createTable(db.dailyPlans);
      await m.createTable(db.eveningCheckins);
      await m.createIndex(db.sleepEntriesDateIdx);
      await m.createIndex(db.dailyPlansDateIdx);
      await m.createIndex(db.eveningCheckinsDateIdx);
    },
    10: (m) async {
      final db = m.database as AppDatabase;
      await m.createTable(db.monitorServers);
      await m.createTable(db.monitorServices);
      await m.createTable(db.monitorChecks);
      await m.createIndex(db.monitorServicesServerIdx);
      await m.createIndex(db.monitorChecksServiceIdx);
    },
  };

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) => runMigrationSteps(m, from, to, migrationSteps),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // Поиск операций строки (`collapse`, корзина, purge) по
      // `(target_table, row_id)`. Идемпотентно и без шага миграции: набор
      // шагов принадлежит модулям Этапа 2.
      await customStatement(
        'CREATE INDEX IF NOT EXISTS sync_outbox_target_row_idx '
        'ON sync_outbox (target_table, row_id)',
      );
    },
  );
}
