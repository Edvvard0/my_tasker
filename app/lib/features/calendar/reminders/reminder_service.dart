import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_planner.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_scheduler.dart';
import 'package:my_tasker/features/sleep/data/sleep_reminders.dart';
import 'package:my_tasker/features/study/data/study_reminders.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:timezone/timezone.dart' as tz;

/// Создатель периодического таймера (тесты подставляют управляемый).
typedef PeriodicTimerFactory = Timer Function(
  Duration period,
  void Function(Timer timer) callback,
);

/// Дополнительный источник напоминаний (например, «Был на паре?» Этапа 7):
/// даёт свои уведомления и список таблиц, правка которых требует
/// пересчёта. Все источники планируются вместе с событиями и задачами:
/// [reconcileReminders] отменяет всё, чего нет в общем списке, поэтому
/// отдельных планировщиков на одном канале быть не может.
abstract interface class ExtraReminderSource {
  /// Таблицы, правки которых меняют напоминания источника.
  List<String> get tables;

  /// Напоминания на ближайшее время (UTC [now], пояс [zone]).
  Future<List<PlannedReminder>> plan(DateTime now, tz.Location zone);
}

/// Держит запланированные напоминания в соответствии с данными.
///
/// Пересчёт ([replan]) выполняется: при старте; после **любой** правки
/// событий, переопределений, задач, отметок и настроек (в том числе
/// пришедшей с сервера при синхронизации — это те же таблицы БД); при смене
/// таймзоны устройства ([onTimeZoneChanged]); при возврате в приложение и
/// по таймеру [refreshEvery] (горизонт 14 дней сдвигается вперёд, после
/// перезагрузки устройства Android само восстанавливает уведомления, а
/// первый запуск приложения пересчитывает всё заново). Подряд идущие правки
/// склеиваются на [debounce].
class ReminderService {
  ReminderService({
    required this.store,
    required this.scheduler,
    required this.settings,
    required this.zone,
    required this.now,
    this.debounce = const Duration(milliseconds: 500),
    this.refreshEvery = const Duration(hours: 6),
    this.periodicTimer = Timer.periodic,
    this.extraSources = const [],
  });

  final SyncStore store;
  final ReminderScheduler scheduler;
  final CalendarSettingsRepository settings;

  /// Текущий пояс устройства.
  final tz.Location Function() zone;
  final DateTime Function() now;
  final Duration debounce;
  final Duration? refreshEvery;
  final PeriodicTimerFactory periodicTimer;

  /// Дополнительные источники напоминаний (Этап 7: «Был на паре?»;
  /// Этап 8: «Как спал?» и вечерний чек-ин).
  final List<ExtraReminderSource> extraSources;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _debounceTimer;
  Timer? _refreshTimer;
  bool _running = false;
  bool _pending = false;
  Completer<void>? _idle;

  /// Сколько раз пересчитывали (для тестов и отладки).
  int replans = 0;

  /// Последний запланированный список.
  List<PlannedReminder> planned = const [];

  static const _tables = [
    'events',
    'event_overrides',
    'tasks',
    'task_completions',
    'user_settings',
  ];

  /// Читает данные и приводит планировщик к нужному состоянию.
  Future<void> replan() async {
    if (_running) {
      _pending = true;
      await (_idle ??= Completer<void>()).future;
      return;
    }
    _running = true;
    try {
      do {
        _pending = false;
        replans++;
        final input = await _readInput();
        planned = [
          ...planReminders(input),
          for (final source in extraSources)
            ...await source.plan(input.now, input.zone),
        ];
        await reconcileReminders(scheduler, planned);
      } while (_pending);
    } finally {
      _running = false;
      final idle = _idle;
      _idle = null;
      idle?.complete();
    }
  }

  Future<ReminderInput> _readInput() async {
    final reminders = await settings.readAllDayReminderTime();
    return ReminderInput(
      now: now().toUtc(),
      zone: zone(),
      allDayMinutes: parseClockMinutes(reminders) ?? 540,
      events: [
        for (final r in await store.visibleRows('events'))
          EventEntity.fromRow(r),
      ],
      overrides: [
        for (final r in await store.visibleRows('event_overrides'))
          EventOverride.fromRow(r),
      ],
      tasks: [
        for (final r in await store.visibleRows('tasks')) TaskEntity.fromRow(r),
      ],
      completions: [
        for (final r in await store.visibleRows('task_completions'))
          TaskCompletion.fromRow(r),
      ],
    );
  }

  /// Начинает следить за данными и планировать.
  Future<void> start() async {
    for (final table in {
      ..._tables,
      for (final source in extraSources) ...source.tables,
    }) {
      _subscriptions.add(
        store.watchVisibleRows(table).skip(1).listen((_) => _schedule()),
      );
    }
    final every = refreshEvery;
    if (every != null) {
      _refreshTimer = periodicTimer(every, (_) => unawaited(replan()));
    }
    _permission = await scheduler.permission();
    await replan();
  }

  void _schedule() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(replan()));
  }

  /// Пояс устройства изменился: «9:00» для событий на весь день сместилось.
  Future<void> onTimeZoneChanged() => replan();

  /// Приложение вернулось на передний план. Если за это время изменилось
  /// состояние разрешений (например, пользователь выдал «точные
  /// будильники» в системных настройках), всё запланированное
  /// регистрируется заново: на Android режим (точно/неточно) задаётся при
  /// планировании и сам не обновится.
  Future<void> onResumed() async {
    final now = await scheduler.permission();
    final changed = _permission != null && _permission != now;
    _permission = now;
    if (changed) await scheduler.cancelAll();
    await replan();
  }

  ReminderPermission? _permission;

  Future<void> stop() async {
    _debounceTimer?.cancel();
    _refreshTimer?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
  }
}

/// Планировщик уведомлений платформы; по умолчанию — «пустышка» (тесты и
/// платформы без поддержки). В `main.dart` подменяется настоящим.
final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (ref) => NoReminderScheduler(),
);

/// «Пустышка»: ничего не планирует.
class NoReminderScheduler implements ReminderScheduler {
  @override
  Future<Set<int>> pendingIds() async => const {};

  @override
  Future<void> schedule(PlannedReminder reminder) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<ReminderPermission> permission() async =>
      ReminderPermission.notRequired;

  @override
  Future<ReminderPermission> requestPermission() async =>
      ReminderPermission.notRequired;
}

final reminderServiceProvider = Provider<ReminderService>((ref) {
  final service = ReminderService(
    store: ref.watch(syncStoreProvider),
    scheduler: ref.watch(reminderSchedulerProvider),
    settings: ref.watch(calendarSettingsRepositoryProvider),
    zone: () => ref.read(deviceTimeZoneProvider),
    now: () => ref.read(clockProvider)().toUtc(),
    extraSources: [
      ref.watch(studyReminderSourceProvider),
      ref.watch(sleepReminderSourceProvider),
    ],
  );
  // Смена пояса устройства пересчитывает напоминания.
  ref
    ..listen(deviceTimeZoneProvider, (previous, next) {
      if (previous != null && previous.name != next.name) {
        unawaited(service.onTimeZoneChanged());
      }
    })
    ..onDispose(() => unawaited(service.stop()));
  return service;
});

/// Состояние разрешений на уведомления для интерфейса.
final reminderPermissionProvider = FutureProvider<ReminderPermission>(
  (ref) => ref.watch(reminderSchedulerProvider).permission(),
);

/// Связывает вход и напоминания: пока пользователь вошёл, сервис следит
/// за данными и держит уведомления актуальными; при возврате в приложение
/// перечитывает пояс устройства и пересчитывает. Следит корень приложения.
final reminderLifecycleProvider = Provider<void>((ref) {
  // Как и синхронизация: виджет-тесты отключают автозапуск.
  if (!ref.watch(syncAutostartProvider)) return;
  final service = ref.watch(reminderServiceProvider);
  final listener = AppLifecycleListener(
    onResume: () {
      unawaited(() async {
        await ref.read(deviceTimeZoneProvider.notifier).refresh();
        await service.onResumed();
      }());
    },
  );
  ref.onDispose(listener.dispose);
  unawaited(service.start());
});
