import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/app.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/workmanager_background_sync.dart';
import 'package:my_tasker/core/theme/font_licenses.dart';
import 'package:my_tasker/features/calendar/reminders/platform_reminder_scheduler.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  final reminders = createPlatformReminderScheduler(now: DateTime.now);
  runApp(
    ProviderScope(
      overrides: [
        // Android: периодическая фоновая синхронизация через WorkManager
        // (на других платформах внутри — пустышка).
        backgroundSyncProvider.overrideWithValue(
          const WorkmanagerBackgroundSync(),
        ),
        // Локальные напоминания: Android — zonedSchedule, Windows — таймеры.
        reminderSchedulerProvider.overrideWithValue(reminders),
      ],
      child: const MyTaskerApp(),
    ),
  );
}
