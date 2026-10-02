import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';
import 'package:my_tasker/core/db/migration_steps.dart';
import 'package:my_tasker/core/db/sync_tables.dart';
import 'package:my_tasker/features/ai_chat/data/ai_tables.dart';

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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Текущая версия схемы (то же значение, что и [schemaVersion]).
  static const int currentSchemaVersion = 4;

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
