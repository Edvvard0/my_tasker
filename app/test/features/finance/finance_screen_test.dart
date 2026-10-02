import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../../support/finance_ui_env.dart';
import '../../support/pump_app.dart';
import '../../support/ui_helpers.dart';

const _nb = ' ';

void main() {
  group('телефон', () {
    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        overrides: [accountRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
      expect(find.byKey(const Key('finance-total')), findsNothing);
    });

    testWidgets('пусто: нет счетов — предложение добавить', (tester) async {
      await pumpFinance(tester);
      expect(find.byKey(const Key('finance-empty')), findsOneWidget);
      expect(find.text('Счетов пока нет'), findsOneWidget);
      await tester.tap(find.byKey(const Key('finance-add-account')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('acc-name')), findsOneWidget);
      expect(find.text('Новый счёт'), findsOneWidget);
    });

    testWidgets('данные: общий баланс, счета, последние операции', (
      tester,
    ) async {
      final demo = (await _demo(tester)).$2;
      expect(textOf(tester, 'finance-total'), '245${_nb}120,10$_nb₽');
      expect(find.byKey(const Key('finance-breakdown')), findsOneWidget);
      expect(
        textOf(tester, 'account-balance-${demo.tbank}'),
        '195${_nb}620,10$_nb₽',
      );
      expect(
        textOf(tester, 'account-balance-${demo.vtb}'),
        '−12${_nb}500$_nb₽',
      );
      expect(find.text('Т-Банк · •• 4242'), findsOneWidget);
      expect(find.text('Наличные'), findsWidgets);
      // Последние операции: новые сверху, доход со знаком «+».
      expect(find.byKey(Key('tx-row-${demo.shop}')), findsOneWidget);
      expect(find.text('Пятёрочка'), findsOneWidget);
      expect(find.text('−1${_nb}249,90$_nb₽'), findsOneWidget);
      // Панели счетов на телефоне нет: счета — карточкой в списке.
      expect(find.byKey(const Key('finance-accounts-panel')), findsNothing);
    });

    testWidgets('счёт вне общего баланса помечен, архивный свёрнут', (
      tester,
    ) async {
      final c = (await _demo(tester)).$1;
      await tester.runAsync(() async {
        await addAccount(c, 'Копилка', opening: 100000, includeInTotal: false);
        await addAccount(c, 'Старый', opening: 50000, archived: true);
      });
      await settleDb(tester);
      expect(find.text('вне общего'), findsOneWidget);
      // Архивный счёт скрыт, но входит в общий баланс по флагу.
      expect(find.text('Старый'), findsNothing);
      expect(textOf(tester, 'finance-total'), '245${_nb}620,10$_nb₽');
      await tester.ensureVisible(
        find.byKey(const Key('accounts-archive-toggle')),
      );
      await tester.tap(find.byKey(const Key('accounts-archive-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Старый'), findsOneWidget);
      expect(find.text('АРХИВ · 1'), findsOneWidget);
    });

    testWidgets('все счета в архиве: подсказка, счета под «Архив»', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        seedWith: (c) => addAccount(c, 'Старый', archived: true),
      );
      expect(find.text('Все счета в архиве.'), findsOneWidget);
      expect(find.text('АРХИВ · 1'), findsOneWidget);
    });

    testWidgets('нет операций — подсказка и кнопка', (tester) async {
      final c = await pumpFinance(
        tester,
        seedWith: (c) => addAccount(c, 'Наличные', kind: AccountKind.cash),
      );
      expect(find.byKey(const Key('finance-recent-empty')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('finance-empty-ops-add')),
      );
      await tester.tap(find.byKey(const Key('finance-empty-ops-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
      expect(c, isNotNull);
    });

    testWidgets('ошибка чтения: плашка и «Повторить»', (tester) async {
      await pumpFinance(
        tester,
        overrides: [
          transactionRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
      expect(
        find.text('Не удалось прочитать финансы на устройстве.'),
        findsOne,
      );
      await tester.tap(find.byKey(const Key('finance-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('офлайн: плашка, данные работают', (tester) async {
      await pumpFinance(
        tester,
        seedWith: seedFinanceDemo,
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });

    testWidgets('быстрые действия открывают редактор нужного вида', (
      tester,
    ) async {
      await _demo(tester);
      await tester.tap(find.byKey(const Key('finance-quick-income')));
      await tester.pumpAndSettle();
      expect(find.text('От кого'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tx-kind-transfer')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-from')), findsOneWidget);
      expect(find.byKey(const Key('tx-to')), findsOneWidget);
    });

    testWidgets('«+» в разделе «Финансы» создаёт операцию', (tester) async {
      await _demo(tester);
      await tester.tap(find.byKey(const Key('create-fab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
      expect(find.byKey(const Key('quick-create-task')), findsNothing);
    });

    testWidgets('тап по счёту открывает экран счёта, «Все ›» — ленту', (
      tester,
    ) async {
      final demo = (await _demo(tester)).$2;
      await tester.tap(find.byKey(Key('account-tile-${demo.tbank}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-balance')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('finance-all-ops')));
      await tester.tap(find.byKey(const Key('finance-all-ops')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feed-search')), findsOneWidget);
    });

    testWidgets('шапка: поиск и категории', (tester) async {
      await _demo(tester);
      await tester.tap(find.byKey(const Key('finance-open-categories')));
      await tester.pumpAndSettle();
      expect(find.text('Категории'), findsWidgets);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finance-open-feed')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feed-search')), findsOneWidget);
    });

    testWidgets('экран засевает стартовые категории', (tester) async {
      var calls = 0;
      await pumpFinance(
        tester,
        overrides: [
          financeBootstrapProvider.overrideWith((ref) {
            calls++;
            return 0;
          }),
        ],
      );
      expect(calls, 1);
    });
  });

  group('десктоп', () {
    testWidgets('счета — в левой панели, без разбивки в карточке баланса', (
      tester,
    ) async {
      final demo = (await _demo(tester, size: desktopSize)).$2;
      expect(find.byKey(const Key('finance-accounts-panel')), findsOneWidget);
      expect(find.byKey(const Key('finance-breakdown')), findsNothing);
      expect(textOf(tester, 'finance-total'), '245${_nb}120,10$_nb₽');
      expect(find.byKey(Key('account-tile-${demo.cash}')), findsOneWidget);
      // Меню «⋯» у строки операции.
      expect(find.byKey(Key('tx-menu-${demo.shop}')), findsOneWidget);
    });

    testWidgets('«Создать» в разделе «Финансы» открывает операцию', (
      tester,
    ) async {
      await _demo(tester, size: desktopSize);
      await tester.tap(find.byKey(const Key('create-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });

    testWidgets('«+» в другом разделе открывает обычное быстрое создание', (
      tester,
    ) async {
      await pumpFinance(tester, location: '/today', size: desktopSize);
      await tester.tap(find.byKey(const Key('create-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quick-create-task')), findsOneWidget);
    });
  });
}

Future<(ProviderContainer, FinanceDemo)> _demo(
  WidgetTester tester, {
  Size size = phoneSize,
}) async {
  late FinanceDemo demo;
  final c = await pumpFinance(
    tester,
    size: size,
    seedWith: (c) async => demo = await seedFinanceDemo(c),
  );
  return (c, demo);
}
