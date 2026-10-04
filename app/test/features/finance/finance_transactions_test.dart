import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';

import '../../support/finance_env.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

Future<List<FinTransaction>> _txs(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(
  () async => [
    for (final r in await c.read(syncStoreProvider).visibleRows('transactions'))
      FinTransaction.fromRow(r),
  ],
))!;

void main() {
  late FinanceDemo demo;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String location = '/finance/transactions',
    Size size = phoneSize,
    Future<void> Function(ProviderContainer c)? more,
  }) => pumpFinance(
    tester,
    location: location,
    size: size,
    seedWith: (c) async {
      demo = await seedFinanceDemo(c);
      if (more != null) await more(c);
    },
  );

  Future<void> filter(WidgetTester tester, String key) async {
    await tapKey(tester, key);
  }

  group('лента операций', () {
    testWidgets('все операции, счётчик, знак «+» у дохода; перевод серым', (
      tester,
    ) async {
      await pump(tester);
      expect(_textOf(tester, 'tx-count'), '9 операций');
      expect(find.text('Пятёрочка'), findsOneWidget);
      expect(find.text('Работодатель'), findsOneWidget);
      expect(find.text('+${nb('85 000 ₽')}'), findsOneWidget);
      expect(find.text('-${nb('4 249,90 ₽')}'), findsOneWidget);
      expect(find.text('Т-Банк → ВТБ'), findsOneWidget);
      // Черновик помечен, сумма зачёркнута.
      expect(find.text('ЧЕРНОВИК'), findsOneWidget);
    });

    testWidgets('фильтры по виду: расходы, доходы, переводы, «Все»', (
      tester,
    ) async {
      await pump(tester);
      await filter(tester, 'tx-filter-expense');
      expect(_textOf(tester, 'tx-count'), '7 операций');
      await filter(tester, 'tx-filter-income');
      expect(_textOf(tester, 'tx-count'), '1 операция');
      await filter(tester, 'tx-filter-transfer');
      expect(_textOf(tester, 'tx-count'), '1 операция');
      expect(find.text('Т-Банк → ВТБ'), findsOneWidget);
      await filter(tester, 'tx-filter-all');
      expect(_textOf(tester, 'tx-count'), '9 операций');
    });

    testWidgets('фильтры по месяцу и счёту', (tester) async {
      await pump(tester);
      await filter(tester, 'tx-filter-month-2026-09');
      expect(_textOf(tester, 'tx-count'), '8 операций');
      await filter(tester, 'tx-filter-month-2026-08');
      expect(_textOf(tester, 'tx-count'), '1 операция');
      await filter(tester, 'tx-filter-month-all');
      await filter(tester, 'tx-filter-account-${demo.savings}');
      // Входящий перевод попадает в ленту счёта-получателя, со знаком «+».
      expect(_textOf(tester, 'tx-count'), '1 операция');
      expect(find.text('+${nb('5 000 ₽')}'), findsOneWidget);
      await filter(tester, 'tx-filter-account-${demo.cash}');
      expect(_textOf(tester, 'tx-count'), '1 операция');
      await filter(tester, 'tx-filter-account-all');
      expect(_textOf(tester, 'tx-count'), '9 операций');
    });

    testWidgets('фильтр по категории верхнего уровня включает '
        'подкатегории', (tester) async {
      await pump(tester);
      await filter(tester, 'tx-filter-category');
      await tester.tap(find.byKey(Key('category-pick-${transportId()}')));
      await tester.pumpAndSettle();
      // Такси — подкатегория «Транспорта».
      expect(_textOf(tester, 'tx-count'), '1 операция');
      expect(find.text('Яндекс Go'), findsOneWidget);
      // Повторное касание сбрасывает категорию.
      await filter(tester, 'tx-filter-category');
      expect(_textOf(tester, 'tx-count'), '9 операций');
    });

    testWidgets('поиск без учёта регистра; ничего не найдено', (tester) async {
      await pump(tester);
      await tester.enterText(find.byKey(const Key('tx-search')), 'ЛЕНТА');
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'tx-count'), '2 операции');
      await tester.enterText(find.byKey(const Key('tx-search')), 'пятёр');
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'tx-count'), '1 операция');
      await tester.enterText(find.byKey(const Key('tx-search')), 'нет такого');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-empty-filter')), findsOneWidget);
    });

    testWidgets('«Требуют проверки»: только неподтверждённые', (tester) async {
      await pump(tester);
      await filter(tester, 'tx-filter-unconfirmed');
      expect(_textOf(tester, 'tx-count'), '1 операция');
      expect(find.text('Черновик из уведомления'), findsOneWidget);
      await filter(tester, 'tx-filter-unconfirmed');
      expect(_textOf(tester, 'tx-count'), '9 операций');
    });

    testWidgets('«Сбросить фильтры» очищает всё, включая поиск; вход из '
        'обзора — с чистой ленты', (tester) async {
      final container = await pump(tester, location: '/finance');
      // Фильтр, оставшийся с прошлого раза, при входе из обзора сбрасывается.
      container
          .read(txFilterProvider.notifier)
          .set(const TxFilter(kind: TxKind.income));
      await tapKey(tester, 'finance-link-transactions');
      expect(_textOf(tester, 'tx-count'), '9 операций');
      expect(find.byKey(const Key('tx-filter-reset')), findsNothing);

      await filter(tester, 'tx-filter-expense');
      await tester.enterText(find.byKey(const Key('tx-search')), 'Лента');
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'tx-count'), '2 операции');
      await tapKey(tester, 'tx-filter-reset');
      expect(_textOf(tester, 'tx-count'), '9 операций');
      expect(container.read(txFilterProvider).isEmpty, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
    });

    testWidgets('пагинация: по 50, «Показать ещё»', (tester) async {
      final container = await pump(
        tester,
        more: (c) async {
          final repo = c.read(financeRepositoryProvider);
          for (var i = 0; i < 60; i++) {
            await repo.createTransaction(
              FinTransaction(
                id: repo.newId(),
                kind: TxKind.expense,
                accountId: demo.cash,
                amount: 100 + i,
                occurredAt: msk(2026, 9, 1 + i % 20, 8),
              ),
            );
          }
        },
      );
      expect(_textOf(tester, 'tx-count'), '69 операций');
      expect(find.byKey(const Key('tx-more')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('tx-more')));
      await tester.tap(find.byKey(const Key('tx-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-more')), findsNothing);
      expect(await _txs(tester, container), hasLength(69));
    });

    testWidgets('пусто: подсказка и кнопка', (tester) async {
      await pumpFinance(tester, location: '/finance/transactions');
      expect(find.byKey(const Key('tx-empty')), findsOneWidget);
      await tapKey(tester, 'tx-empty-add');
      // Операции пишутся на счёт: без счетов форма предлагает его добавить.
      expect(find.byKey(const Key('tx-no-accounts')), findsOneWidget);
    });

    testWidgets('«сегодня» и «вчера» в заголовках дней', (tester) async {
      await pump(
        tester,
        more: (c) async {
          final repo = c.read(financeRepositoryProvider);
          await repo.createTransaction(
            FinTransaction(
              id: repo.newId(),
              kind: TxKind.expense,
              accountId: demo.cash,
              amount: 100,
              occurredAt: msk(2026, 9, 30, 9),
              merchant: 'Сегодняшняя',
            ),
          );
          await repo.createTransaction(
            FinTransaction(
              id: repo.newId(),
              kind: TxKind.expense,
              accountId: demo.cash,
              amount: 100,
              occurredAt: msk(2026, 9, 29, 9),
              merchant: 'Вчерашняя',
            ),
          );
        },
      );
      expect(find.text('СЕГОДНЯ'), findsOneWidget);
      expect(find.text('ВЧЕРА'), findsOneWidget);
    });

    testWidgets('десктоп', (tester) async {
      await pump(tester, size: desktopSize);
      expect(_textOf(tester, 'tx-count'), '9 операций');
    });
  });

  group('форма операции: быстрый ввод', () {
    testWidgets('расход: сумма, категория одним касанием, счёт по '
        'умолчанию', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'transactions-add');
      expect(find.text('Новая операция'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('tx-amount')), '1 250,50');
      // Самая частая категория расходов — продукты.
      await tapKey(tester, 'tx-category-${groceriesId()}');
      await tester.enterText(find.byKey(const Key('tx-merchant')), '  Магнит ');
      await tester.enterText(find.byKey(const Key('tx-comment')), 'чек');
      await tapKey(tester, 'tx-save');

      final created = (await _txs(
        tester,
        container,
      )).firstWhere((t) => t.merchant == 'Магнит');
      expect(created.kind, TxKind.expense);
      expect(created.amount, 125050);
      expect(created.categoryId, groceriesId());
      expect(created.status, TxStatus.confirmed);
      expect(created.source, TxSource.manual);
      // Счёт последней операции — Т-Банк; «сегодня» — момент «сейчас».
      expect(created.accountId, demo.bank);
      expect(created.occurredAt, DateTime.utc(2026, 9, 30, 8, 40));
      expect(created.comment, 'чек');
      final data = container.read(financeDataProvider).requireValue;
      expect(data.balanceOf(demo.bank), 17400000 - 125050);
      expect(_textOf(tester, 'tx-count'), '10 операций');
    });

    testWidgets('доход на выбранный счёт', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'transactions-add');
      await tapKey(tester, 'tx-kind-income');
      await tester.enterText(find.byKey(const Key('tx-amount')), '10 000');
      await tapKey(tester, 'tx-account-${demo.cash}');
      await tapKey(tester, 'tx-category-${salaryCategoryId()}');
      await tapKey(tester, 'tx-save');
      final created = (await _txs(
        tester,
        container,
      )).firstWhere((t) => t.accountId == demo.cash && t.kind == TxKind.income);
      expect(created.amount, 1000000);
      expect(created.categoryId, salaryCategoryId());
      final data = container.read(financeDataProvider).requireValue;
      expect(data.balanceOf(demo.cash), 5400000 + 1000000);
    });

    testWidgets('перевод: одна запись, без категории; обязателен счёт «куда»', (
      tester,
    ) async {
      final container = await pump(tester);
      await tapKey(tester, 'transactions-add');
      await tapKey(tester, 'tx-kind-transfer');
      expect(find.byKey(const Key('tx-category-pick')), findsNothing);
      expect(find.byKey(const Key('tx-merchant')), findsNothing);
      await tester.enterText(find.byKey(const Key('tx-amount')), '2 000');
      await tapKey(tester, 'tx-save');
      expect(find.text('Укажите счёт, куда переводите'), findsOneWidget);
      // «Откуда» нельзя выбрать «куда».
      await tapKey(tester, 'tx-account-${demo.cash}');
      expect(find.byKey(Key('tx-to-account-${demo.cash}')), findsNothing);
      await tapKey(tester, 'tx-to-account-${demo.savings}');
      await tapKey(tester, 'tx-save');
      final transfers = [
        for (final t in await _txs(tester, container))
          if (t.kind == TxKind.transfer) t,
      ];
      expect(transfers, hasLength(2));
      final mine = transfers.firstWhere((t) => t.amount == 200000);
      expect(mine.accountId, demo.cash);
      expect(mine.toAccountId, demo.savings);
      expect(mine.categoryId, isNull);
      final data = container.read(financeDataProvider).requireValue;
      // Общий баланс не изменился: перевод между своими счетами.
      expect(data.balances.total, 36100000);
      expect(data.balanceOf(demo.cash), 5400000 - 200000);
      expect(data.balanceOf(demo.savings), 800000 + 200000);
      // В «расход» и «доход» месяца перевод не попал.
      final month = monthlyTotals(data.transactions);
      expect(month.last.expense, 1150000);
    });

    testWidgets('ошибки: нет суммы, мусор в сумме', (tester) async {
      await pump(tester);
      await tapKey(tester, 'transactions-add');
      await tapKey(tester, 'tx-save');
      expect(find.text('Укажите сумму'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('tx-amount')), '1.2.3');
      await tapKey(tester, 'tx-save');
      expect(find.textContaining('введите сумму'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('tx-amount')), '0');
      await tapKey(tester, 'tx-save');
      expect(find.text('Укажите сумму'), findsOneWidget);
    });

    testWidgets('категория из дерева: подкатегория показывается с родителем; '
        '«без категории»', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'transactions-add');
      await tester.enterText(find.byKey(const Key('tx-amount')), '300');
      await tapKey(tester, 'tx-category-pick');
      await tester.tap(find.byKey(Key('category-pick-${taxiId()}')));
      await tester.pumpAndSettle();
      expect(find.text('Транспорт › Такси'), findsOneWidget);
      // Повторно: «Без категории».
      await tapKey(tester, 'tx-category-pick');
      await tester.tap(find.byKey(const Key('category-pick-none')));
      await tester.pumpAndSettle();
      expect(find.text('Без категории'), findsOneWidget);
      // Выбрав таксю и сохранив, категория запоминается.
      await tapKey(tester, 'tx-category-pick');
      await tester.tap(find.byKey(Key('category-pick-${taxiId()}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'tx-save');
      final created = (await _txs(
        tester,
        container,
      )).firstWhere((t) => t.amount == 30000);
      expect(created.categoryId, taxiId());
    });

    testWidgets('переключение вида сбрасывает категорию', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'transactions-add');
      await tester.enterText(find.byKey(const Key('tx-amount')), '300');
      await tapKey(tester, 'tx-category-${groceriesId()}');
      await tapKey(tester, 'tx-kind-income');
      await tapKey(tester, 'tx-save');
      final created = (await _txs(
        tester,
        container,
      )).firstWhere((t) => t.amount == 30000);
      expect(created.kind, TxKind.income);
      expect(created.categoryId, isNull);
    });

    testWidgets('другой день — полдень по Москве', (tester) async {
      final container = await pump(tester);
      await tapKey(tester, 'transactions-add');
      await tester.enterText(find.byKey(const Key('tx-amount')), '100');
      await tapKey(tester, 'tx-date-tomorrow');
      await tapKey(tester, 'tx-save');
      final created = (await _txs(
        tester,
        container,
      )).firstWhere((t) => t.amount == 10000);
      expect(created.occurredAt, DateTime.utc(2026, 10, 1, 9));
      expect(moscowDay(created.occurredAt), '2026-10-01');
    });

    testWidgets('нет счетов: подсказка вместо формы', (tester) async {
      await pumpFinance(tester, location: '/finance/transactions');
      await tapKey(tester, 'transactions-add');
      expect(find.byKey(const Key('tx-no-accounts')), findsOneWidget);
      expect(find.byKey(const Key('finance-add-account')), findsOneWidget);
    });

    testWidgets('«задним числом» раньше последней сверки — предупреждение', (
      tester,
    ) async {
      final container = await pump(
        tester,
        more: (c) async {
          await c
              .read(financeRepositoryProvider)
              .reconcile(
                accountId: demo.bank,
                actualBalance: 17400000,
                checkedAt: msk(2026, 9, 25),
              );
        },
      );
      await tapKey(tester, 'transactions-add');
      // Сегодня позже сверки — предупреждения нет.
      expect(find.byKey(const Key('tx-backdated')), findsNothing);
      await tester.tap(find.byKey(const Key('tx-date-pick')));
      await tester.pumpAndSettle();
      // Выбор в календаре: 10 сентября.
      await tester.tap(find.text('10').last);
      await tester.tap(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tx-backdated')), findsOneWidget);
      expect(container.read(financeDataProvider).hasValue, isTrue);
    });
  });

  group('форма операции: правка', () {
    Future<String> idOf(
      WidgetTester tester,
      ProviderContainer c,
      String m,
    ) async => (await _txs(tester, c)).firstWhere((t) => t.merchant == m).id;

    testWidgets('открывается по касанию строки; правка суммы', (tester) async {
      final container = await pump(tester);
      final id = await idOf(tester, container, 'Пятёрочка');
      await tapKey(tester, 'tx-$id');
      expect(find.text('Операция'), findsOneWidget);
      final amount = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('tx-amount')),
          matching: find.byType(TextField),
        ),
      );
      expect(amount.controller!.text, '4249,90');
      await tester.enterText(find.byKey(const Key('tx-amount')), '4 300');
      await tapKey(tester, 'tx-save');
      final tx = (await _txs(tester, container)).firstWhere((t) => t.id == id);
      expect(tx.amount, 430000);
      expect(tx.categoryId, groceriesId());
      // Момент не сдвинулся: дата та же.
      expect(tx.occurredAt, msk(2026, 9, 2, 19));
    });

    testWidgets('удаление с подтверждением пересчитывает баланс', (
      tester,
    ) async {
      final container = await pump(tester);
      final id = await idOf(tester, container, 'Кофемания');
      await tapKey(tester, 'tx-$id');
      await tapKey(tester, 'tx-delete');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tapKey(tester, 'confirm-ok');
      expect(find.byKey(Key('tx-$id')), findsNothing);
      final data = container.read(financeDataProvider).requireValue;
      expect(data.balanceOf(demo.bank), 17400000 + 300000);
    });

    testWidgets('черновик: «Подтвердить» включает его в баланс', (
      tester,
    ) async {
      final container = await pump(tester);
      final id = await idOf(tester, container, 'Черновик из уведомления');
      expect(
        container.read(financeDataProvider).requireValue.balanceOf(demo.bank),
        17400000,
      );
      await tapKey(tester, 'tx-$id');
      await tapKey(tester, 'tx-confirm');
      final tx = (await _txs(tester, container)).firstWhere((t) => t.id == id);
      expect(tx.status, TxStatus.confirmed);
      expect(
        container.read(financeDataProvider).requireValue.balanceOf(demo.bank),
        17400000 - 99900,
      );
    });

    testWidgets('сверка раньше операции: предупреждение при правке старой '
        'операции', (tester) async {
      final container = await pump(
        tester,
        more: (c) async {
          await c
              .read(financeRepositoryProvider)
              .reconcile(
                accountId: demo.bank,
                actualBalance: 17400000,
                checkedAt: msk(2026, 9, 25),
              );
        },
      );
      final id = await idOf(tester, container, 'Пятёрочка');
      await tapKey(tester, 'tx-$id');
      expect(find.byKey(const Key('tx-backdated')), findsOneWidget);
    });

    testWidgets('несуществующая операция', (tester) async {
      final container = await pump(tester);
      final id = await idOf(tester, container, 'Кофемания');
      await tapKey(tester, 'tx-$id');
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });

    testWidgets('платёж Работы: «деньги пришли на карту» и покрытие', (
      tester,
    ) async {
      final container = await pump(tester);
      final repo = container.read(financeRepositoryProvider);
      final payment = (await tester.runAsync(() async {
        final rows = await container
            .read(syncStoreProvider)
            .visibleRows('payments');
        return rows.first['id']! as String;
      }))!;
      await tester.runAsync(
        () => repo.reflectWorkPayment(
          paymentId: payment,
          accountId: demo.bank,
          amount: 100000,
          occurredAt: msk(2026, 9, 12),
          merchant: 'Рома',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Рома'), findsOneWidget);
      final data = container.read(financeDataProvider).requireValue;
      expect(data.coverageOf(payment)!.linked, 100000);
      expect(
        data.categoryTitle(categoryPresetId('income.projects')),
        'Доход с проектов',
      );
    });
  });
}
