import 'package:my_tasker/core/calendar_time/calendar_ids.dart'
    show tableNamespace;
import 'package:my_tasker/core/sync/ids.dart';

/// Детерминированные идентификаторы строк «Учёбы» (spec
/// `stage7_study.md`, 1.3–1.7): два устройства, сделавшие одно и то же
/// офлайн, создают одну строку. Формулы — как на сервере
/// (`backend/src/tasker/study/schema.py`).

const String bellsTable = 'study_bells';
const String dayRulesTable = 'study_day_rules';
const String overridesTable = 'class_overrides';
const String attendanceTable = 'study_attendance';

/// Звонок: `uuid5(ns("study_bells"), "<semester>|<on_date или пусто>|<number>")`.
String bellId(String semesterId, String? onDate, int number) =>
    uuid5(tableNamespace(bellsTable), '$semesterId|${onDate ?? ''}|$number');

/// Особый день: `…|weekday:<день>:<cycle_week или пусто>` или `…|date:<дата>`.
String dayRuleId(
  String semesterId, {
  int? weekday,
  String? onDate,
  int? cycleWeek,
}) {
  final scope = onDate != null
      ? 'date:$onDate'
      : 'weekday:$weekday:${cycleWeek ?? ''}';
  return uuid5(tableNamespace(dayRulesTable), '$semesterId|$scope');
}

/// Изменение на дату: `uuid5(ns("class_overrides"), "<slot>|<date>")`.
String overrideId(String slotId, String date) =>
    uuid5(tableNamespace(overridesTable), '$slotId|$date');

/// Отметка посещаемости: `uuid5(ns("study_attendance"), "<slot>|<date>")`.
String attendanceId(String slotId, String date) =>
    uuid5(tableNamespace(attendanceTable), '$slotId|$date');
