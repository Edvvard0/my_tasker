// coverage:ignore-file
// Тонкая платформенная прослойка: без устройства не проверяется. Вся логика
// (какой таймер главный, когда показать и убрать индикатор, что делает
// «Стоп») — в `timer_providers.dart` и `timer_platform.dart` и покрыта
// тестами на поддельной платформе.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:my_tasker/features/work/timer/timer_platform.dart';

const String _channelId = 'timer';
const String _channelName = 'Таймер времени';
const int _notificationId = 0x7A11;

/// Идентификатор кнопки «Стоп» в уведомлении. Нажатие приходит в общий
/// обработчик уведомлений (`createPlatformReminderScheduler(onAction: …)`),
/// потому что плагин уведомлений один на приложение.
const String timerStopActionId = 'timer_stop';

/// Префикс `payload` уведомления таймера: `timer:<id записи>`.
const String timerPayloadPrefix = 'timer:';

/// Платформа таймера для текущей ОС:
///
/// * **Android** — постоянное уведомление (`ongoing`) с хронометром от
///   момента начала и кнопкой «Стоп». Хронометр считает система, поэтому
///   уведомление точно показывает время и при закрытом приложении; сама
///   запись живёт в БД. Кнопка «Стоп» открывает приложение и останавливает
///   запись (`showsUserInterface`), без фонового изолята и без доступа к БД
///   вне процесса приложения.
/// * **Windows и остальные** — «пустышка»: трей требует нативного плагина
///   (например, `tray_manager`), которого в зависимостях нет; индикатор
///   таймера на десктопе — плашка внутри приложения.
///
/// [ensureReady] вызывается перед первым показом: общий плагин
/// инициализирует планировщик напоминаний (`createPlatformReminderScheduler`).
TimerPlatform createPlatformTimerNotifier({
  required Future<void> Function() ensureReady,
}) {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return const NoTimerPlatform();
  }
  return _AndroidTimerPlatform(ensureReady);
}

class _AndroidTimerPlatform implements TimerPlatform {
  _AndroidTimerPlatform(this._ensureReady);

  final Future<void> Function() _ensureReady;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  Future<void>? _ready;
  bool _permissionAsked = false;

  Future<void> get _initialised => _ready ??= _ensureReady();

  /// Android 13+: без разрешения уведомление таймера молча не появится.
  /// Запрашиваем при первом показе (один раз за запуск приложения); отказ
  /// таймер не останавливает — запись времени идёт в любом случае.
  Future<void> _askNotificationPermission() async {
    if (_permissionAsked) return;
    _permissionAsked = true;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return;
      if (await android.areNotificationsEnabled() ?? true) return;
      await android.requestNotificationsPermission();
    } on Object {
      // Не удалось спросить: таймер идёт, просто без уведомления.
    }
  }

  @override
  Future<void> show(TimerNotice notice) async {
    await _initialised;
    await _askNotificationPermission();
    await _plugin.show(
      id: _notificationId,
      title: 'Идёт таймер',
      body: notice.title,
      payload: '$timerPayloadPrefix${notice.entryId}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Идущий таймер времени по проекту',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          usesChronometer: true,
          when: notice.startedAt.millisecondsSinceEpoch,
          category: AndroidNotificationCategory.stopwatch,
          actions: const [
            AndroidNotificationAction(
              timerStopActionId,
              'Стоп',
              showsUserInterface: true,
              cancelNotification: false,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Future<void> hide() async {
    await _initialised;
    await _plugin.cancel(id: _notificationId);
  }
}
