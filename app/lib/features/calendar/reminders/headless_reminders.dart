import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';

/// Хук фоновой синхронизации (`runHeadlessSync(afterSync: ...)`): после
/// цикла в изоляте WorkManager перечитывает пояс устройства и пересчитывает
/// напоминания по свежим данным (новое с сервера планируется, удалённое
/// отменяется, горизонт 14 дней сдвигается вперёд). Подписок и таймеров
/// сервис при этом не заводит — только один [ReminderService.replan].
Future<void> replanRemindersAfterSync(ProviderContainer container) async {
  await container.read(deviceTimeZoneProvider.notifier).refresh();
  await container.read(reminderServiceProvider).replan();
}
