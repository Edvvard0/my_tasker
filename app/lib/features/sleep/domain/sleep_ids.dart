import 'package:my_tasker/core/calendar_time/calendar_ids.dart'
    show tableNamespace;
import 'package:my_tasker/core/sync/ids.dart';

/// Детерминированные идентификаторы строк «Сна и ритуалов» (spec
/// `stage8_sleep_rituals.md`, 0): по одной строке на дату, два устройства,
/// записавшие один день офлайн, делают одну строку. Формула — как на
/// сервере (`backend/src/tasker/sleep/schema.py`, `day_id`):
/// `uuid5(ns(таблица), "<дата>")`.

const String sleepEntriesTable = 'sleep_entries';
const String dailyPlansTable = 'daily_plans';
const String eveningCheckinsTable = 'evening_checkins';

/// Сон за дату (локальная дата пробуждения).
String sleepEntryId(String date) =>
    uuid5(tableNamespace(sleepEntriesTable), date);

/// Утренний план на дату.
String dailyPlanId(String date) => uuid5(tableNamespace(dailyPlansTable), date);

/// Вечерний чек-ин за дату.
String eveningCheckinId(String date) =>
    uuid5(tableNamespace(eveningCheckinsTable), date);
