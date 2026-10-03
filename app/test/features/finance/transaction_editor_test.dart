import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

import '../../support/finance_ui_env.dart';
import '../../support/pump_app.dart';

const _nb = ' ';

Future<(ProviderContainer, FinanceDemo)> _open(
  WidgetTester tester, {
  Size size = phoneSize,
  TransactionKind kind = TransactionKind.expense,
  String? Function(FinanceDemo d)? account,
  String? Function(FinanceDemo d)? transaction,
}) async {
  late FinanceDemo demo;
  final c = await pumpFinance(
    tester,
    size: size,
    seedWith: (c) async => demo = await seedFinanceDemo(c),
  );
  unawaited(
    showTransactionEditor(
      tester.element(find.byType(Scaffold).first),
      transactionId: transaction?.call(demo),
      kind: kind,
      accountId: account?.call(demo),
    ),
  );
  await tester.pumpAndSettle();
  return (c, demo);
}

Future<List<FinanceTransaction>> _txs(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(() => financeRepo(c).transactions()))!;

Future<FinanceTransaction> _latest(
  WidgetTester tester,
  ProviderContainer c,
  Set<String> known,
) async => (await _txs(tester, c)).firstWhere((t) => !known.contains(t.id));

Set<String> _ids(List<FinanceTransaction> list) => {for (final t in list) t.id};

void main() {
  group('создание расхода', () {
    testWidgets('сумма с автоформатом, категория, мерчант — запись и баланс', (
      tester,
    ) async {
      final (c, demo) = await _open(tester);
      final before = _ids(await _txs(tester, c));
      expect(find.text('Новая операция'), findsOneWidget);
      await enter(tester, 'tx-amount', '1249,9');
      expect(fieldText(tester, 'tx-amount'), '1${_nb}249,9');
      await enter(tester, 'tx-merchant', 'Пятёрочка');
      await tapKey(tester, 'tx-category');
      await tapKey(tester, 'pick-category-${demo.groceries}');
      expect(
        find.descendant(
          of: find.byKey(const Key('tx-category')),
          matching: find.text('Продукты'),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      expect(find.byKey(const Key('tx-amount')), findsNothing);
      final t = await _latest(tester, c, before);
      expect(t.kind, TransactionKind.expense);
      expect(t.amount, 124990);
      expect(t.accountId, demo.cash);
      expect(t.categoryId, demo.groceries);
      expect(t.merchant, 'Пятёрочка');
      expect(t.comment, isNull);
      expect(t.source, TransactionSource.manual);
      expect(t.status, TransactionStatus.confirmed);
      expect(t.occurredAt, DateTime.utc(2026, 9, 30, 8, 40));
      // Баланс «Наличных» уменьшился на сумму.
      expect(
        textOf(tester, 'account-balance-${demo.cash}'),
        '47${_nb}750,10$_nb₽',
      );
      expect(textOf(tester, 'finance-total'), '243${_nb}870,20$_nb₽');
    });

    testWidgets('счёт можно выбрать; счёт из параметра — выбран сразу', (
      tester,
    ) async {
      final (c, demo) = await _open(tester, account: (d) => d.vtb);
      expect(
        find.descendant(
          of: find.byKey(const Key('tx-account')),
          matching: find.text('ВТБ Мир'),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'tx-account');
      expect(find.byKey(const Key('account-picker')), findsOneWidget);
      await tapKey(tester, 'pick-account-${demo.tbank}');
      await enter(tester, 'tx-amount', '100');
      final before = _ids(await _txs(tester, c));
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      expect((await _latest(tester, c, before)).accountId, demo.tbank);
    });

    testWidgets('чипы «+1 000» и «+5 000»', (tester) async {
      await _open(tester);
      await tapKey(tester, 'tx-chip-1000');
      await tapKey(tester, 'tx-chip-5000');
      expect(fieldText(tester, 'tx-amount'), '6${_nb}000');
    });

    testWidgets('дата и время: «Завтра» и «15:00»', (tester) async {
      final (c, _) = await _open(tester);
      final before = _ids(await _txs(tester, c));
      await enter(tester, 'tx-amount', '10');
      await tapKey(tester, 'tx-date-tomorrow');
      await tapKey(tester, 'tx-time-1500');
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      // 1 октября, 15:00 по Москве = 12:00 UTC.
      expect(
        (await _latest(tester, c, before)).occurredAt,
        DateTime.utc(2026, 10, 1, 12),
      );
    });

    testWidgets('пустая сумма: подсказка, запись не создаётся', (tester) async {
      final (c, _) = await _open(tester);
      final count = (await _txs(tester, c)).length;
      await tapKey(tester, 'tx-save');
      expect(find.byKey(const Key('tx-error')), findsOneWidget);
      expect(find.text('Введи сумму больше нуля'), findsOneWidget);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
      expect((await _txs(tester, c)).length, count);
      // Ввод снимает ошибку.
      await enter(tester, 'tx-amount', '5');
      expect(find.byKey(const Key('tx-error')), findsNothing);
    });

    testWidgets('ошибка репозитория показывается в форме', (tester) async {
      await _open(tester);
      await enter(tester, 'tx-amount', '5');
      await enter(tester, 'tx-comment', 'я' * 2001);
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      expect(
        find.text('Комментарий — не длиннее 2000 символов'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });
  });

  group('вид операции', () {
    testWidgets('смена вида: категория другого вида сбрасывается', (
      tester,
    ) async {
      final (c, demo) = await _open(tester);
      await tapKey(tester, 'tx-category');
      await tapKey(tester, 'pick-category-${demo.groceries}');
      await tapKey(tester, 'tx-kind-income');
      expect(
        find.descendant(
          of: find.byKey(const Key('tx-category')),
          matching: find.text('Без категории'),
        ),
        findsOneWidget,
      );
      // У дохода — свои категории.
      await tapKey(tester, 'tx-category');
      expect(find.byKey(Key('pick-category-${demo.salary}')), findsOneWidget);
      expect(find.byKey(Key('pick-category-${demo.groceries}')), findsNothing);
      await tapKey(tester, 'pick-category-${demo.salary}');
      await enter(tester, 'tx-amount', '185000');
      final before = _ids(await _txs(tester, c));
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      final t = await _latest(tester, c, before);
      expect(t.kind, TransactionKind.income);
      expect(t.categoryId, demo.salary);
      expect(t.amount, 18500000);
    });

    testWidgets('категории — в два уровня: подкатегории под родителем', (
      tester,
    ) async {
      await _open(tester);
      await tapKey(tester, 'tx-category');
      expect(find.text('Транспорт'), findsOneWidget);
      expect(find.text('Такси'), findsOneWidget);
      expect(find.text('Общественный транспорт'), findsOneWidget);
      final parent = tester.getTopLeft(find.text('Транспорт'));
      final child = tester.getTopLeft(find.text('Такси'));
      expect(child.dx, greaterThan(parent.dx));
    });

    testWidgets('сегмент «Расход / Доход / Перевод» над полем суммы', (
      tester,
    ) async {
      await _open(tester);
      expect(
        tester.getTopLeft(find.byKey(const Key('tx-kind-expense'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('tx-amount'))).dy),
      );
      for (final label in ['Расход', 'Доход', 'Перевод']) {
        expect(
          find.descendant(
            of: find.byType(SegmentedPill<TransactionKind>),
            matching: find.text(label),
          ),
          findsOneWidget,
        );
      }
    });
  });

  group('перевод', () {
    testWidgets('«откуда → куда», разные счета, запись и балансы', (
      tester,
    ) async {
      final (c, demo) = await _open(tester, kind: TransactionKind.transfer);
      // По умолчанию: первый счёт -> второй.
      String label(String key) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(Text),
            ),
          )
          .first
          .data!;
      expect(label('tx-from'), 'Наличные');
      expect(label('tx-to'), 'Т-Банк Black');
      expect(find.byKey(const Key('tx-category')), findsNothing);
      // «Куда» не предлагает счёт «откуда».
      await tapKey(tester, 'tx-to');
      expect(find.byKey(Key('pick-account-${demo.cash}')), findsNothing);
      expect(find.byKey(Key('pick-account-${demo.vtb}')), findsOneWidget);
      await tapKey(tester, 'pick-account-${demo.vtb}');
      expect(label('tx-to'), 'ВТБ Мир');
      await tapKey(tester, 'tx-swap');
      expect(label('tx-from'), 'ВТБ Мир');
      expect(label('tx-to'), 'Наличные');
      await enter(tester, 'tx-amount', '2 000');
      final before = _ids(await _txs(tester, c));
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      final t = await _latest(tester, c, before);
      expect(t.kind, TransactionKind.transfer);
      expect(t.accountId, demo.vtb);
      expect(t.toAccountId, demo.cash);
      expect(t.categoryId, isNull);
      expect(t.amount, 200000);
      // Общий баланс не меняется: оба счёта в общем балансе.
      expect(textOf(tester, 'finance-total'), '245${_nb}120,10$_nb₽');
      expect(
        textOf(tester, 'account-balance-${demo.cash}'),
        '51${_nb}000$_nb₽',
      );
      expect(
        textOf(tester, 'account-balance-${demo.vtb}'),
        '−14${_nb}500$_nb₽',
      );
    });

    testWidgets('«откуда» совпало с «куда»: «куда» подбирается другой', (
      tester,
    ) async {
      final (_, demo) = await _open(tester, kind: TransactionKind.transfer);
      String to() => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('tx-to')),
              matching: find.byType(Text),
            ),
          )
          .first
          .data!;
      expect(to(), 'Т-Банк Black');
      await tapKey(tester, 'tx-from');
      await tapKey(tester, 'pick-account-${demo.tbank}');
      // Один и тот же счёт с двух сторон невозможен.
      expect(to(), 'Наличные');
    });

    testWidgets('один счёт: перевод невозможен', (tester) async {
      await pumpFinance(
        tester,
        seedWith: (c) => addAccount(c, 'Единственный', kind: AccountKind.cash),
      );
      unawaited(
        showTransactionEditor(
          tester.element(find.byType(Scaffold).first),
          kind: TransactionKind.transfer,
        ),
      );
      await tester.pumpAndSettle();
      await enter(tester, 'tx-amount', '1');
      await tapKey(tester, 'tx-save');
      expect(find.text('Выбери счёт, куда переводим'), findsOneWidget);
    });

    testWidgets('смена вида с перевода на расход прячет «Откуда/Куда»', (
      tester,
    ) async {
      await _open(tester, kind: TransactionKind.transfer);
      expect(find.byKey(const Key('tx-to')), findsOneWidget);
      await tapKey(tester, 'tx-kind-expense');
      expect(find.byKey(const Key('tx-to')), findsNothing);
      expect(find.byKey(const Key('tx-account')), findsOneWidget);
      expect(find.byKey(const Key('tx-category')), findsOneWidget);
    });
  });

  group('предупреждение «задним числом»', () {
    Future<(ProviderContainer, FinanceDemo)> reconciled(
      WidgetTester tester,
    ) async {
      final (c, demo) = await _open(tester);
      await tester.runAsync(
        () => financeRepo(c).reconcile(
          accountId: demo.cash,
          actualBalance: 4900000,
          at: DateTime.utc(2026, 9, 30, 8),
        ),
      );
      await settleDb(tester);
      return (c, demo);
    }

    testWidgets('операция раньше последней сверки — предупреждение', (
      tester,
    ) async {
      await reconciled(tester);
      // Сейчас 11:40 по Москве, сверка в 11:00: операция позже — тихо.
      expect(find.byKey(const Key('tx-backdated-warning')), findsNothing);
      // 09:00 по Москве — раньше сверки.
      await tapKey(tester, 'tx-time-0900');
      expect(find.byKey(const Key('tx-backdated-warning')), findsOneWidget);
      expect(
        find.textContaining('раньше последней сверки счёта «Наличные»'),
        findsOneWidget,
      );
      expect(find.textContaining('Баланс счёта не изменится'), findsOneWidget);
      // Время после сверки снимает предупреждение.
      await tapKey(tester, 'tx-time-1200');
      expect(find.byKey(const Key('tx-backdated-warning')), findsNothing);
    });

    testWidgets('другой счёт без сверок — без предупреждения; перевод — '
        'по обоим счетам', (tester) async {
      final (_, demo) = await reconciled(tester);
      await tapKey(tester, 'tx-time-0900');
      await tapKey(tester, 'tx-account');
      await tapKey(tester, 'pick-account-${demo.tbank}');
      expect(find.byKey(const Key('tx-backdated-warning')), findsNothing);
      // Перевод с Т-Банка на «Наличные»: сверка у получателя.
      await tapKey(tester, 'tx-kind-transfer');
      await tapKey(tester, 'tx-to');
      await tapKey(tester, 'pick-account-${demo.cash}');
      expect(find.byKey(const Key('tx-backdated-warning')), findsOneWidget);
      expect(find.textContaining('«Наличные»'), findsOneWidget);
    });

    testWidgets(
      'перевод между двумя сверенными счетами: оба в предупреждении',
      (tester) async {
        final (c, demo) = await reconciled(tester);
        await tester.runAsync(
          () => financeRepo(c).reconcile(
            accountId: demo.tbank,
            actualBalance: 19000000,
            at: DateTime.utc(2026, 9, 30, 8),
          ),
        );
        await settleDb(tester);
        await tapKey(tester, 'tx-kind-transfer');
        await tapKey(tester, 'tx-time-0900');
        expect(find.byKey(const Key('tx-backdated-warning')), findsOneWidget);
        expect(
          find.textContaining('«Наличные», «Т-Банк Black»'),
          findsOneWidget,
        );
      },
    );

    testWidgets('операция всё равно сохраняется (баланс не меняется)', (
      tester,
    ) async {
      final (c, demo) = await reconciled(tester);
      await tapKey(tester, 'tx-time-0900');
      await enter(tester, 'tx-amount', '1000');
      final before = _ids(await _txs(tester, c));
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      expect((await _latest(tester, c, before)).amount, 100000);
      // Сверка — истина на свой момент: баланс «Наличных» равен факту.
      expect(
        textOf(tester, 'account-balance-${demo.cash}'),
        '49${_nb}000$_nb₽',
      );
    });
  });

  group('правка и удаление', () {
    testWidgets('поля заполнены; изменение сохраняется в той же операции', (
      tester,
    ) async {
      final (c, demo) = await _open(tester, transaction: (d) => d.shop);
      expect(find.text('Операция'), findsOneWidget);
      expect(fieldText(tester, 'tx-amount'), '1${_nb}249,90');
      expect(fieldText(tester, 'tx-merchant'), 'Пятёрочка');
      expect(
        find.descendant(
          of: find.byKey(const Key('tx-account')),
          matching: find.text('Т-Банк Black'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('tx-category')),
          matching: find.text('Продукты'),
        ),
        findsOneWidget,
      );
      await enter(tester, 'tx-amount', '1300');
      await enter(tester, 'tx-comment', 'с картой');
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      final t = (await _txs(tester, c)).firstWhere((t) => t.id == demo.shop);
      expect(t.amount, 130000);
      expect(t.comment, 'с картой');
      expect(t.merchant, 'Пятёрочка');
      expect(t.categoryId, demo.groceries);
      expect(t.occurredAt, DateTime.utc(2026, 9, 30, 6, 2));
      expect((await _txs(tester, c)).length, 7);
    });

    testWidgets('правка перевода: «откуда» и «куда» из записи', (tester) async {
      late String transferId;
      final c = await pumpFinance(
        tester,
        seedWith: (c) async {
          final demo = await seedFinanceDemo(c);
          transferId = (await financeRepo(
            c,
          ).transactions()).firstWhere((t) => t.isTransfer).id;
          expect(demo.cash, isNotEmpty);
        },
      );
      unawaited(
        showTransactionEditor(
          tester.element(find.byType(Scaffold).first),
          transactionId: transferId,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-from')), findsOneWidget);
      expect(find.byKey(const Key('tx-to')), findsOneWidget);
      expect(fieldText(tester, 'tx-amount'), '5${_nb}000');
      expect(c, isNotNull);
    });

    testWidgets('удаление из редактора: снэкбар, «Отменить» возвращает', (
      tester,
    ) async {
      final (c, demo) = await _open(tester, transaction: (d) => d.shop);
      await tapKey(tester, 'tx-delete');
      await settleDb(tester);
      expect(find.byKey(const Key('tx-amount')), findsNothing);
      expect(find.text('Операция удалена'), findsOneWidget);
      expect((await _txs(tester, c)).any((t) => t.id == demo.shop), isFalse);
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect((await _txs(tester, c)).any((t) => t.id == demo.shop), isTrue);
    });

    testWidgets('операции нет: «Операция не найдена»', (tester) async {
      await _open(tester, transaction: (_) => 'nope');
      expect(find.byKey(const Key('tx-missing')), findsOneWidget);
    });
  });

  group('счетов нет', () {
    testWidgets('сначала добавь счёт; после создания форма открывается', (
      tester,
    ) async {
      await pumpFinance(tester);
      unawaited(
        showTransactionEditor(tester.element(find.byType(Scaffold).first)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-no-accounts')), findsOneWidget);
      expect(find.text('Сначала добавь счёт'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tx-add-account')));
      await tester.pumpAndSettle();
      await enter(tester, 'acc-name', 'Кошелёк');
      await tapKey(tester, 'acc-save');
      await settleDb(tester);
      expect(find.byKey(const Key('tx-no-accounts')), findsNothing);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('tx-account')),
          matching: find.text('Кошелёк'),
        ),
        findsOneWidget,
      );
    });
  });

  group('операция, привязанная к долгу', () {
    Future<(ProviderContainer, FinanceDemo, FinanceTransaction)> openLinked(
      WidgetTester tester,
    ) async {
      late FinanceDemo demo;
      late String debt;
      final c = await pumpFinance(
        tester,
        seedWith: (c) async {
          demo = await seedFinanceDemo(c);
          debt = await addDebt(c, who: 'Тимур', amount: 500000);
          await addRepaymentTo(
            c,
            debt: debt,
            amount: 200000,
            account: demo.tbank,
            note: 'вернул часть',
          );
        },
      );
      final tx = (await _txs(tester, c)).firstWhere((t) => t.debtId == debt);
      unawaited(
        showTransactionEditor(
          tester.element(find.byType(Scaffold).first),
          transactionId: tx.id,
        ),
      );
      await tester.pumpAndSettle();
      await settleDb(tester);
      return (c, demo, tx);
    }

    testWidgets('вид и сумма недоступны, подсказка; остальное правится, '
        'debt_id цел', (tester) async {
      final (c, demo, tx) = await openLinked(tester);
      expect(tx.kind, TransactionKind.income);
      expect(find.byKey(const Key('tx-debt-linked-hint')), findsOneWidget);
      expect(
        find.text('Сумма и вид меняются через погашение долга'),
        findsOneWidget,
      );
      // Сумма — только чтение, чипов «+100» нет.
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('tx-amount')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.readOnly, isTrue);
      expect(find.byKey(const Key('tx-chip-100')), findsNothing);
      // Вид не переключается: «Перевод» ничего не делает.
      await tester.tap(find.byKey(const Key('tx-kind-transfer')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-from')), findsNothing);
      expect(find.byKey(const Key('tx-account')), findsOneWidget);

      await enter(tester, 'tx-comment', 'уточнил');
      await tapKey(tester, 'tx-account');
      await tapKey(tester, 'pick-account-${demo.cash}');
      await tapKey(tester, 'tx-save');
      await settleDb(tester);
      expect(find.byKey(const Key('tx-amount')), findsNothing);
      final saved = (await _txs(tester, c)).firstWhere((t) => t.id == tx.id);
      expect(saved.debtId, tx.debtId);
      expect(saved.kind, TransactionKind.income);
      expect(saved.amount, 200000);
      expect(saved.comment, 'уточнил');
      expect(saved.accountId, demo.cash);
    });

    testWidgets('обычная операция: вид и сумма редактируются, подсказки нет', (
      tester,
    ) async {
      final (_, _) = await _open(tester, transaction: (d) => d.shop);
      expect(find.byKey(const Key('tx-debt-linked-hint')), findsNothing);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('tx-amount')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.readOnly, isFalse);
      await tester.tap(find.byKey(const Key('tx-kind-transfer')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-from')), findsOneWidget);
    });
  });

  testWidgets('десктоп: форма в панели справа, сохранение работает', (
    tester,
  ) async {
    final (c, demo) = await _open(tester, size: desktopSize);
    final before = _ids(await _txs(tester, c));
    await enter(tester, 'tx-amount', '777');
    // Выбор счёта на десктопе — окно по центру.
    await tapKey(tester, 'tx-account');
    expect(find.byType(Dialog), findsWidgets);
    await tapKey(tester, 'pick-account-${demo.vtb}');
    await tapKey(tester, 'tx-save');
    await settleDb(tester);
    final saved = await _latest(tester, c, before);
    expect(saved.amount, 77700);
    expect(saved.accountId, demo.vtb);
    expect(find.byKey(const Key('tx-amount')), findsNothing);
    // Лента обзора обновилась.
    expect(c.read(financeBalancesProvider).value, isNotNull);
  });
}
