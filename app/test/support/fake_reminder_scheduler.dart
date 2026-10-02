import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_scheduler.dart';

/// Поддельный планировщик: хранит «запланированное» в памяти и ведёт журнал.
class FakeReminderScheduler implements ReminderScheduler {
  final Map<int, PlannedReminder> scheduled = {};
  final List<String> log = [];
  ReminderPermission state = ReminderPermission.granted;
  int permissionRequests = 0;

  /// Запланированные по возрастанию времени.
  List<PlannedReminder> get sorted =>
      scheduled.values.toList()..sort((a, b) => a.fireAt.compareTo(b.fireAt));

  @override
  Future<Set<int>> pendingIds() async => scheduled.keys.toSet();

  @override
  Future<void> schedule(PlannedReminder reminder) async {
    log.add('+${reminder.id}');
    scheduled[reminder.id] = reminder;
  }

  @override
  Future<void> cancel(int id) async {
    log.add('-$id');
    scheduled.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    log.add('clear');
    scheduled.clear();
  }

  @override
  Future<ReminderPermission> permission() async => state;

  @override
  Future<ReminderPermission> requestPermission() async {
    permissionRequests++;
    return state = ReminderPermission.granted;
  }
}

/// Показ уведомлений «сейчас» с журналом.
class FakeShower implements NotificationShower {
  final List<PlannedReminder> shown = [];

  @override
  Future<void> show(PlannedReminder reminder) async => shown.add(reminder);
}
