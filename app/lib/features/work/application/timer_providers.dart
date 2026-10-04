import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/timer/timer_platform.dart';

/// Главный из идущих таймеров — самый поздний по началу (его показывает
/// плашка и уведомление); `null`, если ничего не идёт.
TimeEntry? primaryTimer(List<TimeEntry> running) {
  TimeEntry? best;
  for (final e in running) {
    if (!e.isRunning) continue;
    if (best == null ||
        e.startedAt.isAfter(best.startedAt) ||
        (e.startedAt == best.startedAt && e.id.compareTo(best.id) > 0)) {
      best = e;
    }
  }
  return best;
}

/// Идущих таймеров больше одного: два таймера, запущенные офлайн на разных
/// устройствах, после синхронизации оказываются рядом (spec 1.6).
bool hasTimerConflict(List<TimeEntry> running) =>
    running.where((e) => e.isRunning).length > 1;

/// Идущие записи (видимые, без `ended_at`), старые первыми.
final StreamProvider<List<TimeEntry>> runningEntriesProvider =
    StreamProvider<List<TimeEntry>>(
      (ref) => ref
          .watch(syncStoreProvider)
          .watchVisibleRows(
            'time_entries',
            where: 't.ended_at IS NULL',
            orderBy: 't.started_at, t.id',
          )
          .map((rows) => [for (final r in rows) TimeEntry.fromRow(r)]),
    );

/// Момент «сейчас» для таймера: раз в секунду, пока интерфейс живёт (тесты
/// виджетов отключают тики вместе с `liveClockProvider`).
class TimerTickNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    if (ref.watch(liveClockProvider)) {
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        state = ref.read(clockProvider)().toUtc();
      });
      ref.onDispose(timer.cancel);
    }
    return ref.read(clockProvider)().toUtc();
  }
}

final NotifierProvider<TimerTickNotifier, DateTime> timerTickProvider =
    NotifierProvider<TimerTickNotifier, DateTime>(TimerTickNotifier.new);

/// Идущий таймер с названиями для показа.
@immutable
class RunningTimer {
  const RunningTimer({
    required this.entry,
    required this.projectTitle,
    this.changeRequestTitle,
  });

  final TimeEntry entry;
  final String projectTitle;
  final String? changeRequestTitle;

  /// «Проект» или «Проект · Доработка».
  String get title => changeRequestTitle == null
      ? projectTitle
      : '$projectTitle · $changeRequestTitle';

  Duration elapsed(DateTime now) {
    final d = now.difference(entry.startedAt);
    return d.isNegative ? Duration.zero : d;
  }
}

/// Все идущие таймеры с названиями (старые первыми).
final Provider<List<RunningTimer>> runningTimersProvider =
    Provider<List<RunningTimer>>((ref) {
      final running =
          ref.watch(runningEntriesProvider).value ?? const <TimeEntry>[];
      if (running.isEmpty) return const [];
      final projects = {
        for (final p
            in ref.watch(workProjectsProvider).value ?? const <WorkProject>[])
          p.id: p.title,
      };
      final crs = {
        for (final c
            in ref.watch(changeRequestsProvider).value ??
                const <ChangeRequest>[])
          c.id: c.title,
      };
      return [
        for (final e in running)
          RunningTimer(
            entry: e,
            projectTitle: projects[e.projectId] ?? 'Проект',
            changeRequestTitle: crs[e.changeRequestId],
          ),
      ];
    });

/// Главный идущий таймер (или `null`).
final Provider<RunningTimer?> primaryTimerProvider = Provider<RunningTimer?>((
  ref,
) {
  final timers = ref.watch(runningTimersProvider);
  final main = primaryTimer([for (final t in timers) t.entry]);
  if (main == null) return null;
  return timers.firstWhere((t) => t.entry.id == main.id);
});

/// Идёт больше одного таймера: показать предупреждение.
final Provider<bool> timerConflictProvider = Provider<bool>(
  (ref) => hasTimerConflict([
    for (final t in ref.watch(runningTimersProvider)) t.entry,
  ]),
);

/// Что показывать в системе (уведомление / трей) — по главному таймеру.
final Provider<TimerNotice?> timerNoticeProvider = Provider<TimerNotice?>((
  ref,
) {
  final timer = ref.watch(primaryTimerProvider);
  if (timer == null) return null;
  return TimerNotice(
    entryId: timer.entry.id,
    title: timer.title,
    startedAt: timer.entry.startedAt,
  );
});

/// Связывает идущий таймер и систему: пока таймер идёт — индикатор
/// показан, остановили — убран; «Стоп» из системы останавливает запись.
/// Следит корень приложения (как `reminderLifecycleProvider`).
final timerLifecycleProvider = Provider<void>((ref) {
  final platform = ref.watch(timerPlatformProvider);
  final repo = ref.watch(workRepositoryProvider);

  Future<void> apply(TimerNotice? notice) async {
    try {
      if (notice == null) {
        await platform.hide();
      } else {
        await platform.show(notice);
      }
    } on Object {
      // Нет разрешения на уведомления или плагина: таймер всё равно идёт.
    }
  }

  ref.listen<TimerNotice?>(
    timerNoticeProvider,
    (previous, next) => unawaited(apply(next)),
    fireImmediately: true,
  );
  final sub = ref
      .watch(timerActionsProvider)
      .stops
      .listen((id) => unawaited(repo.stopTimer(id)));
  ref.onDispose(() => unawaited(sub.cancel()));
});
