// coverage:ignore-file
// Тонкая платформенная прослойка: без устройства не проверяется. Вся логика
// планирования (что, когда, пересчёт при правке/синхронизации/смене пояса)
// лежит в `reminder_planner.dart`, `reminder_scheduler.dart` и
// `reminder_service.dart` и покрыта тестами на поддельном планировщике.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_scheduler.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:timezone/timezone.dart' as tz;

const String _channelId = 'reminders';
const String _channelName = 'Напоминания';

/// Создаёт планировщик для текущей платформы (плагин инициализируется при
/// первом обращении, поэтому вызов синхронный и безопасен в тестах):
///
/// * **Android** — `zonedSchedule` (`flutter_local_notifications`):
///   срабатывает при закрытом приложении и после перезагрузки (плагин
///   восстанавливает запланированное сам, а первый запуск приложения
///   пересчитывает всё заново). Нужны разрешения `POST_NOTIFICATIONS`
///   (Android 13+) и точные будильники `SCHEDULE_EXACT_ALARM` (Android 12+;
///   без них напоминания приходят неточно) — см. `AndroidManifest.xml` и
///   `ReminderScheduler.requestPermission`.
/// * **Windows** — таймеры процесса + тосты через тот же плагин: приложение
///   должно быть запущено (живёт в трее).
/// * остальное или ошибка инициализации — «пустышка».
///
/// [onTap] получает `payload` нажатого уведомления (включая то, из которого
/// приложение было запущено): `event:<id>|<ключ>` или `task:<id>`.
///
/// [onAction] получает нажатия на **кнопки** уведомлений (`actionId` и
/// `payload`): плагин уведомлений один на приложение, поэтому кнопка «Стоп»
/// уведомления таймера (Этап 4) приходит сюда же.
ReminderScheduler createPlatformReminderScheduler({
  required DateTime Function() now,
  void Function(String? payload)? onTap,
  void Function(String actionId, String? payload)? onAction,
}) => _LazyReminderScheduler(now, onTap, onAction);

class _LazyReminderScheduler implements ReminderScheduler {
  _LazyReminderScheduler(this._now, this._onTap, this._onAction);

  final DateTime Function() _now;
  final void Function(String? payload)? _onTap;
  final void Function(String actionId, String? payload)? _onAction;
  Future<ReminderScheduler>? _delegate;

  Future<ReminderScheduler> get _scheduler => _delegate ??= _create();

  Future<ReminderScheduler> _create() async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      void tapped(NotificationResponse response) {
        final action = response.actionId;
        if (action != null && action.isNotEmpty) {
          _onAction?.call(action, response.payload);
          return;
        }
        _onTap?.call(response.payload);
      }

      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          await plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
            ),
            onDidReceiveNotificationResponse: tapped,
          );
          // Приложение запущено нажатием на уведомление (холодный старт).
          final launch = await plugin.getNotificationAppLaunchDetails();
          if (launch?.didNotificationLaunchApp ?? false) {
            final response = launch?.notificationResponse;
            if (response != null) {
              tapped(response);
            } else {
              _onTap?.call(null);
            }
          }
          return _AndroidReminderScheduler(plugin);
        case TargetPlatform.windows:
          await plugin.initialize(
            settings: const InitializationSettings(
              windows: WindowsInitializationSettings(
                appName: 'My Tasker',
                appUserModelId: 'MyTasker.App.Tasker',
                guid: '2f0e5b1c-6a53-4d8e-9c5b-3a0f6f1d7a10',
              ),
            ),
            onDidReceiveNotificationResponse: tapped,
          );
          return TimerReminderScheduler(
            shower: _WindowsShower(plugin),
            now: _now,
          );
        case TargetPlatform.iOS:
        case TargetPlatform.macOS:
        case TargetPlatform.linux:
        case TargetPlatform.fuchsia:
          return NoReminderScheduler();
      }
    } on Object {
      // Нет плагина (тесты, неподдерживаемая платформа): без напоминаний.
      return NoReminderScheduler();
    }
  }

  @override
  Future<Set<int>> pendingIds() async => await (await _scheduler).pendingIds();

  @override
  Future<void> schedule(PlannedReminder reminder) async {
    await (await _scheduler).schedule(reminder);
  }

  @override
  Future<void> cancel(int id) async {
    await (await _scheduler).cancel(id);
  }

  @override
  Future<void> cancelAll() async {
    await (await _scheduler).cancelAll();
  }

  @override
  Future<ReminderPermission> permission() async =>
      await (await _scheduler).permission();

  @override
  Future<ReminderPermission> requestPermission() async =>
      await (await _scheduler).requestPermission();
}

class _AndroidReminderScheduler implements ReminderScheduler {
  _AndroidReminderScheduler(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<Set<int>> pendingIds() async => {
    for (final r in await _plugin.pendingNotificationRequests()) r.id,
  };

  @override
  Future<void> schedule(PlannedReminder reminder) async {
    final exact = await _android?.canScheduleExactNotifications() ?? false;
    await _plugin.zonedSchedule(
      id: reminder.id,
      title: reminder.title,
      body: reminder.body,
      payload: reminder.payload,
      scheduledDate: tz.TZDateTime.from(reminder.fireAt, tz.UTC),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Напоминания о событиях и задачах',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  @override
  Future<void> cancel(int id) async {
    await _plugin.cancel(id: id);
  }

  @override
  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  @override
  Future<ReminderPermission> permission() async {
    final android = _android;
    if (android == null) return ReminderPermission.notRequired;
    if (!(await android.areNotificationsEnabled() ?? false)) {
      return ReminderPermission.notificationsDenied;
    }
    if (!(await android.canScheduleExactNotifications() ?? false)) {
      return ReminderPermission.exactAlarmsDenied;
    }
    return ReminderPermission.granted;
  }

  @override
  Future<ReminderPermission> requestPermission() async {
    final android = _android;
    if (android == null) return ReminderPermission.notRequired;
    await android.requestNotificationsPermission();
    await android.requestExactAlarmsPermission();
    return await permission();
  }
}

class _WindowsShower implements NotificationShower {
  _WindowsShower(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> show(PlannedReminder reminder) async {
    await _plugin.show(
      id: reminder.id,
      title: reminder.title,
      body: reminder.body,
      payload: reminder.payload,
    );
  }
}
