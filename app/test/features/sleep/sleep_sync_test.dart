import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/sleep/data/sleep_sync_specs.dart';
import 'package:my_tasker/features/sleep/domain/sleep_ids.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/sleep_env.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Таблицы «Сна» через общий стек синхронизации и фейковый сервер: реестр,
/// детерминированные id, неизменяемые поля, два устройства — один день не
/// плодит дублей; перенос задач из чек-ина — интеграционно с репозиторием
/// задач.
void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late SleepDevice phone;
  late SleepDevice pc;
  var counter = 0;

  setUp(() async {
    // 5 октября 2026, 20:00 UTC (23:00 по Москве).
    clock = ManualClock(DateTime.utc(2026, 10, 5, 20).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => _uuid(8000 + ++counter);
    phone = await SleepDevice.create(server, clock: clock, newId: next);
    pc = await SleepDevice.create(server, clock: clock, newId: next);
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
    expect((await phone.device.store.outboxSummary()).rejected, 0);
    expect((await pc.device.store.outboxSummary()).rejected, 0);
  }

  group('реестр', () {
    test('три таблицы Этапа 8: порядок и неизменяемая дата', () {
      expect(
        [for (final s in sleepSyncSpecs) s.name],
        ['sleep_entries', 'daily_plans', 'evening_checkins'],
      );
      final all = [for (final s in registeredSyncTables) s.name];
      for (final s in sleepSyncSpecs) {
        expect(all, contains(s.name));
        expect(s.parents, isEmpty);
        expect(
          {
            for (final c in s.columns)
              if (c.immutable) c.name,
          },
          {'date'},
        );
      }
      SyncRegistry(registeredSyncTables);
      expect(
        sleepEntriesSpec.column('bed_tz')!.nullable &&
            sleepEntriesSpec.column('quality')!.nullable &&
            !sleepEntriesSpec.column('wake_tz')!.nullable,
        isTrue,
      );
      expect(dailyPlansSpec.column('main_task_id')!.nullable, isTrue);
      expect(eveningCheckinsSpec.column('rating')!.nullable, isTrue);
    });

    test('заголовки строк в корзине', () {
      expect(
        sleepEntriesSpec.titleOf({'date': '2026-10-05'}),
        'Сон 2026-10-05',
      );
      expect(
        dailyPlansSpec.titleOf({'date': '2026-10-05'}),
        'Утренний план 2026-10-05',
      );
      expect(
        eveningCheckinsSpec.titleOf({'date': '2026-10-05'}),
        'Вечерний чек-ин 2026-10-05',
      );
    });
  });

  group('запись сна', () {
    test(
      'дата — день пробуждения, id по дате; повторная запись правит',
      () async {
        final date = await seedNight(phone.sleep, '2026-10-05', quality: 3);
        expect(date, '2026-10-05');
        final row = await phone.device.store.getRow(
          'sleep_entries',
          sleepEntryId('2026-10-05'),
        );
        expect(row!['wake_tz'], 'Europe/Moscow');
        expect(row['bed_at'], '2026-10-04T20:40:00Z');
        expect(row['source'], 'manual');
        expect(row['bed_tz'], isNull);

        await seedNight(phone.sleep, '2026-10-05', wake: '08:00', quality: 5);
        final rows = await phone.device.store.visibleRows('sleep_entries');
        expect(rows, hasLength(1));
        expect(rows.single['wake_at'], '2026-10-05T05:00:00Z');
        expect(rows.single['quality'], 5);
      },
    );

    test(
      'сон за полночь: отбой после 00:00 — тот же календарный день',
      () async {
        await seedNight(phone.sleep, '2026-10-05', bed: '01:15', wake: '08:00');
        final e = await phone.sleep.getEntry('2026-10-05');
        expect(e!.view!.minutes, 6 * 60 + 45);
        expect(e.view!.bedLocal, '01:15');
      },
    );

    test(
      'смена даты правкой: старая строка удаляется, новая создаётся',
      () async {
        await seedNight(phone.sleep, '2026-10-05');
        final entry = (await phone.sleep.getEntry('2026-10-05'))!;
        final moved = await phone.sleep.saveSleep(
          bedAt: entry.bedAt.subtract(const Duration(days: 1)),
          wakeAt: entry.wakeAt.subtract(const Duration(days: 1)),
          wakeTz: entry.wakeTz,
          replacesDate: '2026-10-05',
        );
        expect(moved, '2026-10-04');
        expect(await phone.sleep.getEntry('2026-10-05'), isNull);
        expect(await phone.sleep.getEntry('2026-10-04'), isNotNull);
        expect(
          await phone.device.store.visibleRows('sleep_entries'),
          hasLength(1),
        );
        // Удалённую дату можно записать снова: строка восстанавливается.
        await seedNight(phone.sleep, '2026-10-05');
        expect(
          await phone.device.store.visibleRows('sleep_entries'),
          hasLength(2),
        );
      },
    );

    test('проверки: будущее, длина, зона, самочувствие', () async {
      final bed = DateTime.utc(2026, 10, 4, 20, 40);
      final wake = DateTime.utc(2026, 10, 5, 4, 10);
      Future<void> save({
        DateTime? b,
        DateTime? w,
        String tz = 'Europe/Moscow',
        int? quality,
      }) => phone.sleep.saveSleep(
        bedAt: b ?? bed,
        wakeAt: w ?? wake,
        wakeTz: tz,
        quality: quality,
      );
      await expectLater(
        save(b: DateTime.utc(2026, 10, 7, 20), w: DateTime.utc(2026, 10, 8, 4)),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(save(w: bed), throwsA(isA<ValidationError>()));
      await expectLater(
        save(w: bed.add(const Duration(hours: 25))),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(save(tz: 'Mars/Base'), throwsA(isA<ValidationError>()));
      await expectLater(save(quality: 9), throwsA(isA<ValidationError>()));
      expect(await phone.device.store.visibleRows('sleep_entries'), isEmpty);
    });

    test('самочувствие и заметка к записи; удаление и возврат', () async {
      await seedNight(phone.sleep, '2026-10-05');
      await phone.sleep.updateSleepMeta(
        '2026-10-05',
        quality: 2,
        note: ' плохо ',
      );
      var e = (await phone.sleep.getEntry('2026-10-05'))!;
      expect(e.quality, 2);
      expect(e.note, 'плохо');
      await phone.sleep.updateSleepMeta(
        '2026-10-05',
        quality: 2,
        note: 'плохо',
      );
      await expectLater(
        phone.sleep.updateSleepMeta('2026-01-01'),
        throwsA(isA<StateError>()),
      );
      await phone.sleep.deleteSleep('2026-10-05');
      await phone.sleep.deleteSleep('2026-10-05');
      expect(await phone.sleep.getEntry('2026-10-05'), isNull);
      await phone.sleep.restoreSleep('2026-10-05');
      e = (await phone.sleep.getEntry('2026-10-05'))!;
      expect(e.quality, 2);
    });
  });

  group('план и чек-ин', () {
    test('план: главное добавляется в список первым; ограничения', () async {
      await phone.sleep.savePlan(
        date: '2026-10-05',
        taskIds: [_uuid(1), _uuid(2)],
        mainTaskId: _uuid(3),
        note: '  ',
      );
      var p = (await phone.sleep.getPlan('2026-10-05'))!;
      expect(p.taskIds, [_uuid(3), _uuid(1), _uuid(2)]);
      expect(p.mainTaskId, _uuid(3));
      expect(p.note, isNull);
      expect(p.id, dailyPlanId('2026-10-05'));

      await phone.sleep.savePlan(date: '2026-10-05', taskIds: [_uuid(1)]);
      p = (await phone.sleep.getPlan('2026-10-05'))!;
      expect(p.taskIds, [_uuid(1)]);
      expect(p.mainTaskId, isNull);
      expect(await phone.device.store.visibleRows('daily_plans'), hasLength(1));

      await expectLater(
        phone.sleep.savePlan(
          date: '2026-10-05',
          taskIds: [for (var i = 1; i <= 10; i++) _uuid(i)],
          mainTaskId: _uuid(11),
        ),
        throwsA(isA<ValidationError>()),
      );
      await phone.sleep.deletePlan('2026-10-05');
      expect(await phone.sleep.getPlan('2026-10-05'), isNull);
    });

    test('чек-ин: оценка, решения, повторная запись правит строку', () async {
      await phone.sleep.saveCheckin(
        date: '2026-10-05',
        doneTaskIds: [_uuid(1)],
        carryOver: [
          CarryDecision.tomorrow(_uuid(2)),
          CarryDecision.onDate(_uuid(3), '2026-10-09'),
        ],
        rating: 4,
        note: 'норм',
      );
      var c = (await phone.sleep.getCheckin('2026-10-05'))!;
      expect(c.rating, 4);
      expect(c.carryOver, hasLength(2));
      await phone.sleep.saveCheckin(
        date: '2026-10-05',
        doneTaskIds: [_uuid(1), _uuid(2)],
        rating: 5,
      );
      c = (await phone.sleep.getCheckin('2026-10-05'))!;
      expect(c.doneTaskIds, hasLength(2));
      expect(c.carryOver, isEmpty);
      expect(c.note, isNull);
      expect(
        await phone.device.store.visibleRows('evening_checkins'),
        hasLength(1),
      );
      await expectLater(
        phone.sleep.saveCheckin(
          date: '2026-10-05',
          doneTaskIds: const [],
          rating: 7,
        ),
        throwsA(isA<ValidationError>()),
      );
      await phone.sleep.deleteCheckin('2026-10-05');
      expect(await phone.sleep.getCheckin('2026-10-05'), isNull);
    });
  });

  group('круг синхронизации двух устройств', () {
    test('всё записанное на телефоне доезжает до ПК', () async {
      await seedNight(phone.sleep, '2026-10-05', quality: 4);
      await phone.sleep.savePlan(
        date: '2026-10-05',
        taskIds: [_uuid(1)],
        mainTaskId: _uuid(1),
      );
      await phone.sleep.saveCheckin(
        date: '2026-10-05',
        doneTaskIds: [_uuid(1)],
        carryOver: [CarryDecision.tomorrow(_uuid(2))],
        rating: 3,
      );
      await syncBoth();
      for (final (table, id) in [
        ('sleep_entries', sleepEntryId('2026-10-05')),
        ('daily_plans', dailyPlanId('2026-10-05')),
        ('evening_checkins', eveningCheckinId('2026-10-05')),
      ]) {
        expect(server.row(table, id), isNotNull, reason: table);
        expect(await pc.device.store.getRow(table, id), isNotNull);
      }
      final onPc = await pc.sleep.getCheckin('2026-10-05');
      expect(onPc!.carryOver.single, CarryDecision.tomorrow(_uuid(2)));
      expect((await pc.sleep.getEntry('2026-10-05'))!.quality, 4);
    });

    test('один день, записанный офлайн на двух устройствах, — одна строка; '
        'поля сливаются по одному', () async {
      await seedNight(phone.sleep, '2026-10-05', quality: 3);
      clock.advance(const Duration(seconds: 5));
      await seedNight(pc.sleep, '2026-10-05', wake: '08:00', quality: 5);
      await phone.sleep.savePlan(date: '2026-10-05', taskIds: [_uuid(1)]);
      await pc.sleep.savePlan(date: '2026-10-05', taskIds: [_uuid(2)]);
      await phone.sleep.saveCheckin(
        date: '2026-10-05',
        doneTaskIds: [_uuid(1)],
        rating: 2,
      );
      await pc.sleep.saveCheckin(
        date: '2026-10-05',
        doneTaskIds: const [],
        rating: 4,
      );
      await syncBoth();
      for (final dev in [phone, pc]) {
        for (final table in [
          'sleep_entries',
          'daily_plans',
          'evening_checkins',
        ]) {
          expect(
            await dev.device.store.visibleRows(table),
            hasLength(1),
            reason: table,
          );
        }
      }
      expect(
        (await phone.device.store.visibleRows('sleep_entries')).single,
        (await pc.device.store.visibleRows('sleep_entries')).single,
      );
      // Победила последняя запись (ПК).
      final e = (await phone.sleep.getEntry('2026-10-05'))!;
      expect(e.quality, 5);
      expect(e.view!.wakeLocal, '08:00');
      expect((await phone.sleep.getPlan('2026-10-05'))!.taskIds, [_uuid(2)]);
      expect((await phone.sleep.getCheckin('2026-10-05'))!.rating, 4);
    });

    test('удаление на одном устройстве — удаление на другом', () async {
      await seedNight(phone.sleep, '2026-10-05');
      await syncBoth();
      await pc.sleep.deleteSleep('2026-10-05');
      await syncBoth();
      expect(await phone.sleep.getEntry('2026-10-05'), isNull);
    });
  });

  group('перенос задач из чек-ина (интеграция с задачами)', () {
    Future<String> task(
      SleepDevice d,
      String title, {
      TaskDue due = const TaskDue.none(),
      TaskStatus status = TaskStatus.todo,
      String? rrule,
    }) async {
      final id = d.tasks.newTaskId();
      await d.tasks.createTask(
        TaskEntity(
          id: id,
          title: title,
          status: status,
          due: due,
          rrule: rrule,
          recurrenceMode: rrule == null ? null : RecurrenceMode.schedule,
        ),
      );
      return id;
    }

    TaskDue day(int d) => TaskDue.date(DateTime.utc(2026, 10, d));

    test(
      'даты меняются правильно: завтра, на дату, входящие, со временем',
      () async {
        final dated = await task(phone, 'Датированная', due: day(5));
        final inbox = await task(phone, 'Входящая', status: TaskStatus.inbox);
        final noDate = await task(phone, 'Без даты');
        // 22:30 Москвы 5 октября -> то же настенное время 9 октября.
        final timed = await task(
          phone,
          'Со временем',
          due: TaskDue.at(DateTime.utc(2026, 10, 5, 19, 30), 'Europe/Moscow'),
        );
        final done = await task(
          phone,
          'Готовая',
          due: day(5),
          status: TaskStatus.done,
        );
        final recurring = await task(
          phone,
          'Повторяется',
          due: day(5),
          rrule: 'FREQ=DAILY',
        );

        final outcome = await phone.sleep.applyCarryOver('2026-10-05', [
          CarryDecision.tomorrow(dated),
          CarryDecision.tomorrow(inbox),
          CarryDecision.onDate(noDate, '2026-10-12'),
          CarryDecision.onDate(timed, '2026-10-09'),
          CarryDecision.tomorrow(done),
          CarryDecision.tomorrow(recurring),
          const CarryDecision.tomorrow('01900000-0000-7000-8000-00000000dead'),
        ]);

        expect(outcome.moved, hasLength(4));
        expect(
          [for (final s in outcome.skipped) s.reason],
          ['closed', 'recurring', 'not_found'],
        );
        Future<TaskEntity> get(String id) async =>
            (await phone.tasks.getTask(id))!;
        expect((await get(dated)).due.date, DateTime.utc(2026, 10, 6));
        expect((await get(dated)).status, TaskStatus.todo);
        expect((await get(inbox)).due.date, DateTime.utc(2026, 10, 6));
        expect((await get(inbox)).status, TaskStatus.todo);
        expect((await get(noDate)).due.date, DateTime.utc(2026, 10, 12));
        final t = await get(timed);
        expect(t.due.at, DateTime.utc(2026, 10, 9, 19, 30));
        expect(t.due.tz, 'Europe/Moscow');
        expect((await get(done)).due.date, DateTime.utc(2026, 10, 5));
        expect((await get(recurring)).due.date, DateTime.utc(2026, 10, 5));

        // Повторное применение безопасно: уже перенесённое пропускается.
        final again = await phone.sleep.applyCarryOver('2026-10-05', [
          CarryDecision.tomorrow(dated),
          CarryDecision.onDate(timed, '2026-10-09'),
        ]);
        expect(again.moved, isEmpty);
        expect(
          [for (final s in again.skipped) s.reason],
          ['unchanged', 'unchanged'],
        );
        expect(parseDate('2026-10-06'), (await get(dated)).due.date);
      },
    );

    test(
      'перенос уезжает на второе устройство обычной синхронизацией',
      () async {
        final id = await task(phone, 'Дело', due: day(5));
        await syncBoth();
        await phone.sleep.applyCarryOver('2026-10-05', [
          CarryDecision.tomorrow(id),
        ]);
        await syncBoth();
        expect(
          (await pc.tasks.getTask(id))!.due.date,
          DateTime.utc(2026, 10, 6),
        );
      },
    );

    test(
      'задача, которую не удалось сохранить, пропускается как invalid',
      () async {
        final id = await task(phone, 'Дело', due: day(5));
        // Ломаем задачу напрямую: пустое название не пройдёт проверку.
        await phone.device.store.update('tasks', id, {'title': '   '});
        final outcome = await phone.sleep.applyCarryOver('2026-10-05', [
          CarryDecision.tomorrow(id),
        ]);
        expect(outcome.moved, isEmpty);
        expect(outcome.skipped.single.reason, 'invalid');
      },
    );
  });
}
