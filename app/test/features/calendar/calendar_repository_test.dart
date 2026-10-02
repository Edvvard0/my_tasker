import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

final String _personal = systemCalendarId('personal');

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

final String e1 = _uuid(1);
final String e2 = _uuid(2);
final String a1 = _uuid(3);

EventEntity _event(
  String id, {
  String? rrule,
  String start = '2026-10-05T07:00:00Z',
  String end = '2026-10-05T08:00:00Z',
  String tz = 'Europe/Moscow',
  String? calendarId,
}) => EventEntity(
  id: id,
  calendarId: calendarId ?? _personal,
  title: 'Пара',
  allDay: false,
  startAt: parseInstant(start),
  endAt: parseInstant(end),
  tz: tz,
  rrule: rrule,
);

void main() {
  ensureTimeZones();
  late ManualClock clock;
  late FakeSyncServer server;
  late CalendarDevice d;
  late CalendarRepository repo;
  var counter = 0;

  setUp(() async {
    clock = ManualClock();
    server = appServer(clock);
    counter = 0;
    d = await CalendarDevice.create(
      server,
      clock: clock,
      newId: () => _uuid(100 + ++counter),
    );
    repo = d.calendars;
    await repo.ensureSystemCalendars();
  });
  tearDown(() async {
    await d.close();
    await server.dispose();
  });

  test(
    'системные календари создаются один раз с детерминированным id',
    () async {
      await repo.ensureSystemCalendars();
      final layers = await repo.layers();
      expect(layers.map((l) => l.systemKey), [
        'personal',
        'work',
        'study',
        'tasks',
        'holidays_ru',
      ]);
      expect(layers.first.id, systemCalendarId('personal'));
      expect(layers.every((l) => l.isSystem && l.visible), isTrue);
      expect(layers.where((l) => l.isVirtual).length, 2);
    },
  );

  test('удалённый системный календарь возвращается', () async {
    final id = systemCalendarId('work');
    await d.device.store.softDelete('calendars', id);
    await repo.ensureSystemCalendars();
    expect((await repo.getLayer(id))!.name, 'Работа');
    expect(await repo.layers(), hasLength(5));
  });

  group('пользовательские слои', () {
    test('создание, правка, порядок, удаление', () async {
      final a = await repo.createLayer(name: ' Спорт ', color: '#112233');
      final b = await repo.createLayer(name: 'Семья');
      var layers = await repo.layers();
      expect(layers.last.id, b);
      expect(layers[5].name, 'Спорт');
      expect(layers[5].position, 5);
      await repo.updateLayer(a, name: 'Спорт+', color: null, visible: false);
      final changed = (await repo.getLayer(a))!;
      expect(changed.name, 'Спорт+');
      expect(changed.color, isNull);
      expect(changed.visible, isFalse);
      await repo.updateLayer(a);
      await repo.reorderLayers([b, a]);
      layers = await repo.layers();
      expect((await repo.getLayer(b))!.position, 0);
      expect((await repo.getLayer(a))!.position, 1);
      await repo.deleteLayer(a);
      expect(await repo.getLayer(a), isNotNull);
      expect((await repo.layers()).any((l) => l.id == a), isFalse);
    });

    test('проверки значений', () async {
      expect(
        () => repo.createLayer(name: '  '),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => repo.createLayer(name: 'x', color: 'red'),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => repo.deleteLayer(systemCalendarId('personal')),
        throwsA(isA<ValidationError>()),
      );
      await repo.deleteLayer('нет такого');
    });

    test('перенос событий и подсчёт перед удалением', () async {
      final a = await repo.createLayer(name: 'A');
      final b = await repo.createLayer(name: 'B');
      await repo.createEvent(_event(e1, calendarId: a));
      await repo.createEvent(_event(e2, calendarId: a));
      expect(await repo.eventCount(a), 2);
      await repo.moveEvents(a, b);
      expect(await repo.eventCount(a), 0);
      expect(await repo.eventCount(b), 2);
    });

    test('удаление слоя скрывает его события', () async {
      final a = await repo.createLayer(name: 'A');
      await repo.createEvent(_event(e1, calendarId: a));
      await repo.deleteLayer(a);
      expect(await repo.eventCount(a), 0);
    });
  });

  group('события', () {
    test('создание и чтение', () async {
      final id = await repo.createEvent(_event(e1));
      final e = (await repo.getEvent(id))!;
      expect(e.title, 'Пара');
      expect(e.startAt, DateTime.utc(2026, 10, 5, 7));
      expect(e.series, isNotNull);
      expect(await repo.getEvent('нет'), isNull);
    });

    test('невалидное событие не пишется', () async {
      expect(
        () => repo.createEvent(_event(e1).copyWith(title: ' ')),
        throwsA(isA<ValidationError>()),
      );
      expect(await d.device.store.outbox(), hasLength(5));
    });

    test('правка времени отправляет группу целиком', () async {
      await repo.createEvent(_event(e1));
      await d.device.sync();
      final e = (await repo.getEvent(e1))!;
      await repo.updateEvent(
        e.copyWith(
          endAt: DateTime.utc(2026, 10, 5, 9),
          reminders: [10],
          description: 'x',
        ),
      );
      final op = (await d.device.store.outbox()).single;
      expect(op.fields!.keys, containsAll(eventTimeColumns));
      expect(op.fields!.keys, contains('rrule'));
      expect(op.fields!['reminders'], [10]);
      await repo.updateEvent((await repo.getEvent(e1))!);
      expect(await d.device.store.outbox(), hasLength(1));
    });

    test('правка названия не трогает группу времени', () async {
      await repo.createEvent(_event(e1));
      await d.device.sync();
      await repo.updateEvent(
        (await repo.getEvent(e1))!.copyWith(title: 'Новое'),
      );
      final op = (await d.device.store.outbox()).single;
      expect(op.fields, {'title': 'Новое'});
    });

    test('смена правила убирает «висячие» переопределения', () async {
      final e = _event(e1, rrule: 'FREQ=DAILY;COUNT=5');
      await repo.createEvent(e);
      await repo.cancelInstance(e, '2026-10-06T07:00:00Z');
      await repo.cancelInstance(e, '2026-10-09T07:00:00Z');
      expect(await repo.overridesOf(e1), hasLength(2));
      await repo.updateEvent(e.copyWith(rrule: 'FREQ=DAILY;COUNT=3'));
      final left = await repo.overridesOf(e1);
      expect(left.map((o) => o.originalStart), ['2026-10-06T07:00:00Z']);
    });

    test('удаление и восстановление', () async {
      await repo.createEvent(_event(e1));
      await repo.deleteEvent(e1);
      expect(await repo.eventCount(_personal), 0);
      await repo.restoreEvent(e1);
    });
  });

  group('экземпляры', () {
    test('отмена, изменение, возврат', () async {
      final e = _event(e1, rrule: 'FREQ=DAILY;COUNT=3');
      await repo.createEvent(e);
      const key = '2026-10-06T07:00:00Z';
      await repo.cancelInstance(e, key);
      var o = (await repo.overridesOf(e1)).single;
      expect(o.cancelled, isTrue);
      expect(o.id, eventOverrideId(e1, key));
      await repo.overrideInstance(
        e,
        key,
        InstanceChange(
          title: 'Другое',
          startAt: DateTime.utc(2026, 10, 6, 10),
          endAt: DateTime.utc(2026, 10, 6, 11),
          reminders: const [5],
        ),
      );
      o = (await repo.overridesOf(e1)).single;
      expect(o.cancelled, isFalse);
      expect(o.title, 'Другое');
      expect(o.reminders, [5]);
      await repo.restoreInstance(e, key);
      expect(await repo.overridesOf(e1), isEmpty);
      // Повторная отмена возвращает ту же строку из корзины.
      await repo.cancelInstance(e, key);
      expect(await repo.overridesOf(e1), hasLength(1));
      await repo.restoreInstance(e, '2026-10-07T07:00:00Z');
    });

    test('проверки значений экземпляра', () async {
      final e = _event(e1, rrule: 'FREQ=DAILY');
      await repo.createEvent(e);
      expect(
        () => repo.overrideInstance(e, 'k', const InstanceChange(title: ' ')),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => repo.overrideInstance(
          e,
          'k',
          InstanceChange(startAt: DateTime.utc(2026)),
        ),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('«это и следующие»', () {
    test('разрез серии с COUNT: хвост получает остаток', () async {
      final e = _event(e1, rrule: 'FREQ=DAILY;COUNT=5');
      await repo.createEvent(e);
      final tailId = await repo.splitFollowing(
        e,
        '2026-10-07T07:00:00Z',
        e.copyWith(
          title: 'Новое',
          startAt: DateTime.utc(2026, 10, 7, 8),
          endAt: DateTime.utc(2026, 10, 7, 9),
        ),
      );
      expect(tailId, isNot(e1));
      final old = (await repo.getEvent(e1))!;
      expect(old.rrule, 'FREQ=DAILY;UNTIL=20261007T065959Z');
      final tail = (await repo.getEvent(tailId))!;
      expect(tail.rrule, 'FREQ=DAILY;COUNT=3');
      expect(tail.title, 'Новое');
      expect(tail.startAt, DateTime.utc(2026, 10, 7, 8));
    });

    test('переопределения хвоста переезжают к новому событию', () async {
      final e = _event(e1, rrule: 'FREQ=DAILY');
      await repo.createEvent(e);
      await repo.cancelInstance(e, '2026-10-06T07:00:00Z');
      await repo.cancelInstance(e, '2026-10-09T07:00:00Z');
      final tailId = await repo.splitFollowing(
        e,
        '2026-10-08T07:00:00Z',
        e.copyWith(
          startAt: DateTime.utc(2026, 10, 8, 7),
          endAt: DateTime.utc(2026, 10, 8, 8),
        ),
      );
      expect((await repo.overridesOf(e1)).map((o) => o.originalStart), [
        '2026-10-06T07:00:00Z',
      ]);
      final moved = await repo.overridesOf(tailId);
      expect(moved.single.originalStart, '2026-10-09T07:00:00Z');
      expect(
        moved.single.id,
        eventOverrideId(tailId, moved.single.originalStart),
      );
    });

    test('первый экземпляр — правка «Все»', () async {
      final e = _event(e1, rrule: 'FREQ=DAILY;COUNT=3');
      await repo.createEvent(e);
      final id = await repo.splitFollowing(
        e,
        '2026-10-05T07:00:00Z',
        e.copyWith(title: 'Все'),
      );
      expect(id, e1);
      expect((await repo.getEvent(e1))!.title, 'Все');
      expect(await d.device.store.visibleRows('events'), hasLength(1));
    });

    test('«весь день»: UNTIL накануне', () async {
      final e = EventEntity(
        id: a1,
        calendarId: _personal,
        title: 'День',
        allDay: true,
        startDate: DateTime.utc(2026, 10, 5),
        endDate: DateTime.utc(2026, 10, 5),
        rrule: 'FREQ=DAILY',
      );
      await repo.createEvent(e);
      final tailId = await repo.splitFollowing(
        e,
        '2026-10-08',
        e.copyWith(
          startDate: DateTime.utc(2026, 10, 8),
          endDate: DateTime.utc(2026, 10, 8),
        ),
      );
      expect((await repo.getEvent(a1))!.rrule, 'FREQ=DAILY;UNTIL=20261007');
      expect((await repo.getEvent(tailId))!.rrule, 'FREQ=DAILY');
    });

    test('не повторяющееся событие разрезать нельзя', () async {
      final e = _event(e1);
      await repo.createEvent(e);
      expect(
        () => repo.splitFollowing(e, 'k', e),
        throwsA(isA<ValidationError>()),
      );
    });

    test('удалить это и следующие', () async {
      final e = _event(e1, rrule: 'FREQ=DAILY;COUNT=5');
      await repo.createEvent(e);
      await repo.cancelInstance(e, '2026-10-08T07:00:00Z');
      await repo.deleteFollowing(e, '2026-10-07T07:00:00Z');
      final old = (await repo.getEvent(e1))!;
      expect(old.rrule, 'FREQ=DAILY;UNTIL=20261007T065959Z');
      expect(await repo.overridesOf(e1), isEmpty);
      // С первого экземпляра — удаление всего события.
      await repo.deleteFollowing(old, '2026-10-05T07:00:00Z');
      expect(await repo.eventCount(_personal), 0);
      // Не повторяющееся — тоже удаление.
      await repo.createEvent(_event(e2));
      await repo.deleteFollowing(_event(e2), 'k');
      expect(await repo.eventCount(_personal), 0);
    });
  });

  test('развёртка через репозиторий видит переопределения', () async {
    final e = _event(e1, rrule: 'FREQ=DAILY;COUNT=3');
    await repo.createEvent(e);
    await repo.cancelInstance(e, '2026-10-06T07:00:00Z');
    final overrides = await repo.overridesOf(e1);
    final result = expandSeries(
      (await repo.getEvent(e1))!.series!,
      from: DateTime.utc(2026, 10),
      to: DateTime.utc(2026, 11),
      cancelled: {
        for (final o in overrides.where((o) => o.cancelled)) o.originalStart,
      },
    );
    expect(result.map((o) => o.key), [
      '2026-10-05T07:00:00Z',
      '2026-10-07T07:00:00Z',
    ]);
  });
}
