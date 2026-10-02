import 'package:my_tasker/core/sync/ids.dart';

/// Детерминированные идентификаторы строк календаря (spec 2.2): два
/// устройства, независимо создавшие «одно и то же» офлайн, получают одну
/// строку. `id = uuid5(ns(table), name)`, где
/// `ns(table) = uuid5(NAMESPACE_URL, "urn:my-tasker:<table>")`.

/// `uuid5(NAMESPACE_URL, ...)`.
const String namespaceUrl = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

/// Пространство имён таблицы.
String tableNamespace(String table) =>
    uuid5(namespaceUrl, 'urn:my-tasker:$table');

/// Системный календарь по `system_key`.
String systemCalendarId(String systemKey) =>
    uuid5(tableNamespace('calendars'), systemKey);

/// Приведение имени тега к одному регистру, одинаковое во всех клиентах:
/// понижаются только заглавные ASCII и кириллица (`toLowerCase` и
/// `str.lower` расходятся для греческой финальной сигмы, турецкой İ и т. п.,
/// и два устройства получили бы разные id одного тега).
String foldTagName(String name) {
  final out = StringBuffer();
  for (final c in name.runes) {
    if ((c >= 0x41 && c <= 0x5A) || (c >= 0x410 && c <= 0x42F)) {
      out.writeCharCode(c + 32);
    } else if (c == 0x401) {
      out.writeCharCode(0x451);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// Тег по имени (регистр не важен: [foldTagName]).
String tagId(String name) => uuid5(tableNamespace('tags'), foldTagName(name));

/// Переопределение экземпляра события.
String eventOverrideId(String eventId, String originalStart) =>
    uuid5(tableNamespace('event_overrides'), '$eventId|$originalStart');

/// Связь задача–тег.
String taskTagId(String taskId, String tagId) =>
    uuid5(tableNamespace('task_tags'), '$taskId|$tagId');

/// Отметка выполнения экземпляра повторяющейся задачи.
String taskCompletionId(String taskId, String instanceDate) =>
    uuid5(tableNamespace('task_completions'), '$taskId|$instanceDate');

/// Ключи системных календарей (spec 3.1) и их названия.
const Map<String, String> systemCalendarNames = {
  'personal': 'Личное',
  'work': 'Работа',
  'study': 'Учёба',
  'tasks': 'Задачи',
  'holidays_ru': 'Праздники России',
};
