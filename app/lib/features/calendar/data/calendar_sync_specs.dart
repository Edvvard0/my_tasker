import 'package:my_tasker/core/sync/sync_table.dart';

/// Синхронизируемые таблицы календаря (spec Этапа 2, раздел 3).
/// Порядок регистрации — родители вперёд.

/// `calendars` — слои (spec 3.1).
const SyncTableSpec calendarsSpec = SyncTableSpec(
  name: 'calendars',
  label: 'Календарь',
  columns: [
    SyncColumn('name', SyncColumnType.text),
    SyncColumn('color', SyncColumnType.text, nullable: true),
    SyncColumn('kind', SyncColumnType.text),
    SyncColumn(
      'system_key',
      SyncColumnType.text,
      nullable: true,
      immutable: true,
    ),
    SyncColumn('visible', SyncColumnType.boolean),
    SyncColumn('position', SyncColumnType.integer),
  ],
  titleOf: _calendarTitle,
);

/// `events` — события (spec 3.2).
const SyncTableSpec eventsSpec = SyncTableSpec(
  name: 'events',
  label: 'Событие',
  columns: [
    SyncColumn('calendar_id', SyncColumnType.uuid),
    SyncColumn('title', SyncColumnType.text),
    SyncColumn('description', SyncColumnType.text, nullable: true),
    SyncColumn('location', SyncColumnType.text, nullable: true),
    SyncColumn('all_day', SyncColumnType.boolean),
    SyncColumn('start_at', SyncColumnType.datetime, nullable: true),
    SyncColumn('end_at', SyncColumnType.datetime, nullable: true),
    SyncColumn('tz', SyncColumnType.text, nullable: true),
    SyncColumn('start_date', SyncColumnType.text, nullable: true),
    SyncColumn('end_date', SyncColumnType.text, nullable: true),
    SyncColumn('rrule', SyncColumnType.text, nullable: true),
    SyncColumn('reminders', SyncColumnType.json, nullable: true),
    SyncColumn('source', SyncColumnType.text),
  ],
  parents: [SyncRelation('calendar_id', 'calendars')],
  titleOf: _eventTitle,
);

/// `event_overrides` — переопределения экземпляров (spec 3.3).
const SyncTableSpec eventOverridesSpec = SyncTableSpec(
  name: 'event_overrides',
  label: 'Изменение экземпляра',
  columns: [
    SyncColumn('event_id', SyncColumnType.uuid, immutable: true),
    SyncColumn('original_start', SyncColumnType.text, immutable: true),
    SyncColumn('cancelled', SyncColumnType.boolean),
    SyncColumn('title', SyncColumnType.text, nullable: true),
    SyncColumn('description', SyncColumnType.text, nullable: true),
    SyncColumn('location', SyncColumnType.text, nullable: true),
    SyncColumn('start_at', SyncColumnType.datetime, nullable: true),
    SyncColumn('end_at', SyncColumnType.datetime, nullable: true),
    SyncColumn('start_date', SyncColumnType.text, nullable: true),
    SyncColumn('end_date', SyncColumnType.text, nullable: true),
    SyncColumn('reminders', SyncColumnType.json, nullable: true),
  ],
  parents: [SyncRelation('event_id', 'events')],
  titleOf: _overrideTitle,
);

String _calendarTitle(Map<String, Object?> row) => '${row['name']}';

String _eventTitle(Map<String, Object?> row) => '${row['title']}';

/// Заголовок изменения экземпляра в корзине: «Экземпляр 5 окт».
String _overrideTitle(Map<String, Object?> row) {
  final key = '${row['original_start']}';
  final day = key.length >= 10 ? key.substring(0, 10) : key;
  final cancelled = row['cancelled'] == true;
  return '${cancelled ? 'Отмена' : 'Изменение'} экземпляра $day';
}
