import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/presentation/event_editor.dart';

import '../support/stage2_env.dart';

BuildContext _ctx(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);

Future<void> _open(
  WidgetTester tester, {
  String? eventId,
  String? key,
  DateTime? date,
}) async {
  unawaited(
    showEventEditor(
      _ctx(tester),
      eventId: eventId,
      instanceKey: key,
      initialDate: date,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  // Нижняя кнопка формы может перекрывать поле: докручиваем вручную.
  final form = find
      .descendant(
        of: find.byType(EventEditor),
        matching: find.byType(Scrollable),
      )
      .first;
  final inForm =
      form.evaluate().isNotEmpty &&
      find.descendant(of: form, matching: finder).evaluate().isNotEmpty;
  for (var i = 0; inForm && i < 8 && tester.getCenter(finder).dy > 700; i++) {
    await tester.drag(form, const Offset(0, -120));
    await tester.pumpAndSettle();
  }
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<List<EventEntity>> _events(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(() => c.read(eventsProvider.future)))!;

Future<List<EventOverride>> _overrides(
  WidgetTester tester,
  ProviderContainer c,
  String id,
) async => (await tester.runAsync(
  () => c.read(calendarRepositoryProvider).overridesOf(id),
))!;

Future<void> _confirmPicker(WidgetTester tester) async {
  await tester.tap(
    find
        .descendant(of: find.byType(Dialog), matching: find.byType(TextButton))
        .last,
  );
  await tester.pumpAndSettle();
}

/// Повторяющееся «Английский» (пн, пт; 09:00–10:30 МСК) и экземпляр пятницы.
Future<(EventEntity, String)> _series(
  WidgetTester tester,
  ProviderContainer c,
) async {
  final e = await tester.runAsync(
    () => addEvent(
      c,
      title: 'Английский',
      startUtc: '2026-09-28T06:00:00',
      endUtc: '2026-09-28T07:30:00',
      rrule: 'FREQ=WEEKLY;BYDAY=MO,FR',
      location: 'ауд. 112',
    ),
  );
  // Ключ экземпляра пятницы 2 октября 09:00 МСК.
  return (e!, '2026-10-02T06:00:00Z');
}

void main() {
  group('создание', () {
    testWidgets(
      'все поля: слой, дата, время, длительность, место, напоминания',
      (tester) async {
        final c = await pumpStage2(tester);
        await _open(tester);
        await tester.enterText(find.byKey(const Key('event-title')), 'Созвон');
        await _tap(tester, 'event-layer-${systemCalendarId('work')}');
        await _tap(tester, 'event-date-tomorrow');
        await _tap(tester, 'event-time-1500');
        await _tap(tester, 'event-duration-90');
        await _tap(tester, 'reminder-10');
        await tester.enterText(find.byKey(const Key('event-location')), 'Zoom');
        await tester.enterText(
          find.byKey(const Key('event-description')),
          'Ссылка',
        );
        await _tap(tester, 'event-save');
        final e = (await _events(tester, c)).single;
        expect(e.title, 'Созвон');
        expect(e.calendarId, systemCalendarId('work'));
        expect(e.startAt, moscow(2026, 10, 1, 15));
        expect(e.endAt, moscow(2026, 10, 1, 16, 30));
        expect(e.tz, 'Europe/Moscow');
        expect(e.location, 'Zoom');
        expect(e.description, 'Ссылка');
        expect(e.reminders, [10]);
        expect(find.byKey(const Key('event-title')), findsNothing);
      },
    );

    testWidgets('пустое название — ошибка, событие не создаётся', (
      tester,
    ) async {
      final c = await pumpStage2(tester);
      await _open(tester);
      await _tap(tester, 'event-save');
      expect(find.byKey(const Key('event-error')), findsOneWidget);
      expect(await _events(tester, c), isEmpty);
    });

    testWidgets('на весь день: несколько дней, напоминания сбрасываются', (
      tester,
    ) async {
      final c = await pumpStage2(tester);
      await _open(tester, date: DateTime.utc(2026, 10, 5));
      await tester.enterText(find.byKey(const Key('event-title')), 'Отпуск');
      await _tap(tester, 'reminder-10');
      await _tap(tester, 'event-all-day');
      expect(find.byKey(const Key('event-end-date-today')), findsOneWidget);
      await _tap(tester, 'event-end-date-tomorrow');
      await _tap(tester, 'event-save');
      final e = (await _events(tester, c)).single;
      expect(e.allDay, isTrue);
      expect(e.startDate, DateTime.utc(2026, 10, 5));
      expect(
        e.endDate,
        DateTime.utc(2026, 10).isAfter(e.startDate!) ? e.endDate : e.endDate,
      );
      expect(e.tz, isNull);
      expect(e.reminders, isNull);
    });

    testWidgets('длительность «другое»: выбор времени окончания', (
      tester,
    ) async {
      final c = await pumpStage2(tester);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('event-title')), 'Свой');
      await _tap(tester, 'event-time-1500');
      await _tap(tester, 'event-duration-pick');
      await _confirmPicker(tester);
      await _tap(tester, 'event-save');
      final e = (await _events(tester, c)).single;
      // Окончание «как предложено» — 16:00 (сохраняется 60 минут).
      expect(e.endAt!.difference(e.startAt!).inMinutes, 60);
    });

    testWidgets('часовой пояс: поиск и выбор', (tester) async {
      final c = await pumpStage2(tester);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('event-title')), 'Берлин');
      await _tap(tester, 'event-time-1500');
      await _tap(tester, 'event-timezone');
      expect(find.byKey(const Key('tz-Europe/Moscow')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('tz-search')), 'berlin');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tz-Europe/Berlin')));
      await tester.pumpAndSettle();
      await _tap(tester, 'event-save');
      final e = (await _events(tester, c)).single;
      expect(e.tz, 'Europe/Berlin');
      expect(e.startAt!.hour, anyOf(12, 13));
    });

    testWidgets('повторение по чётным неделям пишет INTERVAL цикла', (
      tester,
    ) async {
      final c = await pumpStage2(tester, seed: true);
      await _open(tester);
      await tester.enterText(find.byKey(const Key('event-title')), 'Пара');
      await _tap(tester, 'event-date-today');
      await _tap(tester, 'repeat-freq-weekly');
      await _tap(tester, 'repeat-day-1');
      await _tap(tester, 'repeat-cycle-2');
      await _tap(tester, 'event-save');
      final e = (await _events(tester, c)).firstWhere((e) => e.title == 'Пара');
      expect(e.rrule, contains('INTERVAL=2'));
      expect(e.rrule, contains('BYDAY=TU'));
    });

    testWidgets('ссылка на настройки цикла закрывает редактор', (tester) async {
      await pumpStage2(tester);
      await _open(tester);
      await _tap(tester, 'repeat-freq-weekly');
      await _tap(tester, 'repeat-open-cycle');
      expect(find.byKey(const Key('event-title')), findsNothing);
      expect(find.byKey(const Key('cycle-card')), findsOneWidget);
    });
  });

  group('правка одиночного', () {
    testWidgets('форма заполнена; сохранение меняет поля', (tester) async {
      final c = await pumpStage2(tester);
      final e = (await tester.runAsync(
        () => addEvent(
          c,
          title: 'Тренировка',
          startUtc: '2026-09-30T15:00:00',
          endUtc: '2026-09-30T16:00:00',
          location: 'Зал',
        ),
      ))!;
      await _open(tester, eventId: e.id);
      expect(
        find.descendant(
          of: find.byKey(const Key('event-title')),
          matching: find.text('Тренировка'),
        ),
        findsOneWidget,
      );
      expect(find.text('Зал'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('event-title')), 'Бассейн');
      await _tap(tester, 'event-duration-30');
      await _tap(tester, 'event-save');
      final got = (await _events(tester, c)).single;
      expect(got.title, 'Бассейн');
      expect(got.endAt!.difference(got.startAt!).inMinutes, 30);
    });

    testWidgets('событие на весь день открывается и сохраняется', (
      tester,
    ) async {
      final c = await pumpStage2(tester);
      final e = (await tester.runAsync(
        () => addAllDayEvent(
          c,
          title: 'Праздник',
          date: DateTime.utc(2026, 10, 3),
          endDate: DateTime.utc(2026, 10, 4),
        ),
      ))!;
      await _open(tester, eventId: e.id);
      expect(find.text('Конец (включительно)'), findsOneWidget);
      await _tap(tester, 'event-save');
      expect(
        (await _events(tester, c)).single.endDate,
        DateTime.utc(2026, 10, 4),
      );
    });

    testWidgets('удаление и «Отменить»', (tester) async {
      final c = await pumpStage2(tester);
      final e = (await tester.runAsync(
        () => addEvent(
          c,
          title: 'Лишнее',
          startUtc: '2026-09-30T15:00:00',
          endUtc: '2026-09-30T16:00:00',
        ),
      ))!;
      await _open(tester, eventId: e.id);
      await _tap(tester, 'event-delete');
      expect(await _events(tester, c), isEmpty);
      expect(find.text('Удалено: «Лишнее»'), findsOneWidget);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(await _events(tester, c), hasLength(1));
    });

    testWidgets('событие не найдено (удалено на другом устройстве)', (
      tester,
    ) async {
      await pumpStage2(tester);
      await _open(tester, eventId: 'no-such-event');
      expect(find.textContaining('Событие не найдено'), findsOneWidget);
    });
  });

  group('правка экземпляра серии', () {
    Future<(ProviderContainer, EventEntity, String)> setup(
      WidgetTester tester,
    ) async {
      final c = await pumpStage2(tester);
      final (e, key) = await _series(tester, c);
      await _open(tester, eventId: e.id, key: key);
      return (c, e, key);
    }

    testWidgets('форма показывает экземпляр (пятница), не мастер', (
      tester,
    ) async {
      await setup(tester);
      expect(find.text('Английский'), findsOneWidget);
      expect(find.text('ауд. 112'), findsOneWidget);
    });

    testWidgets('«Только это»: создаётся изменение экземпляра', (tester) async {
      final (c, e, _) = await setup(tester);
      await tester.enterText(
        find.byKey(const Key('event-title')),
        'Разговорный',
      );
      await _tap(tester, 'event-duration-60');
      await _tap(tester, 'event-save');
      await _tap(tester, 'scope-only');
      final o = (await _overrides(tester, c, e.id)).single;
      expect(o.title, 'Разговорный');
      expect(o.endAt!.difference(o.startAt!).inMinutes, 60);
      expect(find.byKey(const Key('event-title')), findsNothing);
    });

    testWidgets('«Только это» с изменением повторения — ошибка', (
      tester,
    ) async {
      final (c, e, _) = await setup(tester);
      await _tap(tester, 'repeat-freq-daily');
      await _tap(tester, 'event-save');
      await _tap(tester, 'scope-only');
      expect(find.byKey(const Key('event-error')), findsOneWidget);
      expect(await _overrides(tester, c, e.id), isEmpty);
    });

    testWidgets('«Это и следующие»: серия разрезается', (tester) async {
      final (c, _, _) = await setup(tester);
      await tester.enterText(
        find.byKey(const Key('event-title')),
        'Новый курс',
      );
      await _tap(tester, 'event-save');
      await _tap(tester, 'scope-following');
      final events = await _events(tester, c);
      expect(events, hasLength(2));
      expect(
        events.map((e) => e.title),
        containsAll(['Английский', 'Новый курс']),
      );
    });

    testWidgets('«Все в серии»: правится мастер, сдвиг переносится', (
      tester,
    ) async {
      final (c, e, _) = await setup(tester);
      await _tap(tester, 'event-date-tomorrow'); // пятница -> сдвиг даты
      await tester.enterText(find.byKey(const Key('event-title')), 'Курс');
      await _tap(tester, 'event-save');
      await _tap(tester, 'scope-all');
      final got = (await _events(tester, c)).single;
      expect(got.id, e.id);
      expect(got.title, 'Курс');
    });

    testWidgets('закрыть диалог области — ничего не меняется', (tester) async {
      final (c, e, _) = await setup(tester);
      await tester.enterText(find.byKey(const Key('event-title')), 'Нет');
      await _tap(tester, 'event-save');
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect((await _events(tester, c)).single.title, e.title);
      expect(find.byKey(const Key('event-title')), findsOneWidget);
    });

    testWidgets('удаление «Только это» отменяет экземпляр; «Отменить»', (
      tester,
    ) async {
      final (c, e, _) = await setup(tester);
      await _tap(tester, 'event-delete');
      await _tap(tester, 'scope-only');
      expect((await _overrides(tester, c, e.id)).single.cancelled, isTrue);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(
        (await _overrides(tester, c, e.id)).where((o) => o.cancelled),
        isEmpty,
      );
    });

    testWidgets('удаление «Это и следующие» обрезает серию', (tester) async {
      final (c, e, _) = await setup(tester);
      await _tap(tester, 'event-delete');
      await _tap(tester, 'scope-following');
      final got = (await _events(tester, c)).single;
      expect(got.rrule, contains('UNTIL'));
      expect(got.id, e.id);
    });

    testWidgets('удаление «Все в серии» убирает событие', (tester) async {
      final (c, _, _) = await setup(tester);
      await _tap(tester, 'event-delete');
      await _tap(tester, 'scope-all');
      expect(await _events(tester, c), isEmpty);
    });

    testWidgets('закрыть диалог удаления — событие остаётся', (tester) async {
      final (c, _, _) = await setup(tester);
      await _tap(tester, 'event-delete');
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(await _events(tester, c), hasLength(1));
    });
  });

  group('карточка события', () {
    testWidgets('повторяющееся: удаление «Только это» и «Все»', (tester) async {
      final c = await pumpStage2(tester, location: '/calendar', seed: true);
      await tester.tap(find.text('Английский').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Каждую неделю'), findsWidgets);
      await tester.tap(find.byKey(const Key('details-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scope-only')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Удалено:'), findsOneWidget);
      final english = (await _events(
        tester,
        c,
      )).firstWhere((e) => e.title == 'Английский');
      expect(await _overrides(tester, c, english.id), hasLength(1));
    });

    testWidgets('одиночное с напоминанием: «Удалить» без вопросов', (
      tester,
    ) async {
      final c = await pumpStage2(tester, location: '/calendar', seed: true);
      await tester.tap(find.text('Созвон Creora').first);
      await tester.pumpAndSettle();
      expect(find.text('Zoom'), findsWidgets);
      await tester.tap(find.byKey(const Key('details-delete')));
      await tester.pumpAndSettle();
      expect(
        (await _events(tester, c)).where((e) => e.title == 'Созвон Creora'),
        isEmpty,
      );
    });

    testWidgets('весь день и повторение «Только это»/«Это и следующие»', (
      tester,
    ) async {
      final c = await pumpStage2(tester, location: '/calendar', seed: true);
      await tester.ensureVisible(find.text('День рождения Ромы').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('День рождения Ромы').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('весь день'), findsWidgets);
      await tester.tap(find.byKey(const Key('details-delete')));
      await tester.pumpAndSettle();
      expect(
        (await _events(
          tester,
          c,
        )).where((e) => e.title == 'День рождения Ромы'),
        isEmpty,
      );
    });
  });
}
