import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/presentation/debt_editor.dart';
import 'package:my_tasker/features/finance/presentation/repayment_sheet.dart';

import '../../support/finance_ui_env.dart';
import '../../support/pump_app.dart';
import '../../support/ui_helpers.dart';

const _nb = ' ';

String _rub(int rubles) {
  final s = rubles.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(_nb);
    out.write(s[i]);
  }
  return '$out$_nb₽';
}

/// Экран «Долги» с демо-долгами (и, если [withAccounts], демо-счетами).
Future<(ProviderContainer, DebtsDemo, FinanceDemo?)> _open(
  WidgetTester tester, {
  String location = '/finance/debts',
  Size size = phoneSize,
  bool withAccounts = false,
  List<Override> overrides = const [],
}) async {
  late DebtsDemo debts;
  FinanceDemo? accounts;
  final c = await pumpFinance(
    tester,
    size: size,
    overrides: overrides,
    seedWith: (c) async {
      if (withAccounts) accounts = await seedFinanceDemo(c);
      debts = await seedDebtsDemo(c);
    },
  );
  if (location != '/finance') await goTo(tester, location);
  await settleDb(tester);
  return (c, debts, accounts);
}

/// Выполняет работу с БД в реальном времени и даёт потокам интерфейса
/// обновиться: запрос, начатый при незавершённом обновлении потока, иначе
/// ждал бы кадров теста.
Future<T> _db<T>(WidgetTester tester, Future<T> Function() action) async {
  final result = await tester.runAsync(action);
  await settleDb(tester);
  return result as T;
}

void main() {
  group('Долги: список', () {
    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        location: '/finance/debts',
        overrides: [debtRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
      expect(find.byKey(const Key('debts-list')), findsNothing);
    });

    testWidgets('пусто: «Никто ничего не должен» и «Добавить долг»', (
      tester,
    ) async {
      await pumpFinance(tester, location: '/finance/debts');
      expect(find.byKey(const Key('debts-empty')), findsOneWidget);
      expect(find.text('Никто ничего не должен'), findsOneWidget);
      await tester.tap(find.byKey(const Key('debts-empty-add')));
      await tester.pumpAndSettle();
      expect(find.text('Новый долг'), findsOneWidget);
      expect(find.byKey(const Key('debt-who')), findsOneWidget);
    });

    testWidgets('данные: итоги, остатки, статусы и просрочка', (tester) async {
      final (_, demo, _) = await _open(tester);
      expect(textOf(tester, 'debts-total-owed_to_me'), _rub(12500));
      expect(textOf(tester, 'debts-total-i_owe'), _rub(15000));
      expect(textOf(tester, 'debt-amount-${demo.emir}'), _rub(7500));
      expect(textOf(tester, 'debt-amount-${demo.nastya}'), _rub(2000));
      expect(textOf(tester, 'debt-status-${demo.emir}'), 'Открыт');
      expect(textOf(tester, 'debt-status-${demo.nastya}'), 'Частично');
      expect(find.text('Вернули ${_rub(600)} из ${_rub(2600)}'), findsOne);
      // Эмир просрочен на 10 дней (срок 20 сентября, сегодня 30-е).
      expect(find.byKey(Key('debt-overdue-${demo.emir}')), findsOneWidget);
      expect(find.text('Просрочен на 10 дней'), findsOneWidget);
      expect(find.byKey(Key('debt-overdue-${demo.bender}')), findsNothing);
      // Закрытый долг скрыт под раскрывашкой.
      expect(find.byKey(Key('debt-row-${demo.timur}')), findsNothing);
      await tapKey(tester, 'debts-closed-toggle-owed_to_me');
      expect(find.byKey(Key('debt-row-${demo.timur}')), findsOneWidget);
      expect(textOf(tester, 'debt-status-${demo.timur}'), 'Закрыт');
      // Самый большой остаток выше.
      final emirTop = tester.getTopLeft(
        find.byKey(Key('debt-row-${demo.emir}')),
      );
      final benderTop = tester.getTopLeft(
        find.byKey(Key('debt-row-${demo.bender}')),
      );
      expect(emirTop.dy, lessThan(benderTop.dy));
    });

    testWidgets('в секции без долгов — подсказка', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/debts',
        seedWith: (c) => addDebt(c, who: 'Эмир', amount: 100000),
      );
      expect(find.byKey(const Key('debts-none-i_owe')), findsOneWidget);
      expect(find.text('Ты никому не должен.'), findsOneWidget);
      expect(textOf(tester, 'debts-total-i_owe'), '0$_nb₽');
    });

    testWidgets('десктоп: секции рядом', (tester) async {
      await _open(tester, size: desktopSize);
      final left = tester.getTopLeft(
        find.byKey(const Key('debts-section-owed_to_me')),
      );
      final right = tester.getTopLeft(
        find.byKey(const Key('debts-section-i_owe')),
      );
      expect(right.dx, greaterThan(left.dx + 300));
      expect(right.dy, left.dy);
    });

    testWidgets('ошибка чтения: плашка и «Повторить»', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/debts',
        overrides: [
          repaymentRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('finance-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('офлайн: плашка, данные работают', (tester) async {
      final (_, demo, _) = await _open(
        tester,
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
      expect(find.byKey(Key('debt-row-${demo.emir}')), findsOneWidget);
    });

    testWidgets(
      'вход из «Финансы» и обратно; тап по строке открывает карточку',
      (tester) async {
        final (_, demo, _) = await _open(tester, location: '/finance');
        await tapKey(tester, 'finance-open-debts');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('debts-list')), findsOneWidget);
        await tester.tap(find.byKey(Key('debt-row-${demo.bender}')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('debt-remaining')), findsOneWidget);
        await tester.tap(find.byTooltip('Назад'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('debts-list')), findsOneWidget);
        await tester.tap(find.byTooltip('Назад'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('finance-open-debts')), findsOneWidget);
      },
    );

    testWidgets('«+» в шапке открывает редактор нового долга', (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const Key('debts-add')));
      await tester.pumpAndSettle();
      expect(find.text('Новый долг'), findsOneWidget);
    });
  });

  group('Долг: карточка', () {
    testWidgets('данные: остаток, прогресс, статус, срок, история', (
      tester,
    ) async {
      final (c, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.nastya}');
      await settleDb(tester);
      expect(textOf(tester, 'debt-remaining'), _rub(2000));
      expect(
        textOf(tester, 'debt-repaid-line'),
        'Вернули ${_rub(600)} из ${_rub(2600)}',
      );
      expect(find.text('ЧАСТИЧНО'), findsOneWidget);
      expect(find.byKey(const Key('debt-progress-fill')), findsOneWidget);
      expect(find.byKey(const Key('debt-overdue')), findsNothing);
      expect(find.byKey(const Key('debt-history')), findsOneWidget);
      expect(find.text('28 сент. · без движения денег'), findsOneWidget);
      expect(find.text(_rub(600)), findsWidgets);
      expect(find.text('Погашений пока нет.'), findsNothing);
      expect(c, isNotNull);
    });

    testWidgets('просроченный долг: слово и иконка, срок', (tester) async {
      final (_, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.emir}');
      await settleDb(tester);
      expect(find.byKey(const Key('debt-overdue')), findsOneWidget);
      expect(find.text('Просрочен на 10 дней'), findsOneWidget);
      expect(textOf(tester, 'debt-due-line'), 'Срок возврата: 20 сент.');
      expect(textOf(tester, 'debt-date-line'), 'Дата долга: 27 авг.');
      expect(find.text('ОТКРЫТ'), findsOneWidget);
      expect(find.byKey(const Key('debt-no-repayments')), findsOneWidget);
    });

    testWidgets('«Я должен»: подпись направления и «Я вернул»', (tester) async {
      final (_, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.vlad}');
      await settleDb(tester);
      expect(textOf(tester, 'debt-direction-label'), 'Я должен');
      await tapKey(tester, 'debt-repay');
      expect(find.text('Я вернул'), findsOneWidget);
    });

    testWidgets('закрытый долг: нет «Закрыть остаток», остаток 0', (
      tester,
    ) async {
      final (_, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.timur}');
      await settleDb(tester);
      expect(textOf(tester, 'debt-remaining'), '0$_nb₽');
      expect(find.text('ЗАКРЫТ'), findsOneWidget);
      expect(find.byKey(const Key('debt-close-rest')), findsNothing);
    });

    testWidgets('переплата показана словом', (tester) async {
      final (c, demo, _) = await _open(tester);
      await _db(
        tester,
        () => addRepaymentTo(c, debt: demo.timur, amount: 50000),
      );
      await goTo(tester, '/finance/debts/${demo.timur}');
      await settleDb(tester);
      expect(
        textOf(tester, 'debt-overpaid'),
        'Переплата ${_rub(500)}: погашений больше суммы долга.',
      );
    });

    testWidgets('нет такого долга: «Долг не найден»', (tester) async {
      await _open(tester, location: '/finance/debts/нет-такого');
      expect(find.byKey(const Key('debt-missing')), findsOneWidget);
      expect(find.text('Долг не найден'), findsOneWidget);
      await tester.tap(find.text('К долгам'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('debts-list')), findsOneWidget);
    });

    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await pumpFinance(
        tester,
        location: '/finance/debts/x',
        overrides: [repaymentRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    });

    testWidgets('ошибка чтения: плашка', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/debts/x',
        overrides: [
          debtRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('офлайн: плашка', (tester) async {
      final (_, demo, _) = await _open(
        tester,
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
          ),
        ],
      );
      await goTo(tester, '/finance/debts/${demo.emir}');
      await settleDb(tester);
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
      expect(find.byKey(const Key('debt-remaining')), findsOneWidget);
    });

    testWidgets('десктоп: карточка по центру', (tester) async {
      final (_, demo, _) = await _open(tester, size: desktopSize);
      await goTo(tester, '/finance/debts/${demo.nastya}');
      await settleDb(tester);
      expect(textOf(tester, 'debt-remaining'), _rub(2000));
    });

    testWidgets('удаление: подтверждение, возврат к списку, «Отменить»', (
      tester,
    ) async {
      final (c, demo, acc) = await _open(tester, withAccounts: true);
      await _db(
        tester,
        () => addRepaymentTo(
          c,
          debt: demo.emir,
          amount: 100000,
          account: acc!.cash,
        ),
      );
      await goTo(tester, '/finance/debts/${demo.emir}');
      await settleDb(tester);
      await tester.tap(find.byKey(const Key('debt-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('debt-menu-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(
        find.textContaining('Операции на счетах (1) останутся'),
        findsOneWidget,
      );
      // отмена — ничего не удалено
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await _db(tester, () => financeRepo(c).debts()), hasLength(5));
      await tester.tap(find.byKey(const Key('debt-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('debt-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
      await settleDb(tester);
      expect(find.byKey(const Key('debts-list')), findsOneWidget);
      expect(find.byKey(Key('debt-row-${demo.emir}')), findsNothing);
      expect(textOf(tester, 'debts-total-owed_to_me'), _rub(5000));
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(find.byKey(Key('debt-row-${demo.emir}')), findsOneWidget);
      expect(textOf(tester, 'debts-total-owed_to_me'), _rub(11500));
    });
  });

  group('Долг: редактор', () {
    testWidgets('создание: все поля сохраняются, контрагент обрезается', (
      tester,
    ) async {
      final c = await pumpFinance(tester, location: '/finance/debts');
      await tester.tap(find.byKey(const Key('debts-empty-add')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'debt-direction-iOwe');
      expect(find.text('Кому должен'), findsOneWidget);
      await enter(tester, 'debt-who', '  Лена ');
      await enter(tester, 'debt-amount', '12 345,5');
      await tapKey(tester, 'debt-due-tomorrow');
      await enter(tester, 'debt-comment', ' на отпуск ');
      await tapKey(tester, 'debt-save');
      await settleDb(tester);
      final debts = await _db(tester, () => financeRepo(c).debts());
      final d = debts.single;
      expect(d.direction, DebtDirection.iOwe);
      expect(d.counterparty, 'Лена');
      expect(d.amount, 1234550);
      expect(d.debtDate, '2026-09-30');
      expect(d.dueDate, '2026-10-01');
      expect(d.comment, 'на отпуск');
      expect(d.personId, isNull);
      expect(find.byKey(const Key('debts-list')), findsOneWidget);
      expect(textOf(tester, 'debts-total-i_owe'), '12${_nb}345,50$_nb₽');
    });

    testWidgets('ошибки: нет контрагента, нет суммы, срок раньше даты', (
      tester,
    ) async {
      final c = await pumpFinance(tester, location: '/finance/debts');
      await tester.tap(find.byKey(const Key('debts-empty-add')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'debt-save');
      expect(find.text('Введи сумму больше нуля'), findsOneWidget);
      await enter(tester, 'debt-amount', '100');
      await tapKey(tester, 'debt-save');
      expect(find.byKey(const Key('debt-error')), findsOneWidget);
      expect(find.text('Укажи, кто должен или кому должен ты'), findsOneWidget);
      // срок раньше даты долга
      await enter(tester, 'debt-who', 'Эмир');
      await tapKey(tester, 'debt-date-tomorrow');
      await tapKey(tester, 'debt-due-today');
      await tapKey(tester, 'debt-save');
      expect(find.text('Срок не может быть раньше даты долга'), findsOneWidget);
      expect(await _db(tester, () => financeRepo(c).debts()), isEmpty);
    });

    testWidgets('займ на счёт: выдача — расход со счёта, «расход» месяца '
        'не меняется', (tester) async {
      final (c, _, demo) = await _open(tester, withAccounts: true);
      final before = await _db(tester, () => financeRepo(c).balances());
      await tester.tap(find.byKey(const Key('debts-add')));
      await tester.pumpAndSettle();
      await enter(tester, 'debt-who', 'Паша');
      await enter(tester, 'debt-amount', '5000');
      await tapKey(tester, 'debt-loan');
      expect(find.byKey(const Key('debt-loan-account')), findsOneWidget);
      expect(find.byKey(const Key('debt-loan-note')), findsOneWidget);
      await tapKey(tester, 'debt-loan-account');
      await tapKey(tester, 'pick-account-${demo!.tbank}');
      await tapKey(tester, 'debt-save');
      await settleDb(tester);
      final repo = financeRepo(c);
      final balances = await _db(tester, repo.balances);
      expect(balances.of(demo.tbank), before.of(demo.tbank) - 500000);
      final debt = (await _db(
        tester,
        repo.debts,
      )).firstWhere((d) => d.who == 'Паша');
      final txs = await _db(tester, repo.transactions);
      final loan = txs.singleWhere((t) => t.debtId == debt.id);
      expect(loan.kind, TransactionKind.expense);
      expect(loan.accountId, demo.tbank);
      // выдача займа не входит в расход сентября: итог как был
      final feed = TransactionFeed.of(txs);
      expect(feed.months['2026-09']!.expense, 124990 + 42000 + 131000);
    });

    testWidgets('займ: получение — доход на счёт; без счетов — подсказка', (
      tester,
    ) async {
      final c = await pumpFinance(tester, location: '/finance/debts');
      await tester.tap(find.byKey(const Key('debts-empty-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('debt-loan-no-accounts')), findsOneWidget);
      expect(find.byKey(const Key('debt-loan')), findsNothing);
      expect(c, isNotNull);
    });

    testWidgets('займ «я должен»: подпись и доход', (tester) async {
      final (c, _, demo) = await _open(tester, withAccounts: true);
      await tester.tap(find.byKey(const Key('debts-add')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'debt-direction-iOwe');
      await enter(tester, 'debt-who', 'Банк');
      await enter(tester, 'debt-amount', '3000');
      await tapKey(tester, 'debt-loan');
      expect(find.text('Записать получение займа на счёт'), findsOneWidget);
      await tapKey(tester, 'debt-save');
      await settleDb(tester);
      final txs = await _db(tester, () => financeRepo(c).transactions());
      final loan = txs.firstWhere((t) => t.debtId != null);
      expect(loan.kind, TransactionKind.income);
      expect(loan.accountId, demo!.cash, reason: 'счёт по умолчанию — первый');
    });

    testWidgets('правка: поля подставлены, сохраняется только изменённое', (
      tester,
    ) async {
      final (c, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.emir}');
      await settleDb(tester);
      await tester.tap(find.byKey(const Key('debt-edit')));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'debt-who'), 'Эмир');
      expect(fieldText(tester, 'debt-amount'), '7${_nb}500');
      expect(
        find.byKey(const Key('debt-loan')),
        findsNothing,
        reason: 'займ — только у нового долга',
      );
      await enter(tester, 'debt-amount', '8000');
      await tapKey(tester, 'debt-due-none');
      await tapKey(tester, 'debt-save');
      await settleDb(tester);
      final d = (await _db(tester, () => financeRepo(c).getDebt(demo.emir)))!;
      expect(d.amount, 800000);
      expect(d.dueDate, isNull);
      expect(d.counterparty, 'Эмир');
      expect(textOf(tester, 'debt-remaining'), _rub(8000));
      expect(
        find.byKey(const Key('debt-overdue')),
        findsNothing,
        reason: 'без срока просрочки нет',
      );
    });

    testWidgets('долг пропал на другом устройстве', (tester) async {
      await pumpFinance(tester, location: '/finance/debts');
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(showDebtEditor(context, debtId: 'нет-такого'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('debt-missing')), findsOneWidget);
    });
  });

  group('Погашение', () {
    testWidgets('через счёт: операция-доход с debt_id, баланс растёт, доход '
        'месяца не меняется', (tester) async {
      final (c, demo, acc) = await _open(tester, withAccounts: true);
      final repo = financeRepo(c);
      final before = await _db(tester, repo.balances);
      final monthBefore = TransactionFeed.of(
        await _db(tester, repo.transactions),
      ).months['2026-09']!.income;
      await goTo(tester, '/finance/debts/${demo.emir}');
      await settleDb(tester);
      await tapKey(tester, 'debt-repay');
      expect(textOf(tester, 'repay-context'), 'Эмир · остаток ${_rub(7500)}');
      expect(find.byKey(const Key('repay-account-note')), findsOneWidget);
      await enter(tester, 'repay-amount', '2500');
      await tapKey(tester, 'repay-account');
      await tapKey(tester, 'pick-account-${acc!.tbank}');
      await tapKey(tester, 'repay-note');
      await enter(tester, 'repay-note', 'первая часть');
      await tapKey(tester, 'repay-save');
      await settleDb(tester);

      expect(textOf(tester, 'debt-remaining'), _rub(5000));
      expect(find.text('ЧАСТИЧНО'), findsOneWidget);
      expect(find.textContaining('на счёт «Т-Банк Black»'), findsOneWidget);
      final repayment = (await _db(
        tester,
        () => repo.repayments(debtId: demo.emir),
      )).single;
      final tx = (await _db(
        tester,
        () => repo.getTransaction(repayment.transactionId!),
      ))!;
      expect(tx.kind, TransactionKind.income);
      expect(tx.debtId, demo.emir);
      expect(tx.accountId, acc.tbank);
      expect(tx.comment, 'первая часть');
      final after = await _db(tester, repo.balances);
      expect(after.of(acc.tbank), before.of(acc.tbank) + 250000);
      expect(after.total, before.total + 250000);
      final monthAfter = TransactionFeed.of(
        await _db(tester, repo.transactions),
      ).months['2026-09']!.income;
      expect(monthAfter, monthBefore);
    });

    testWidgets('«Закрыть остаток» подставляет весь остаток и закрывает '
        'долг', (tester) async {
      final (c, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.nastya}');
      await settleDb(tester);
      await tapKey(tester, 'debt-repay');
      await tapKey(tester, 'repay-close');
      expect(fieldText(tester, 'repay-amount'), '2${_nb}000');
      expect(find.byKey(const Key('repay-overpay')), findsNothing);
      // без счетов — «без движения денег»
      expect(find.byKey(const Key('repay-none-note')), findsOneWidget);
      expect(find.text('Списать без движения денег'), findsWidgets);
      await tapKey(tester, 'repay-save');
      await settleDb(tester);
      expect(textOf(tester, 'debt-remaining'), '0$_nb₽');
      expect(find.text('ЗАКРЫТ'), findsOneWidget);
      expect(find.byKey(const Key('debt-close-rest')), findsNothing);
      final s = (await _db(
        tester,
        () => financeRepo(c).debtState(demo.nastya),
      ))!;
      expect(s.status, DebtStatus.closed);
    });

    testWidgets('кнопка «Закрыть остаток» на карточке открывает лист с '
        'суммой', (tester) async {
      final (_, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.nastya}');
      await settleDb(tester);
      await tapKey(tester, 'debt-close-rest');
      expect(fieldText(tester, 'repay-amount'), '2${_nb}000');
    });

    testWidgets('«Списать без движения денег»: погашение без операции', (
      tester,
    ) async {
      final (c, demo, _) = await _open(tester, withAccounts: true);
      final repo = financeRepo(c);
      final before = await _db(tester, repo.balances);
      final countBefore = (await _db(tester, repo.transactions)).length;
      await goTo(tester, '/finance/debts/${demo.bender}');
      await settleDb(tester);
      await tapKey(tester, 'debt-repay');
      await tapKey(tester, 'repay-move-none');
      expect(find.byKey(const Key('repay-account')), findsNothing);
      expect(find.byKey(const Key('repay-none-note')), findsOneWidget);
      await enter(tester, 'repay-amount', '3000');
      await tapKey(tester, 'repay-save');
      await settleDb(tester);
      final r = (await _db(
        tester,
        () => repo.repayments(debtId: demo.bender),
      )).single;
      expect(r.transactionId, isNull);
      expect((await _db(tester, repo.transactions)).length, countBefore);
      expect((await _db(tester, repo.balances)).total, before.total);
      expect(find.text('ЗАКРЫТ'), findsOneWidget);
      expect(find.textContaining('без движения денег'), findsOneWidget);
    });

    testWidgets('«я вернул» со счёта: операция-расход, расход месяца не '
        'меняется', (tester) async {
      final (c, demo, acc) = await _open(tester, withAccounts: true);
      final repo = financeRepo(c);
      final monthBefore = TransactionFeed.of(
        await _db(tester, repo.transactions),
      ).months['2026-09']!.expense;
      await goTo(tester, '/finance/debts/${demo.vlad}');
      await settleDb(tester);
      await tapKey(tester, 'debt-repay');
      await enter(tester, 'repay-amount', '1000');
      await tapKey(tester, 'repay-save');
      await settleDb(tester);
      final r = (await _db(
        tester,
        () => repo.repayments(debtId: demo.vlad),
      )).single;
      final tx = (await _db(
        tester,
        () => repo.getTransaction(r.transactionId!),
      ))!;
      expect(tx.kind, TransactionKind.expense);
      expect(tx.accountId, acc!.cash);
      final month = TransactionFeed.of(await _db(tester, repo.transactions))
          .months['2026-09']!
          .expense;
      expect(month, monthBefore);
      expect(textOf(tester, 'debt-remaining'), _rub(14000));
    });

    testWidgets('больше остатка: предупреждение, но сохранить можно', (
      tester,
    ) async {
      final (c, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.nastya}');
      await settleDb(tester);
      await tapKey(tester, 'debt-repay');
      await enter(tester, 'repay-amount', '2500');
      expect(find.byKey(const Key('repay-overpay')), findsOneWidget);
      expect(find.textContaining('переплата ${_rub(500)}'), findsOneWidget);
      await tapKey(tester, 'repay-save');
      await settleDb(tester);
      expect(
        textOf(tester, 'debt-overpaid'),
        'Переплата ${_rub(500)}: погашений больше суммы долга.',
      );
      final s = (await _db(
        tester,
        () => financeRepo(c).debtState(demo.nastya),
      ))!;
      expect(s.overpaid, 50000);
    });

    testWidgets('ошибка: пустая сумма', (tester) async {
      final (_, demo, _) = await _open(tester);
      await goTo(tester, '/finance/debts/${demo.nastya}');
      await settleDb(tester);
      await tapKey(tester, 'debt-repay');
      await tapKey(tester, 'repay-save');
      expect(find.byKey(const Key('repay-error')), findsOneWidget);
      expect(find.text('Введи сумму больше нуля'), findsOneWidget);
    });

    testWidgets('правка: сумма, привязанная операция следует; удаление с '
        'подтверждением и «Отменить»', (tester) async {
      final (c, demo, acc) = await _open(tester, withAccounts: true);
      final repo = financeRepo(c);
      final id = await _db(
        tester,
        () => addRepaymentTo(
          c,
          debt: demo.emir,
          amount: 100000,
          account: acc!.tbank,
          on: '2026-09-29',
        ),
      );
      final balance0 = (await _db(tester, repo.balances)).of(acc!.tbank);
      await goTo(tester, '/finance/debts/${demo.emir}');
      await settleDb(tester);
      await tapKey(tester, 'repayment-row-$id');
      expect(fieldText(tester, 'repay-amount'), '1${_nb}000');
      expect(find.byKey(const Key('repay-move-none')), findsNothing);
      expect(
        textOf(tester, 'repay-linked-note'),
        'Операция на счёте «Т-Банк Black» изменится вместе с погашением.',
      );
      await enter(tester, 'repay-amount', '1500');
      await tapKey(tester, 'repay-save');
      await settleDb(tester);
      expect(textOf(tester, 'debt-remaining'), _rub(6000));
      final after = (await _db(tester, repo.balances)).of(acc.tbank);
      expect(after, balance0 + 50000);

      await tapKey(tester, 'repayment-row-$id');
      await tapKey(tester, 'repay-delete');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(
        find.textContaining('Операция на счёте останется'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
      await settleDb(tester);
      expect(textOf(tester, 'debt-remaining'), _rub(7500));
      expect(find.byKey(const Key('debt-no-repayments')), findsOneWidget);
      // операция осталась: баланс счёта не вернулся
      expect((await _db(tester, repo.balances)).of(acc.tbank), after);
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(textOf(tester, 'debt-remaining'), _rub(6000));
    });

    testWidgets('правка погашения без операции', (tester) async {
      final (c, demo, _) = await _open(tester);
      final id = (await _db(
        tester,
        () => financeRepo(c).repayments(debtId: demo.nastya),
      )).single.id;
      await goTo(tester, '/finance/debts/${demo.nastya}');
      await settleDb(tester);
      await tapKey(tester, 'repayment-row-$id');
      expect(
        textOf(tester, 'repay-linked-note'),
        'Без движения денег: операции на счёте нет.',
      );
    });

    testWidgets('погашение или долг пропали', (tester) async {
      final (_, demo, _) = await _open(tester);
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(
        showRepaymentSheet(context, debtId: demo.nastya, repaymentId: 'нет'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('repay-missing')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      unawaited(showRepaymentSheet(context, debtId: 'нет-долга'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('repay-debt-missing')), findsOneWidget);
    });
  });

  group('Корзина', () {
    testWidgets('долг уходит один, без погашений; восстановление возвращает '
        'долг с погашениями; погашение — отдельной строкой', (tester) async {
      final (c, demo, _) = await _open(tester);
      final repo = financeRepo(c);
      final repaymentId = (await _db(
        tester,
        () => repo.repayments(debtId: demo.nastya),
      )).single.id;
      final timurRepayment = (await _db(
        tester,
        () => repo.repayments(debtId: demo.timur),
      )).single.id;
      await _db(tester, () => repo.deleteDebt(demo.nastya));
      await _db(tester, () => repo.deleteRepayment(timurRepayment));
      await goTo(tester, '/settings/trash');
      await settleDb(tester);
      expect(find.byKey(const Key('trash-list')), findsOneWidget);
      expect(find.text('Мне должны: Настя, ${_rub(2600)}'), findsOneWidget);
      expect(find.textContaining('Долг · удалено'), findsOneWidget);
      expect(find.textContaining('Погашение долга · удалено'), findsOneWidget);
      // погашения удалённого долга отдельной строкой не показываются
      expect(
        find.byKey(Key('trash-debt_repayments-$repaymentId')),
        findsNothing,
      );

      await tester.tap(find.byKey(Key('restore-${demo.nastya}')));
      await settleDb(tester);
      expect(
        await _db(tester, () => repo.repayments(debtId: demo.nastya)),
        hasLength(1),
      );
      expect(
        (await _db(tester, () => repo.debtState(demo.nastya)))!.repaid,
        60000,
      );
      // восстановить погашение Тимура
      await tester.tap(find.byKey(Key('restore-$timurRepayment')));
      await settleDb(tester);
      expect(
        (await _db(tester, () => repo.debtState(demo.timur)))!.isClosed,
        isTrue,
      );
      expect(find.text('Корзина пуста'), findsOneWidget);
    });
  });
}
