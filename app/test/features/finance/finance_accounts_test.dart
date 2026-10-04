import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/shell/app_router.dart';

import '../../support/finance_env.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

Future<List<Account>> _accounts(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(
  () async => [
    for (final r in await c.read(syncStoreProvider).visibleRows('accounts'))
      Account.fromRow(r),
  ],
))!;

void main() {
  late FinanceDemo demo;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String location = '/finance/accounts',
    Size size = phoneSize,
  }) => pumpFinance(
    tester,
    location: location,
    size: size,
    seedWith: (c) async => demo = await seedFinanceDemo(c),
  );

  group('«Счета»', () {
    testWidgets('общий баланс и карточки счетов с балансами', (tester) async {
      await pump(tester);
      expect(_textOf(tester, 'accounts-total'), nb('361 000 ₽'));
      expect(_textOf(tester, 'balance-${demo.cash}'), nb('54 000 ₽'));
      expect(_textOf(tester, 'balance-${demo.bank}'), nb('174 000 ₽'));
      expect(_textOf(tester, 'balance-${demo.savings}'), nb('8 000 ₽'));
      expect(_textOf(tester, 'balance-${demo.credit}'), nb('125 000 ₽'));
      expect(find.textContaining('•••• 4242'), findsOneWidget);
      expect(find.text('Т-Банк · •••• 4242'), findsOneWidget);
      expect(find.text('Наличные'), findsWidgets);
    });

    testWidgets('десктоп', (tester) async {
      await pump(tester, size: desktopSize);
      expect(_textOf(tester, 'accounts-total'), nb('361 000 ₽'));
    });

    testWidgets('пусто: подсказка и добавление', (tester) async {
      await pumpFinance(tester, location: '/finance/accounts');
      expect(find.byKey(const Key('accounts-empty')), findsOneWidget);
      await tapKey(tester, 'finance-add-account');
      expect(find.byKey(const Key('account-name')), findsOneWidget);
    });

    testWidgets('счёт вне общего баланса помечен и не входит в итог', (
      tester,
    ) async {
      final container = await pump(tester);
      final repo = (await tester.runAsync(
        () async => container.read(syncStoreProvider),
      ))!;
      final row = (await tester.runAsync(() => repo.visibleRows('accounts')))!
          .firstWhere((r) => r['name'] == 'Кредитка');
      await tester.runAsync(
        () => repo.update('accounts', row['id']! as String, {
          'include_in_total': false,
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Не в общем балансе'), findsOneWidget);
      expect(_textOf(tester, 'accounts-total'), nb('236 000 ₽'));
      // Баланс самого счёта виден.
      expect(_textOf(tester, 'balance-${demo.credit}'), nb('125 000 ₽'));
    });

    testWidgets('архив: счёт уходит из списка, но остаётся в общем балансе', (
      tester,
    ) async {
      final container = await pump(tester);
      await tester.tap(find.byKey(Key('account-${demo.cash}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'account-edit');
      await tapKey(tester, 'account-archived');
      // Баланс ненулевой и в общем балансе: предупреждение.
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tapKey(tester, 'confirm-ok');
      await tapKey(tester, 'account-save');
      expect(
        (await _accounts(
          tester,
          container,
        )).firstWhere((a) => a.id == demo.cash).archived,
        isTrue,
      );
      // Назад к списку: наличных нет в «Открытых», есть в архиве.
      container.read(routerProvider).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(Key('account-${demo.cash}')), findsNothing);
      expect(_textOf(tester, 'accounts-total'), nb('361 000 ₽'));
      await tapKey(tester, 'accounts-filter-archive');
      expect(find.byKey(Key('account-${demo.cash}')), findsOneWidget);
      await tapKey(tester, 'accounts-filter-open');
      expect(find.byKey(Key('account-${demo.cash}')), findsNothing);
    });
  });

  group('форма счёта', () {
    testWidgets('кредитка: последние цифры, отрицательный остаток, лимит', (
      tester,
    ) async {
      final container = await pumpFinance(
        tester,
        location: '/finance/accounts',
      );
      await tapKey(tester, 'accounts-add');
      await tester.enterText(find.byKey(const Key('account-name')), 'Альфа');
      await tapKey(tester, 'account-kind-credit_card');
      await tester.enterText(
        find.byKey(const Key('account-bank')),
        'Альфа-Банк',
      );
      await tester.enterText(find.byKey(const Key('account-last4')), '9876');
      await tester.enterText(
        find.byKey(const Key('account-opening')),
        '-5 000,50',
      );
      await tester.enterText(find.byKey(const Key('account-limit')), '300 000');
      await tapKey(tester, 'account-save');
      final account = (await _accounts(tester, container)).single;
      expect(account.name, 'Альфа');
      expect(account.kind, AccountKind.creditCard);
      expect(account.cardLast4, '9876');
      expect(account.openingBalance, -500050);
      expect(account.creditLimit, 30000000);
      expect(account.openingDate, '2026-09-30');
      expect(account.includeInTotal, isTrue);
      expect(_textOf(tester, 'balance-${account.id}'), nb('-5 000,50 ₽'));
    });

    testWidgets('ошибки: пустое имя, мусорная сумма, неверный лимит', (
      tester,
    ) async {
      await pumpFinance(tester, location: '/finance/accounts');
      await tapKey(tester, 'accounts-add');
      await tapKey(tester, 'account-save');
      expect(find.byKey(const Key('account-error')), findsOneWidget);
      expect(find.textContaining('не может быть пустым'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('account-name')), 'Нал');
      await tester.enterText(find.byKey(const Key('account-opening')), '1.2.3');
      await tapKey(tester, 'account-save');
      expect(find.textContaining('введите сумму'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('account-opening')), '100');
      await tapKey(tester, 'account-kind-credit_card');
      await tester.enterText(find.byKey(const Key('account-limit')), '-5');
      await tapKey(tester, 'account-save');
      expect(
        find.text('Кредитный лимит: введите сумму, например 300 000'),
        findsOneWidget,
      );
    });

    testWidgets('смена вида на «наличные» убирает поля карты', (tester) async {
      await pumpFinance(tester, location: '/finance/accounts');
      await tapKey(tester, 'accounts-add');
      expect(find.byKey(const Key('account-last4')), findsOneWidget);
      await tapKey(tester, 'account-kind-cash');
      expect(find.byKey(const Key('account-last4')), findsNothing);
      expect(find.byKey(const Key('account-limit')), findsNothing);
    });

    testWidgets('правка и удаление со всей историей', (tester) async {
      final container = await pump(tester);
      await tester.tap(find.byKey(Key('account-${demo.savings}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'account-edit');
      await tester.enterText(
        find.byKey(const Key('account-name')),
        'Накопительный',
      );
      await tapKey(tester, 'account-save');
      expect(find.text('Накопительный'), findsWidgets);
      expect(
        (await _accounts(
          tester,
          container,
        )).firstWhere((a) => a.id == demo.savings).name,
        'Накопительный',
      );

      await tapKey(tester, 'account-edit');
      await tapKey(tester, 'account-delete');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(
        find.textContaining('вместе со всеми его операциями'),
        findsOneWidget,
      );
      await tapKey(tester, 'confirm-ok');
      expect(find.byKey(const Key('account-missing')), findsOneWidget);
      expect(
        (await _accounts(tester, container)).map((a) => a.id),
        isNot(contains(demo.savings)),
      );
    });

    testWidgets('несуществующий счёт: понятное сообщение', (tester) async {
      await pump(tester, location: '/finance/accounts/нет-такого');
      expect(find.byKey(const Key('account-missing')), findsOneWidget);
    });

    testWidgets('форма несуществующего счёта', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(Key('account-${demo.cash}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'account-edit');
      expect(find.byKey(const Key('account-name')), findsOneWidget);
    });
  });

  group('карточка счёта и сверка', () {
    testWidgets('баланс, операции счёта (в том числе входящие переводы)', (
      tester,
    ) async {
      final container = await pump(tester);
      await goTo(tester, container, '/finance/accounts/${demo.savings}');
      expect(_textOf(tester, 'account-balance'), nb('8 000 ₽'));
      // Входящий перевод 5 000 с Т-Банка показан со знаком «+».
      expect(find.textContaining('Перевод'), findsWidgets);
      expect(find.text('Т-Банк → ВТБ'), findsOneWidget);
      expect(find.text('+${nb('5 000 ₽')}'), findsOneWidget);
    });

    testWidgets(
      'сверка: расхождение, корректировка, баланс; доход не меняется',
      (tester) async {
        final container = await pump(tester);
        await tester.tap(find.byKey(Key('account-${demo.bank}')));
        await tester.pumpAndSettle();
        expect(_textOf(tester, 'account-balance'), nb('174 000 ₽'));

        await tapKey(tester, 'account-reconcile');
        expect(find.byKey(const Key('reconcile-actual')), findsOneWidget);
        expect(
          _textOf(tester, 'reconcile-expected'),
          'По нашим данным: ${nb('174 000 ₽')}',
        );
        await tester.enterText(
          find.byKey(const Key('reconcile-actual')),
          '174 800',
        );
        await tester.pumpAndSettle();
        expect(
          _textOf(tester, 'reconcile-gap'),
          'Корректировка: +${nb('800 ₽')} (в банке больше)',
        );
        await tester.enterText(
          find.byKey(const Key('reconcile-actual')),
          '173 000',
        );
        await tester.pumpAndSettle();
        expect(
          _textOf(tester, 'reconcile-gap'),
          'Корректировка: -${nb('1 000 ₽')} (в банке меньше)',
        );
        await tester.enterText(
          find.byKey(const Key('reconcile-actual')),
          '174 000',
        );
        await tester.pumpAndSettle();
        expect(_textOf(tester, 'reconcile-gap'), 'Расхождения нет');

        await tester.enterText(
          find.byKey(const Key('reconcile-actual')),
          '174 800',
        );
        await tapKey(tester, 'reconcile-save');
        expect(_textOf(tester, 'account-balance'), nb('174 800 ₽'));
        expect(find.text('корректировка', skipOffstage: false), findsNothing);
        expect(find.textContaining('корректировка'), findsOneWidget);
        // Операций не прибавилось, доход месяца не изменился.
        final data = container.read(financeDataProvider).requireValue;
        expect(data.checkpoints, hasLength(1));
        expect(
          data.adjustmentsOf(data.accountById[demo.bank]!).single.adjustment,
          80000,
        );
        expect(
          data.transactions.where((t) => t.accountId == demo.bank),
          hasLength(8),
        );

        // Удаление сверки возвращает расчётный баланс.
        await tapKey(tester, 'checkpoint-delete-${data.checkpoints.single.id}');
        expect(_textOf(tester, 'account-balance'), nb('174 000 ₽'));
      },
    );

    testWidgets('сверка: пустое значение — ошибка, неверная сумма — ошибка', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(Key('account-${demo.bank}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'account-reconcile');
      await tapKey(tester, 'reconcile-save');
      expect(find.text('Укажите баланс из банка'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('reconcile-actual')),
        '1.2.3',
      );
      await tapKey(tester, 'reconcile-save');
      expect(find.textContaining('введите сумму'), findsOneWidget);
    });

    testWidgets('кнопка «Операция» на карточке счёта подставляет счёт', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(Key('account-${demo.savings}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'account-add-tx');
      final chip = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byKey(Key('tx-account-${demo.savings}')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(chip.properties.selected, isTrue);
    });
  });
}
