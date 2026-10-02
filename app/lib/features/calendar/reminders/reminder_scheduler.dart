import 'dart:async';

import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';

/// Планировщик локальных уведомлений. Платформенная часть спрятана за этим
/// интерфейсом: Android — `zonedSchedule` (срабатывает без запущенного
/// приложения, переживает перезагрузку), Windows — таймер внутри процесса
/// (приложение живёт в трее). Логика планирования и пересчёта целиком в
/// Dart и тестируется на поддельном планировщике (`test/support`).
abstract interface class ReminderScheduler {
  /// Идентификаторы уведомлений, запланированных сейчас.
  Future<Set<int>> pendingIds();

  /// Планирует (или заменяет) уведомление.
  Future<void> schedule(PlannedReminder reminder);

  Future<void> cancel(int id);

  Future<void> cancelAll();

  /// Текущее состояние разрешений (без запроса).
  Future<ReminderPermission> permission();

  /// Запрашивает разрешения (уведомления, точные будильники) у системы.
  Future<ReminderPermission> requestPermission();
}

/// Приводит запланированное к желаемому списку: лишнее отменяет, недостающее
/// планирует; совпадающее не трогает. Возвращает число
/// (отменено, запланировано).
Future<({int cancelled, int scheduled})> reconcileReminders(
  ReminderScheduler scheduler,
  List<PlannedReminder> desired,
) async {
  final wanted = {for (final r in desired) r.id: r};
  final pending = await scheduler.pendingIds();
  var cancelled = 0;
  var scheduled = 0;
  for (final id in pending) {
    if (!wanted.containsKey(id)) {
      await scheduler.cancel(id);
      cancelled++;
    }
  }
  for (final r in desired) {
    if (!pending.contains(r.id)) {
      await scheduler.schedule(r);
      scheduled++;
    }
  }
  return (cancelled: cancelled, scheduled: scheduled);
}

/// Показ уведомления «сейчас» (Windows: тост через плагин).
abstract interface class NotificationShower {
  Future<void> show(PlannedReminder reminder);
}

/// Планировщик на таймерах процесса: для платформ без системных
/// отложенных уведомлений (Windows). Пока приложение запущено, в нужный
/// момент показывает уведомление через [NotificationShower]. Таймеры
/// ставятся только на ближайшие [maxDelay] (дальше перепланирует сервис по
/// расписанию), поэтому длинные `Timer` не копятся.
class TimerReminderScheduler implements ReminderScheduler {
  TimerReminderScheduler({
    required this._shower,
    required this._now,
    ReminderPermission permissionState = ReminderPermission.notRequired,
    this.maxDelay = const Duration(days: 20),
  }) : _permission = permissionState;

  final NotificationShower _shower;
  final DateTime Function() _now;
  final ReminderPermission _permission;
  final Duration maxDelay;
  final Map<int, Timer> _timers = {};

  @override
  Future<Set<int>> pendingIds() async => _timers.keys.toSet();

  @override
  Future<void> schedule(PlannedReminder reminder) async {
    await cancel(reminder.id);
    final delay = reminder.fireAt.difference(_now().toUtc());
    if (delay > maxDelay) return;
    _timers[reminder.id] = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timers.remove(reminder.id);
      unawaited(_shower.show(reminder));
    });
  }

  @override
  Future<void> cancel(int id) async => _timers.remove(id)?.cancel();

  @override
  Future<void> cancelAll() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  @override
  Future<ReminderPermission> permission() async => _permission;

  @override
  Future<ReminderPermission> requestPermission() async => _permission;
}
