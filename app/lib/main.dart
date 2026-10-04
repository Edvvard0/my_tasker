import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/app.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/workmanager_background_sync.dart';
import 'package:my_tasker/core/theme/font_licenses.dart';
import 'package:my_tasker/features/calendar/reminders/platform_reminder_scheduler.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_taps.dart';
import 'package:my_tasker/features/work/timer/platform_timer_notifier.dart';
import 'package:my_tasker/features/work/timer/timer_platform.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  // Нажатия на уведомления (в том числе запустившее приложение) идут в шину.
  final taps = ReminderTaps();
  // «Стоп» из уведомления таймера (Этап 4) приходит через тот же плагин.
  final timerActions = TimerActions();
  final reminders = createPlatformReminderScheduler(
    now: DateTime.now,
    onTap: taps.add,
    onAction: (actionId, payload) {
      if (actionId == timerStopActionId &&
          payload != null &&
          payload.startsWith(timerPayloadPrefix)) {
        timerActions.requestStop(payload.substring(timerPayloadPrefix.length));
      }
    },
  );
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
        reminderTapsProvider.overrideWithValue(taps),
        // Таймер времени: Android — постоянное уведомление со «Стоп».
        timerPlatformProvider.overrideWithValue(
          createPlatformTimerNotifier(ensureReady: reminders.permission),
        ),
        timerActionsProvider.overrideWithValue(timerActions),
      ],
      child: const MyTaskerApp(),
    ),
  );
}
