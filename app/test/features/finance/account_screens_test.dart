import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/account_editor.dart';

import '../../support/finance_ui_env.dart';
import '../../support/pump_app.dart';
import '../../support/ui_helpers.dart';

const _nb = ' ';

Future<(ProviderContainer, FinanceDemo)> _open(
  WidgetTester tester, {
  required String Function(FinanceDemo d) route,
  Size size = phoneSize,
  List<Override> overrides = const [],
}) async {
  late FinanceDemo demo;
  // Маршрут зависит от id счёта из демо-данных: сначала сеем данные, затем
  // переходим.
  final c = await pumpFinance(
    tester,
    size: size,
    overrides: overrides,
    seedWith: (c) async => demo = await seedFinanceDemo(c),
  );
  await goTo(tester, route(demo));
  return (c, demo);
}

void main() {
  group('экран «Счёт»', () {
    testWidgets('данные: баланс, операции счёта, месячные итоги', (
      tester,
    ) async {
      final (_, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.tbank}',
      );
      expect(textOf(tester, 'account-balance'), '195${_nb}620,10$_nb₽');
      expect(find.text('Т-Банк · •• 4242'), findsOneWidget);
      expect(find.byKey(Key('tx-row-${demo.shop}')), findsOneWidget);
      // Операции других счетов (кроме переводов этого) не показываются.
      expect(find.text('Перекрёсток'), findsOneWidget);
      expect(find.byKey(const Key('month-header-2026-09')), findsOneWidget);
      expect(textOf(tester, 'month-net-2026-09'), 'Итого +17${_nb}020,10$_nb₽');
      // Название счёта в подписях строк не повторяется.
      expect(find.text('Продукты · Сегодня, 09:02'), findsOneWidget);
      expect(find.byKey(const Key('account-reconcile')), findsOneWidget);
      expect(find.byKey(const Key('account-limit')), findsNothing);
    });

    testWidgets('кредитка: лимит; счёт вне общего: пометка', (tester) async {
      await _open(tester, route: (d) => '/finance/accounts/${d.vtb}');
      expect(
        textOf(tester, 'account-limit'),
        'Кредитный лимит 150${_nb}000$_nb₽',
      );
      expect(textOf(tester, 'account-balance'), '−12${_nb}500$_nb₽');
      expect(find.byKey(const Key('account-empty')), findsOneWidget);
      expect(find.text('Операций нет'), findsOneWidget);
    });

    testWidgets('пусто: «Добавить операцию» открывает редактор со счётом', (
      tester,
    ) async {
      await _open(tester, route: (d) => '/finance/accounts/${d.savings}');
      // По накопительному счёту есть входящий перевод.
      expect(find.byKey(const Key('account-empty')), findsNothing);
      await _open(tester, route: (d) => '/finance/accounts/${d.vtb}');
      await tester.ensureVisible(find.byKey(const Key('account-empty-add')));
      await tester.tap(find.byKey(const Key('account-empty-add')));
      await tester.pumpAndSettle();
      expect(find.text('ВТБ Мир'), findsWidgets);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });

    testWidgets('последняя сверка и счёт вне общего баланса', (tester) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}',
      );
      await tester.runAsync(() async {
        await financeRepo(c).updateAccount(
          (await financeRepo(c).getAccount(demo.cash))!
              .copyWith(includeInTotal: false),
        );
        await financeRepo(c).reconcile(
          accountId: demo.cash,
          actualBalance: 4950000,
          at: DateTime.utc(2026, 9, 30, 6),
        );
      });
      await settleDb(tester);
      expect(find.byKey(const Key('account-not-in-total')), findsOneWidget);
      expect(
        textOf(tester, 'account-last-checkpoint'),
        'Сверка 30 сент.: в банке больше на 500$_nb₽',
      );
    });

    testWidgets('счёта нет: «Счёт не найден»', (tester) async {
      await _open(tester, route: (_) => '/finance/accounts/missing');
      expect(find.byKey(const Key('account-missing')), findsOneWidget);
      await tester.tap(find.text('К финансам'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });

    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        location: '/finance/accounts/x',
        overrides: [transactionRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    });

    testWidgets('ошибка: плашка', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/accounts/x',
        overrides: [
          transactionRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('офлайн: плашка над экраном', (tester) async {
      await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}',
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
    });

    testWidgets('архив с ненулевым балансом: предупреждение, затем архив и '
        'возврат', (tester) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.tbank}',
      );
      await tester.tap(find.byKey(const Key('account-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-menu-archive')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(_inDialog('195${_nb}620,10$_nb₽'), findsOneWidget);
      expect(find.textContaining('останутся в общем балансе'), findsOneWidget);
      // Отмена — ничего не меняется.
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect((await _account(tester, c, demo.tbank)).archived, isFalse);
      // Подтверждение.
      await tester.tap(find.byKey(const Key('account-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-menu-archive')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await settleDb(tester);
      expect((await _account(tester, c, demo.tbank)).archived, isTrue);
      expect(find.byKey(const Key('account-archived')), findsOneWidget);
      expect(find.textContaining('в архиве'), findsWidgets);
      // Возврат из архива — без вопросов.
      await tester.tap(find.byKey(const Key('account-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Вернуть из архива'), findsOneWidget);
      await tester.tap(find.byKey(const Key('account-menu-archive')));
      await settleDb(tester);
      expect((await _account(tester, c, demo.tbank)).archived, isFalse);
      expect(find.byKey(const Key('account-archived')), findsNothing);
    });

    testWidgets('архив счёта с нулевым балансом — без вопроса, с отменой', (
      tester,
    ) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}',
      );
      late String id;
      await tester.runAsync(() async {
        final empty = await addAccount(c, 'Пустой');
        id = empty;
      });
      await goTo(tester, '/finance/accounts/$id');
      await tester.tap(find.byKey(const Key('account-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-menu-archive')));
      await settleDb(tester);
      expect(find.byKey(const Key('confirm-dialog')), findsNothing);
      expect(find.text('Счёт «Пустой» в архиве'), findsOneWidget);
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(find.byKey(const Key('account-archived')), findsNothing);
      expect(demo.cash, isNotEmpty);
    });

    testWidgets('удаление: сообщает про корзину и операции, затем уходит на '
        'обзор; «Отменить» возвращает', (tester) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.tbank}',
      );
      await tester.tap(find.byKey(const Key('account-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-menu-delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('уйдёт в корзину'), findsOneWidget);
      expect(find.textContaining('операциями (6)'), findsOneWidget);
      expect(_inDialog('195${_nb}620,10$_nb₽'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await settleDb(tester);
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
      // В общем балансе не осталось Т-Банка.
      expect(textOf(tester, 'finance-total'), '49${_nb}500$_nb₽');
      expect(find.text('Т-Банк Black'), findsNothing);
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(textOf(tester, 'finance-total'), '245${_nb}120,10$_nb₽');
      expect(demo.tbank, isNotEmpty);
      expect(c, isNotNull);
    });

    testWidgets('правка из шапки открывает редактор счёта', (tester) async {
      await _open(tester, route: (d) => '/finance/accounts/${d.tbank}');
      await tester.tap(find.byKey(const Key('account-edit')));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'acc-name'), 'Т-Банк Black');
    });

    testWidgets('«Операция» открывает редактор с этим счётом', (tester) async {
      await _open(tester, route: (d) => '/finance/accounts/${d.cash}');
      await tester.tap(find.byKey(const Key('account-add-tx')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-account')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('tx-account')),
          matching: find.text('Наличные'),
        ),
        findsOneWidget,
      );
    });
  });

  group('редактор счёта', () {
    testWidgets('создание карты: последние 4 цифры и кредитный лимит', (
      tester,
    ) async {
      final c = await pumpFinance(tester);
      await tester.tap(find.byKey(const Key('finance-add-account')));
      await tester.pumpAndSettle();
      // Поля, зависящие от вида.
      expect(find.byKey(const Key('acc-last4')), findsOneWidget);
      expect(find.byKey(const Key('acc-limit')), findsNothing);
      await tapKey(tester, 'acc-kind-cash');
      expect(find.byKey(const Key('acc-last4')), findsNothing);
      await tapKey(tester, 'acc-kind-creditCard');
      expect(find.byKey(const Key('acc-last4')), findsOneWidget);
      expect(find.byKey(const Key('acc-limit')), findsOneWidget);
      await enter(tester, 'acc-name', 'Тинькофф Платинум');
      await enter(tester, 'acc-bank', 'Т-Банк');
      await enter(tester, 'acc-last4', '12ab3456');
      await enter(tester, 'acc-opening', '-12500');
      await enter(tester, 'acc-limit', '150000');
      await tapKey(tester, 'acc-include');
      await tapKey(tester, 'acc-save');
      await settleDb(tester);
      final accounts = (await tester.runAsync(
        () => financeRepo(c).accounts(),
      ))!;
      expect(accounts, hasLength(1));
      final a = accounts.single;
      expect(a.name, 'Тинькофф Платинум');
      expect(a.kind, AccountKind.creditCard);
      expect(a.bank, 'Т-Банк');
      expect(a.cardLast4, '1234');
      expect(a.openingBalance, -1250000);
      expect(a.creditLimit, 15000000);
      expect(a.includeInTotal, isFalse);
      expect(a.openingDate, '2026-09-30');
      expect(a.archived, isFalse);
    });

    testWidgets('наличные: без карты и лимита, дата открытия — выбранная', (
      tester,
    ) async {
      final c = await pumpFinance(tester);
      await tester.tap(find.byKey(const Key('finance-add-account')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'acc-kind-cash');
      await enter(tester, 'acc-name', '  Кошелёк ');
      await enter(tester, 'acc-opening', '1500,5');
      await tester.tap(find.byKey(const Key('acc-date-tomorrow')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'acc-save');
      await settleDb(tester);
      final a = (await tester.runAsync(() => financeRepo(c).accounts()))!
          .single;
      expect(a.name, 'Кошелёк');
      expect(a.kind, AccountKind.cash);
      expect(a.cardLast4, isNull);
      expect(a.creditLimit, isNull);
      expect(a.openingBalance, 150050);
      expect(a.openingDate, '2026-10-01');
    });

    testWidgets('пустое название: ошибка под формой, счёт не создан', (
      tester,
    ) async {
      final c = await pumpFinance(tester);
      await tester.tap(find.byKey(const Key('finance-add-account')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'acc-save');
      expect(find.byKey(const Key('acc-error')), findsOneWidget);
      expect(find.textContaining('Название счёта'), findsOneWidget);
      expect(await tester.runAsync(() => financeRepo(c).accounts()), isEmpty);
    });

    testWidgets('правка: поля заполнены, изменение сохраняется', (
      tester,
    ) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.tbank}',
      );
      await tester.tap(find.byKey(const Key('account-edit')));
      await tester.pumpAndSettle();
      String field(String key) => fieldText(tester, key);
      expect(field('acc-name'), 'Т-Банк Black');
      expect(field('acc-bank'), 'Т-Банк');
      expect(field('acc-last4'), '4242');
      await enter(tester, 'acc-name', 'Т-Банк Premium');
      await tapKey(tester, 'acc-save');
      await settleDb(tester);
      expect((await _account(tester, c, demo.tbank)).name, 'Т-Банк Premium');
      expect(find.text('Т-Банк Premium'), findsWidgets);
    });

    testWidgets('правка кредитки: лимит и карта загружены, лимит меняется', (
      tester,
    ) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.vtb}',
      );
      await tester.tap(find.byKey(const Key('account-edit')));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'acc-limit'), '150${_nb}000');
      expect(fieldText(tester, 'acc-last4'), '7788');
      expect(fieldText(tester, 'acc-opening'), '−12${_nb}500');
      await enter(tester, 'acc-limit', '200000');
      await tapKey(tester, 'acc-save');
      await settleDb(tester);
      final a = await _account(tester, c, demo.vtb);
      expect(a.creditLimit, 20000000);
      expect(
        textOf(tester, 'account-limit'),
        'Кредитный лимит 200${_nb}000$_nb₽',
      );
    });

    testWidgets('архив и удаление из редактора', (tester) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}',
      );
      await tester.tap(find.byKey(const Key('account-edit')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'acc-archive');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await settleDb(tester);
      expect((await _account(tester, c, demo.cash)).archived, isTrue);
      // Редактор закрыт; открываем снова: «Из архива», затем удаляем.
      await tester.tap(find.byKey(const Key('account-edit')));
      await tester.pumpAndSettle();
      expect(find.text('Из архива'), findsOneWidget);
      await tapKey(tester, 'acc-delete');
      expect(find.textContaining('в корзину'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await settleDb(tester);
      final removed = await tester.runAsync(
        () => financeRepo(c).accounts(includeArchived: true),
      );
      expect(removed!.any((a) => a.id == demo.cash), isFalse);
    });

    testWidgets('несуществующий счёт: «Счёт не найден»', (tester) async {
      await pumpFinance(tester, seedWith: seedFinanceDemo);
      unawaited(
        showAccountEditor(
          tester.element(find.byType(Scaffold).first),
          accountId: 'nope',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('acc-missing')), findsOneWidget);
    });
  });

  group('сверка баланса', () {
    testWidgets('введён баланс: «в банке больше», история', (tester) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.tbank}',
      );
      await tester.tap(find.byKey(const Key('account-reconcile')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'reconcile-current'), '195${_nb}620,10$_nb₽');
      expect(find.byKey(const Key('reconcile-history-empty')), findsOneWidget);
      await enter(tester, 'reconcile-amount', '196000');
      await enter(tester, 'reconcile-note', 'по выписке');
      await tapKey(tester, 'reconcile-save');
      await settleDb(tester);
      expect(find.text('В банке больше на 379,90$_nb₽'), findsWidgets);
      expect(find.byKey(const Key('reconcile-result')), findsOneWidget);
      // Баланс счёта теперь равен факту, история пополнилась.
      expect(textOf(tester, 'reconcile-current'), '196${_nb}000$_nb₽');
      expect(find.text('В банке 196${_nb}000$_nb₽'), findsOneWidget);
      expect(find.textContaining('по выписке'), findsOneWidget);
      expect(find.byKey(const Key('reconcile-history-empty')), findsNothing);
      // Операций-корректировок сверка не создаёт.
      final txs = (await tester.runAsync(() => financeRepo(c).transactions()))!;
      expect(txs, hasLength(7));
      final cps = (await tester.runAsync(
        () => financeRepo(c).checkpoints(accountId: demo.tbank),
      ))!;
      expect(cps, hasLength(1));
      expect(cps.single.source, CheckpointSource.manual);
      expect(cps.single.actualBalance, 19600000);
    });

    testWidgets('в банке меньше и «сходится»', (tester) async {
      await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}/reconcile',
      );
      await enter(tester, 'reconcile-amount', '48 000');
      await tapKey(tester, 'reconcile-save');
      await settleDb(tester);
      expect(find.text('В банке меньше на 1${_nb}000$_nb₽'), findsWidgets);
      expect(find.text('−1${_nb}000$_nb₽'), findsOneWidget);
      await enter(tester, 'reconcile-amount', '48000');
      await tapKey(tester, 'reconcile-save');
      await settleDb(tester);
      expect(
        find.text('Сходится: в банке столько же, сколько в учёте'),
        findsWidgets,
      );
    });

    testWidgets('пустой ввод: подсказка, ничего не создаётся', (tester) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}/reconcile',
      );
      await tapKey(tester, 'reconcile-save');
      expect(find.byKey(const Key('reconcile-error')), findsOneWidget);
      expect(find.text('Введи баланс из банка'), findsOneWidget);
      await enter(tester, 'reconcile-amount', '5');
      expect(find.byKey(const Key('reconcile-error')), findsNothing);
      expect(
        await tester.runAsync(
          () => financeRepo(c).checkpoints(accountId: demo.cash),
        ),
        isEmpty,
      );
    });

    testWidgets('сверка раньше открытия счёта: ошибка репозитория', (
      tester,
    ) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}/reconcile',
        overrides: [],
      );
      // Счёт «открывается» в будущем: сверка «сейчас» раньше открытия.
      await tester.runAsync(() async {
        final a = (await financeRepo(c).getAccount(demo.cash))!;
        await financeRepo(c)
            .updateAccount(a.copyWith(openingDate: '2026-12-01'));
      });
      await settleDb(tester);
      await enter(tester, 'reconcile-amount', '100');
      await tapKey(tester, 'reconcile-save');
      await settleDb(tester);
      expect(find.text('Сверка раньше открытия счёта'), findsOneWidget);
    });

    testWidgets('удаление сверки с отменой', (tester) async {
      final (c, demo) = await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}/reconcile',
      );
      late String id;
      await tester.runAsync(() async {
        final line = await financeRepo(c).reconcile(
          accountId: demo.cash,
          actualBalance: 4000000,
          at: DateTime.utc(2026, 9, 29),
        );
        id = line.checkpointId;
      });
      await settleDb(tester);
      expect(find.byKey(Key('checkpoint-$id')), findsOneWidget);
      expect(textOf(tester, 'reconcile-current'), '40${_nb}000$_nb₽');
      await tester.tap(find.byKey(Key('checkpoint-delete-$id')));
      await settleDb(tester);
      expect(find.byKey(Key('checkpoint-$id')), findsNothing);
      expect(textOf(tester, 'reconcile-current'), '49${_nb}000$_nb₽');
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(find.byKey(Key('checkpoint-$id')), findsOneWidget);
      expect(textOf(tester, 'reconcile-current'), '40${_nb}000$_nb₽');
    });

    testWidgets('счёта нет: «Счёт не найден»', (tester) async {
      await _open(tester, route: (_) => '/finance/accounts/nope/reconcile');
      expect(find.byKey(const Key('reconcile-missing')), findsOneWidget);
      await tester.tap(find.text('К финансам'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });

    testWidgets('ошибка чтения', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/accounts/x/reconcile',
        overrides: [
          accountRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        location: '/finance/accounts/x/reconcile',
        overrides: [accountRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    });

    testWidgets('офлайн: плашка', (tester) async {
      await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}/reconcile',
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
    });

    testWidgets('назад ведёт на экран счёта', (tester) async {
      await _open(
        tester,
        route: (d) => '/finance/accounts/${d.cash}/reconcile',
      );
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-balance')), findsOneWidget);
    });
  });
}

/// Текст внутри диалога подтверждения.
Finder _inDialog(String text) => find.descendant(
  of: find.byKey(const Key('confirm-dialog')),
  matching: find.textContaining(text),
);

Future<Account> _account(
  WidgetTester tester,
  ProviderContainer c,
  String id,
) async => (await tester.runAsync(() => financeRepo(c).getAccount(id)))!;
