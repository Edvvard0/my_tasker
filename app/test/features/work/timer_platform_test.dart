import 'dart:io';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/work/application/timer_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/timer/timer_platform.dart';

import '../../support/work_env.dart';

class _FakePlatform implements TimerPlatform {
  final List<TimerNotice> shown = [];
  int hidden = 0;
  bool failing = false;

  @override
  Future<void> show(TimerNotice notice) async {
    if (failing) throw StateError('нет разрешения на уведомления');
    shown.add(notice);
  }

  @override
  Future<void> hide() async {
    if (failing) throw StateError('нет разрешения на уведомления');
    hidden++;
  }
}

TimeEntry _entry(
  String id,
  DateTime start, {
  DateTime? end,
  String project = 'p',
}) => TimeEntry(
  id: id,
  projectId: project,
  startedAt: start,
  endedAt: end,
  billable: true,
  source: TimeSource.timer,
);

void main() {
  group('главный таймер и конфликт', () {
    final t0 = DateTime.utc(2026, 10, 5, 9);

    test('главный — самый поздний; остановленные не считаются', () {
      expect(primaryTimer(const []), isNull);
      final a = _entry('a', t0);
      final b = _entry('b', t0.add(const Duration(minutes: 5)));
      final done = _entry(
        'c',
        t0.add(const Duration(hours: 1)),
        end: t0.add(const Duration(hours: 2)),
      );
      expect(primaryTimer([a, b, done])!.id, 'b');
      expect(primaryTimer([done]), isNull);
      // Одинаковое начало — решает id: выбор стабилен на всех устройствах.
      expect(primaryTimer([_entry('x', t0), _entry('y', t0)])!.id, 'y');
      expect(primaryTimer([_entry('y', t0), _entry('x', t0)])!.id, 'y');
    });

    test('конфликт — когда идущих больше одного', () {
      final a = _entry('a', t0);
      expect(hasTimerConflict([a]), isFalse);
      expect(hasTimerConflict([a, _entry('b', t0)]), isTrue);
      expect(
        hasTimerConflict([
          a,
          _entry('b', t0, end: t0.add(const Duration(minutes: 1))),
        ]),
        isFalse,
      );
    });

    test('RunningTimer: название и время не уходит в минус', () {
      final timer = RunningTimer(
        entry: _entry('a', t0),
        projectTitle: 'Бот',
        changeRequestTitle: 'Вход',
      );
      expect(timer.title, 'Бот · Вход');
      expect(timer.elapsed(t0.add(const Duration(seconds: 90))).inSeconds, 90);
      expect(
        timer.elapsed(t0.subtract(const Duration(hours: 1))),
        Duration.zero,
      );
      expect(
        RunningTimer(entry: _entry('a', t0), projectTitle: 'Бот').title,
        'Бот',
      );
    });

    test('TimerNotice сравнивается по значению', () {
      final a = TimerNotice(entryId: 'e', title: 'Бот', startedAt: t0);
      final b = TimerNotice(entryId: 'e', title: 'Бот', startedAt: t0);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(TimerNotice(entryId: 'f', title: 'Бот', startedAt: t0)));
    });

    test('NoTimerPlatform ничего не делает', () async {
      const platform = NoTimerPlatform();
      await platform.show(
        TimerNotice(entryId: 'e', title: 'Бот', startedAt: t0),
      );
      await platform.hide();
    });
  });

  test('тик таймера: раз в секунду, пока интерфейс живёт', () {
    fakeAsync((async) {
      var now = DateTime.utc(2026, 10, 5, 9);
      final container = ProviderContainer(
        overrides: [
          liveClockProvider.overrideWithValue(true),
          clockProvider.overrideWithValue(() => now),
        ],
      );
      final seen = <DateTime>[];
      container.listen(timerTickProvider, (_, next) => seen.add(next));
      expect(container.read(timerTickProvider), now);
      now = now.add(const Duration(seconds: 1));
      async.elapse(const Duration(seconds: 1));
      expect(seen, [now]);
      now = now.add(const Duration(seconds: 1));
      async.elapse(const Duration(seconds: 1));
      expect(seen.length, 2);
      container.dispose();
      // После закрытия тик остановлен: незавершённых таймеров нет.
      expect(async.pendingTimers, isEmpty);
    });
  });

  group('индикатор в системе (уведомление / трей)', () {
    late _FakePlatform platform;
    late TimerClock clock;

    Future<ProviderContainer> pump(WidgetTester tester) {
      platform = _FakePlatform();
      clock = TimerClock(workNow);
      return pumpWork(
        tester,
        seed: true,
        fixedClock: false,
        overrides: [
          ...clock.overrides,
          timerPlatformProvider.overrideWithValue(platform),
        ],
      );
    }

    testWidgets('таймер идёт — индикатор показан, остановили — убран', (
      tester,
    ) async {
      final container = await pump(tester);
      expect(platform.shown, isEmpty);
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      late TimerStartResult started;
      await tester.runAsync(() async {
        started = await container
            .read(workRepositoryProvider)
            .startTimer(projectId: bot);
      });
      await tester.pumpAndSettle();
      expect(platform.shown.last.entryId, started.started.id);
      expect(platform.shown.last.title, 'Бот разборов ИИ');
      expect(platform.shown.last.startedAt, workNow);

      await tester.runAsync(
        () => container
            .read(workRepositoryProvider)
            .stopTimer(started.started.id),
      );
      await tester.pumpAndSettle();
      expect(platform.hidden, greaterThan(0));
    });

    testWidgets('«Стоп» из системы останавливает запись', (tester) async {
      final container = await pump(tester);
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      late TimerStartResult started;
      await tester.runAsync(() async {
        started = await container
            .read(workRepositoryProvider)
            .startTimer(projectId: bot);
      });
      await tester.pumpAndSettle();
      clock.moment = clock.moment.add(const Duration(minutes: 7));
      container.read(timerActionsProvider).requestStop(started.started.id);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final entry = container
          .read(workDataProvider)
          .requireValue
          .entries
          .firstWhere((e) => e.id == started.started.id);
      expect(entry.endedAt, clock.moment);
      expect(container.read(runningTimersProvider), isEmpty);
      // «Стоп» по неизвестной или уже остановленной записи — не ошибка.
      container.read(timerActionsProvider)
        ..requestStop(started.started.id)
        ..requestStop('нет такой');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    });

    testWidgets('два таймера: в системе — главный (поздний)', (tester) async {
      final container = await pump(tester);
      final repo = container.read(workRepositoryProvider);
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      final creora = projectIdOf(container, 'Платформа Creora');
      final foreign = repo.newId();
      await tester.runAsync(() async {
        await repo.startTimer(projectId: bot);
        await container
            .read(syncStoreProvider)
            .create(
              'time_entries',
              foreign,
              _entry(
                foreign,
                workNow.add(const Duration(minutes: 3)),
                project: creora,
              ).toFields(),
            );
      });
      await tester.pumpAndSettle();
      expect(platform.shown.last.entryId, foreign);
      expect(platform.shown.last.title, 'Платформа Creora');
    });

    testWidgets('сбой платформы не ломает таймер', (tester) async {
      final container = await pump(tester);
      platform.failing = true;
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      late TimerStartResult started;
      await tester.runAsync(() async {
        started = await container
            .read(workRepositoryProvider)
            .startTimer(projectId: bot);
      });
      await tester.pumpAndSettle();
      expect(container.read(runningTimersProvider), hasLength(1));
      await tester.runAsync(
        () => container
            .read(workRepositoryProvider)
            .stopTimer(started.started.id),
      );
      await tester.pumpAndSettle();
      expect(container.read(runningTimersProvider), isEmpty);
    });
  });

  group('таймер переживает перезапуск приложения', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('timer_restart');
      file = File('${dir.path}/work.sqlite');
    });
    tearDown(() => dir.delete(recursive: true));

    Future<(AppDatabase, WorkRepository, SyncStore)> open(
      DateTime Function() now,
    ) async {
      final db = AppDatabase(NativeDatabase(file));
      final store = SyncStore(
        db: db,
        registry: SyncRegistry(registeredSyncTables),
        nowMs: () => now().millisecondsSinceEpoch,
      );
      return (db, WorkRepository(store, now: now), store);
    }

    test(
      'хранится время начала: после перезапуска таймер идёт дальше',
      () async {
        var now = DateTime.utc(2026, 10, 5, 9);
        var (db, repo, store) = await open(() => now);
        final project = repo.newId();
        await repo.createProject(WorkProject(id: project, title: 'Бот'));
        final started = await repo.startTimer(projectId: project, note: 'вход');
        await store.dispose();
        await db.close();

        // «Перезапуск»: три часа спустя, новое подключение к той же БД.
        now = now.add(const Duration(hours: 3, minutes: 2, seconds: 1));
        (db, repo, store) = await open(() => now);
        addTearDown(() async {
          await store.dispose();
          await db.close();
        });
        final running = await repo.runningEntries();
        expect(running.single.id, started.started.id);
        expect(running.single.startedAt, DateTime.utc(2026, 10, 5, 9));
        expect(running.single.note, 'вход');
        expect(
          RunningTimer(
            entry: running.single,
            projectTitle: 'Бот',
          ).elapsed(now).inSeconds,
          3 * 3600 + 2 * 60 + 1,
        );
        final stopped = (await repo.stopTimer(running.single.id))!;
        expect(entrySeconds(stopped), 3 * 3600 + 2 * 60 + 1);
        expect(await repo.runningEntries(), isEmpty);
      },
    );
  });
}
