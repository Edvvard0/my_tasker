import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/trash/presentation/trash_screen.dart';

import '../support/pump_app.dart';
import '../support/ui_helpers.dart';

final _now = DateTime.utc(2026, 10, 1, 12);

TrashItem _item(
  String title, {
  int daysLeft = 27,
  String label = 'Настройка',
}) => TrashItem(
  table: 'user_settings',
  label: label,
  id: userSettingsId(title),
  title: title,
  deletedAt: _now.subtract(const Duration(days: 3)),
  daysLeft: daysLeft,
);

void main() {
  const route = '/settings/trash';

  testWidgets('загрузка: скелетон', (tester) async {
    final gate = StreamController<List<TrashItem>>();
    addTearDown(gate.close);
    await pumpApp(
      tester,
      location: route,
      overrides: [trashProvider.overrideWith((ref) => gate.stream)],
    );
    expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
  });

  testWidgets('пусто: «Корзина пуста»', (tester) async {
    await pumpApp(tester, location: route, now: _now);
    expect(find.text('Корзина пуста'), findsOneWidget);
    expect(find.textContaining('30 дней'), findsWidgets);
  });

  testWidgets('данные: подписи «удалится через N дней»', (tester) async {
    await pumpApp(
      tester,
      location: route,
      now: _now,
      overrides: [
        trashProvider.overrideWith(
          (ref) => Stream.value([
            _item('ui.theme'),
            _item('sync.interval', daysLeft: 1),
            _item('a.b', daysLeft: 0),
            _item('x', daysLeft: 2),
          ]),
        ),
      ],
    );
    expect(find.byKey(const Key('trash-list')), findsOneWidget);
    expect(find.text('удалится через 27 дней'), findsOneWidget);
    expect(find.text('удалится через 1 день'), findsOneWidget);
    expect(find.text('удалится через 2 дня'), findsOneWidget);
    expect(find.text('удалится сегодня'), findsOneWidget);
    expect(find.text('Удалённое хранится 30 дней.'), findsOneWidget);
    expect(find.textContaining('Настройка · удалено'), findsWidgets);
    expect(find.text('Восстановить'), findsNWidgets(4));
  });

  testWidgets('ошибка чтения: «Повторить»', (tester) async {
    var attempts = 0;
    await pumpApp(
      tester,
      location: route,
      overrides: [
        trashProvider.overrideWith((ref) {
          attempts++;
          return attempts == 1
              ? Stream<List<TrashItem>>.error(StateError('x'))
              : Stream.value(<TrashItem>[]);
        }),
      ],
    );
    expect(find.byKey(const Key('trash-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('trash-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trash-error')), findsNothing);
    expect(find.text('Корзина пуста'), findsOneWidget);
  });

  testWidgets('офлайн: пояснение про отложенное восстановление', (
    tester,
  ) async {
    await pumpApp(
      tester,
      location: route,
      overrides: [
        syncStatusProvider.overrideWith(
          () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
        ),
      ],
    );
    expect(find.byKey(const Key('trash-offline')), findsOneWidget);
    expect(
      find.textContaining('отправится, когда появится сеть'),
      findsOneWidget,
    );
  });

  testWidgets('настоящая корзина: удалили — видно, восстановили — исчезло', (
    tester,
  ) async {
    final container = await pumpApp(tester, location: route, now: _now);
    final store = container.read(syncStoreProvider);
    final id = userSettingsId('ui.theme');
    await tester.runAsync(() async {
      await store.create('user_settings', id, {
        'key': 'ui.theme',
        'value': 'dark',
      });
      await store.softDelete('user_settings', id);
    });
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.text('ui.theme'), findsOneWidget);
    expect(find.text('удалится через 30 дней'), findsOneWidget);

    await tester.tap(find.byKey(Key('restore-$id')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('«ui.theme» восстановлено'), findsOneWidget);
    expect(find.text('ui.theme'), findsNothing);
    final row = await tester.runAsync(() => store.getRow('user_settings', id));
    expect(row!['deleted_at'], isNull);
    final ops = await tester.runAsync(store.outbox);
    expect(ops!.last.fields, {'deleted_at': null});
  });

  test('formatDaysLeft и формы слова «день»', () {
    expect(formatDaysLeft(0), 'удалится сегодня');
    expect(formatDaysLeft(-3), 'удалится сегодня');
    expect(formatDaysLeft(21), 'удалится через 21 день');
    expect(formatDaysLeft(25), 'удалится через 25 дней');
    expect(pluralRu(11, 'день', 'дня', 'дней'), 'дней');
    expect(pluralRu(112, 'день', 'дня', 'дней'), 'дней');
    expect(pluralRu(22, 'день', 'дня', 'дней'), 'дня');
  });

  test('formatMoment: формулировки', () {
    final now = DateTime(2026, 10, 1, 12);
    expect(formatMoment(now, now), 'только что');
    expect(
      formatMoment(now.subtract(const Duration(minutes: 5)), now),
      '5 мин назад',
    );
    expect(
      formatMoment(now.subtract(const Duration(hours: 3)), now),
      'сегодня в 09:00',
    );
    expect(
      formatMoment(now.subtract(const Duration(days: 1)), now),
      'вчера в 12:00',
    );
    expect(
      formatMoment(now.subtract(const Duration(days: 40)), now),
      '22 авг., 12:00',
    );
    expect(
      formatMoment(DateTime(2025, 12, 31, 23, 5), now),
      '31 дек. 2025, 23:05',
    );
    expect(
      formatMoment(now.add(const Duration(minutes: 3)), now),
      'только что',
    );
    expect(formatClock(DateTime(2026, 1, 1, 7, 5)), '07:05');
    expect(formatDate(DateTime(2026, 3, 9), now), '9 марта');
  });
}
