import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/banks/data/bank_drafts.dart';
import 'package:my_tasker/features/banks/data/banks_repository.dart';
import 'package:my_tasker/features/banks/data/notification_store.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/domain/notification_engine.dart';
import 'package:my_tasker/features/banks/presentation/bank_reconcile_screen.dart';
import 'package:my_tasker/features/banks/presentation/banks_screen.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_gate.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';

import '../../support/banks_env.dart';

/// Выполняет работу с БД в настоящем async и сразу прогоняет кадры: пока
/// экран подписан на потоки БД, их запросы ждут `pump`, а следующий запрос
/// ждёт их (блокировка исполнителя Drift).
Future<T> _run<T>(WidgetTester tester, Future<T> Function() body) async {
  final result = await tester.runAsync(body);
  await tester.pumpAndSettle();
  return result as T;
}

Future<List<FinTransaction>> _txs(WidgetTester tester, ProviderContainer c) =>
    _run(
      tester,
      () async => [
        for (final r
            in await c.read(syncStoreProvider).visibleRows('transactions'))
          FinTransaction.fromRow(r),
      ],
    );

/// Создаёт операцию банка (по умолчанию черновик из уведомления).
Future<String> _add(
  WidgetTester tester,
  ProviderContainer c,
  String account, {
  int amount = 10000,
  String? merchant,
  TxKind kind = TxKind.expense,
  TxStatus status = TxStatus.draft,
  TxSource source = TxSource.notification,
  DateTime? at,
  String? comment,
  String? category,
}) => _run(tester, () async {
  final repo = c.read(financeRepositoryProvider);
  final id = repo.newId();
  await repo.createTransaction(
    FinTransaction(
      id: id,
      kind: kind,
      accountId: account,
      amount: amount,
      occurredAt: at ?? DateTime.utc(2026, 9, 29, 9),
      merchant: merchant,
      status: status,
      source: source,
      comment: comment,
      categoryId: category,
    ),
  );
  return id;
});

void main() {
  late FinanceDemo demo;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String location = '/finance/banks/drafts',
    Size size = phoneSize,
    FakeBankPlatform? platform,
    Future<void> Function(ProviderContainer c)? more,
  }) => pumpBanks(
    tester,
    location: location,
    size: size,
    platform: platform,
    seedWith: (c) async {
      demo = await seedFinanceDemo(c);
      if (more != null) await more(c);
    },
  );

  group('«Банки»: хаб и переходы', () {
    testWidgets('Android без доступа: подсказка «Нужен доступ» ведёт в '
        'настройку; ссылки со счётчиками', (tester) async {
      final platform = FakeBankPlatform();
      await pump(tester, location: '/finance/banks', platform: platform);
      expect(find.byKey(const Key('banks-needs-access')), findsOneWidget);
      // Один черновик из демо.
      expect(
        find.descendant(
          of: find.byKey(const Key('banks-link-drafts')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'banks-open-setup');
      expect(find.byKey(const Key('bank-setup-screen')), findsOneWidget);
    });

    testWidgets('доступ выдан: подсказки нет, в ссылке «включены»', (
      tester,
    ) async {
      final platform = FakeBankPlatform()..listenerEnabled = true;
      await pump(tester, location: '/finance/banks', platform: platform);
      expect(find.byKey(const Key('banks-needs-access')), findsNothing);
      expect(find.text('включены'), findsOneWidget);
    });

    testWidgets('Windows: «только Android», выписка и сверка доступны', (
      tester,
    ) async {
      await pump(tester, location: '/finance/banks');
      expect(find.byKey(const Key('banks-unsupported')), findsOneWidget);
      expect(find.text('только Android'), findsOneWidget);
      await tapKey(tester, 'banks-link-import');
      expect(find.byKey(const Key('statement-import-screen')), findsOneWidget);
    });

    testWidgets('переходы: черновики, требует проверки, сверка, настройка', (
      tester,
    ) async {
      await pump(tester, location: '/finance/banks');
      await tapKey(tester, 'banks-link-drafts');
      expect(find.byKey(const Key('drafts-screen')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'banks-link-review');
      expect(find.byKey(const Key('needs-review-screen')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'banks-link-reconcile');
      expect(find.byKey(const Key('bank-reconcile-screen')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'banks-link-setup');
      expect(find.byKey(const Key('bank-setup-screen')), findsOneWidget);
    });

    testWidgets(
      'из «Финансов» есть ссылка «Банки»; экраны под замком раздела',
      (tester) async {
        await pump(tester, location: '/finance');
        await tapKey(tester, 'finance-link-banks');
        expect(find.byKey(const Key('banks-screen')), findsOneWidget);
        expect(
          find.ancestor(
            of: find.byType(BanksScreen),
            matching: find.byType(FinanceLockGate),
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('«Черновики»', () {
    testWidgets('карточка: контрагент, счёт, статус, источник; подтвердить', (
      tester,
    ) async {
      final c = await pump(tester);
      final draft = (await _txs(
        tester,
        c,
      )).firstWhere((t) => t.status == TxStatus.draft);
      expect(find.byKey(Key('draft-card-${draft.id}')), findsOneWidget);
      expect(find.text('Черновик из уведомления'), findsOneWidget);
      expect(find.text('ЧЕРНОВИК'), findsOneWidget);
      expect(find.text('ВРУЧНУЮ'), findsOneWidget);
      await tapKey(tester, 'draft-confirm-${draft.id}');
      expect(find.byKey(const Key('drafts-empty')), findsOneWidget);
      final after = (await _txs(tester, c)).firstWhere((t) => t.id == draft.id);
      expect(after.status, TxStatus.confirmed);
    });

    testWidgets('отклонить: подтверждение, операция уходит в корзину', (
      tester,
    ) async {
      final c = await pump(tester);
      final draft = (await _txs(
        tester,
        c,
      )).firstWhere((t) => t.status == TxStatus.draft);
      await tapKey(tester, 'draft-reject-${draft.id}');
      // «Отмена» ничего не делает.
      await tapKey(tester, 'confirm-cancel');
      expect(find.byKey(Key('draft-card-${draft.id}')), findsOneWidget);
      await tapKey(tester, 'draft-reject-${draft.id}');
      await tapKey(tester, 'confirm-ok');
      expect(find.byKey(const Key('drafts-empty')), findsOneWidget);
      expect((await _txs(tester, c)).any((t) => t.id == draft.id), isFalse);
    });

    testWidgets('поправить открывает форму операции', (tester) async {
      final c = await pump(tester);
      final draft = (await _txs(
        tester,
        c,
      )).firstWhere((t) => t.status == TxStatus.draft);
      await tapKey(tester, 'draft-edit-${draft.id}');
      expect(find.byType(TransactionEditor), findsOneWidget);
      expect(find.byKey(const Key('tx-confirm')), findsOneWidget);
    });

    testWidgets('смена категории и «запомнить для этого мерчанта» создаёт '
        'правило', (tester) async {
      final c = await pump(tester);
      final draft = (await _txs(
        tester,
        c,
      )).firstWhere((t) => t.status == TxStatus.draft);
      // До выбора галочка выключена.
      expect(
        tester
            .widget<Checkbox>(find.byKey(Key('draft-remember-${draft.id}')))
            .value,
        isFalse,
      );
      await tapKey(tester, 'draft-category-${draft.id}');
      await pickCategory(tester, groceriesId());
      expect(find.text('Продукты'), findsWidgets);
      // После ручного выбора галочка включается сама.
      expect(
        tester
            .widget<Checkbox>(find.byKey(Key('draft-remember-${draft.id}')))
            .value,
        isTrue,
      );
      await tapKey(tester, 'draft-confirm-${draft.id}');
      final rules = await _run(
        tester,
        () => c.read(banksRepositoryProvider).rules(),
      );
      expect(rules.single.categoryId, groceriesId());
      expect(rules.single.merchantKey, 'черновик из уведомления');
    });

    testWidgets('без галочки правило не создаётся', (tester) async {
      final c = await pump(tester);
      final draft = (await _txs(
        tester,
        c,
      )).firstWhere((t) => t.status == TxStatus.draft);
      await tapKey(tester, 'draft-remember-${draft.id}');
      await tapKey(tester, 'draft-remember-${draft.id}');
      await tapKey(tester, 'draft-confirm-${draft.id}');
      expect(
        await _run(tester, () => c.read(banksRepositoryProvider).rules()),
        isEmpty,
      );
    });

    testWidgets('массовое подтверждение: выбрать все → подтвердить; «Требует '
        'проверки» без галочки и без прямого подтверждения', (tester) async {
      final c = await pump(tester);
      await _add(tester, c, demo.bank, merchant: 'Магнит', amount: 20000);
      await _add(tester, c, demo.bank, merchant: 'Лента', amount: 30000);
      final review = await _add(
        tester,
        c,
        demo.bank,
        merchant: 'AMAZON',
        status: TxStatus.needsReview,
        comment: 'Сумма в USD: 12,50. Укажите сумму в рублях.',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('draft-select-$review')), findsNothing);
      expect(find.byKey(Key('draft-confirm-$review')), findsNothing);
      expect(find.byKey(Key('draft-check-$review')), findsOneWidget);
      expect(find.byKey(Key('draft-comment-$review')), findsOneWidget);
      expect(find.text('ТРЕБУЕТ ПРОВЕРКИ'), findsOneWidget);

      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('drafts-confirm-selected')),
            )
            .onPressed,
        isNull,
      );
      await tapKey(tester, 'drafts-select-all');
      expect(find.text('Подтвердить (3)'), findsOneWidget);
      // Снять выбор и выбрать снова.
      await tapKey(tester, 'drafts-select-all');
      expect(find.text('Подтвердить'), findsWidgets);
      await tapKey(tester, 'drafts-select-all');
      await tapKey(tester, 'drafts-confirm-selected');
      expect(find.textContaining('Подтверждено: 3 операции'), findsOneWidget);
      final left = (await _txs(tester, c)).where((t) => !t.isConfirmed);
      expect(left.single.id, review);
      // «Проверить» открывает форму.
      await tapKey(tester, 'draft-check-$review');
      expect(find.byType(TransactionEditor), findsOneWidget);
    });

    testWidgets('выбор отдельных черновиков', (tester) async {
      final c = await pump(tester);
      final a = await _add(tester, c, demo.bank, merchant: 'Магнит');
      await _add(tester, c, demo.bank, merchant: 'Лента');
      await tester.pumpAndSettle();
      await tapKey(tester, 'draft-select-$a');
      expect(find.text('Подтвердить (1)'), findsOneWidget);
      await tapKey(tester, 'draft-select-$a');
      expect(find.text('Подтвердить (1)'), findsNothing);
    });

    testWidgets('склейка перевода между своими счетами и отказ', (
      tester,
    ) async {
      final c = await pump(tester, more: (c) async {});
      final out = await _add(
        tester,
        c,
        demo.bank,
        amount: 600000,
        merchant: 'Перевод себе',
        at: DateTime.utc(2026, 9, 29, 10),
      );
      final inc = await _add(
        tester,
        c,
        demo.savings,
        amount: 600000,
        kind: TxKind.income,
        merchant: 'Поступление',
        at: DateTime.utc(2026, 9, 29, 10, 0, 30),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('transfer-card-$out')), findsOneWidget);
      expect(find.textContaining('Т-Банк → ВТБ'), findsOneWidget);
      await tapKey(tester, 'transfer-merge-$out');
      expect(find.byKey(Key('transfer-card-$out')), findsNothing);
      final all = await _txs(tester, c);
      expect(all.where((t) => t.id == out || t.id == inc), isEmpty);
      final transfer = all.singleWhere(
        (t) => t.kind == TxKind.transfer && t.amount == 600000,
      );
      expect(transfer.accountId, demo.bank);
      expect(transfer.toAccountId, demo.savings);
    });

    testWidgets('«Это не перевод» убирает предложение и помнит выбор', (
      tester,
    ) async {
      final c = await pump(tester);
      final out = await _add(
        tester,
        c,
        demo.bank,
        amount: 700000,
        at: DateTime.utc(2026, 9, 29, 10),
      );
      await _add(
        tester,
        c,
        demo.savings,
        amount: 700000,
        kind: TxKind.income,
        at: DateTime.utc(2026, 9, 29, 10, 1),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'transfer-dismiss-$out');
      expect(find.byKey(Key('transfer-card-$out')), findsNothing);
      // Выбор сохранён локально и переживает пересоздание провайдера.
      final saved = await _run(
        tester,
        () => c.read(dismissedTransfersProvider.future),
      );
      expect(saved, hasLength(1));
    });

    testWidgets('десктоп: тот же список', (tester) async {
      await pump(tester, size: desktopSize);
      expect(find.byKey(const Key('drafts-screen')), findsOneWidget);
      expect(find.text('Черновик из уведомления'), findsOneWidget);
    });
  });

  group('«Требует проверки»', () {
    Future<BankNotification> unrecognized(
      WidgetTester tester,
      ProviderContainer c, {
      String text = 'Оплата 1 234,50 ₽ в Кафе у дома. Остаток 5 000 ₽',
    }) => _run(
      tester,
      () async => (await c
          .read(notificationStoreProvider)
          .insert(
            raw(vtbPackage, 'ВТБ', text, DateTime.utc(2026, 9, 29, 9, 30)),
            state: NotificationState.unrecognized,
            reason: 'no_rule',
          ))!,
    );

    Future<BankNotification> needsAccount(
      WidgetTester tester,
      ProviderContainer c,
    ) => _run(tester, () async {
      final data = loadBankDataSync();
      const text = 'Покупка на 100 ₽, Магнит. Карта *9999. Доступно 500 ₽';
      final parsed = parseNotification(
        data.notifications,
        package: tbankPackage,
        title: 'Покупка',
        text: text,
      );
      return (await c
          .read(notificationStoreProvider)
          .insert(
            raw(
              tbankPackage,
              'Покупка',
              text,
              DateTime.utc(2026, 9, 29, 9, 30),
            ),
            state: NotificationState.needsAccount,
            reason: 'no_account',
            parsed: parsed,
          ))!;
    });

    testWidgets('пусто: «Всё разобрано»', (tester) async {
      await pump(tester, location: '/finance/banks/review');
      expect(find.byKey(const Key('review-empty')), findsOneWidget);
    });

    testWidgets('нераспознанное: исходный текст, создать операцию вручную '
        'из заготовки', (tester) async {
      final c = await pump(tester, location: '/finance/banks/review');
      final n = await unrecognized(tester, c);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('review-unrecognized-${n.id}')), findsOneWidget);
      expect(find.textContaining('Кафе у дома'), findsOneWidget);
      expect(find.textContaining('ВТБ'), findsWidgets);
      expect(find.text('НЕ РАСПОЗНАНО'), findsNWidgets(2));
      expect(find.text('Формат уведомления пока не известен'), findsOneWidget);

      await tapKey(tester, 'review-create-${n.id}');
      // Заготовка: сумма из текста, текст в комментарии.
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('tx-amount')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '1234,50',
      );
      await tapKey(tester, 'tx-save');
      final all = await _txs(tester, c);
      final created = all.firstWhere((t) => t.amount == 123450);
      expect(created.comment, contains('Кафе у дома'));
      expect(created.status, TxStatus.confirmed);
      // Уведомление обработано и пропало из списка.
      expect(find.byKey(Key('review-unrecognized-${n.id}')), findsNothing);
      final stored = await _run(
        tester,
        () => c.read(notificationStoreProvider).get(n.id),
      );
      expect(stored!.state, NotificationState.processed);
      expect(stored.txId, created.id);
    });

    testWidgets('«Убрать» скрывает уведомление', (tester) async {
      final c = await pump(tester, location: '/finance/banks/review');
      final n = await unrecognized(tester, c);
      await tester.pumpAndSettle();
      await tapKey(tester, 'review-dismiss-${n.id}');
      expect(find.byKey(const Key('review-empty')), findsOneWidget);
    });

    testWidgets('нужен счёт: выбор счёта создаёт черновик', (tester) async {
      final c = await pump(tester, location: '/finance/banks/review');
      final pending = await needsAccount(tester, c);
      expect(
        find.text('Не найден счёт с такими последними цифрами карты'),
        findsOneWidget,
      );
      expect(find.textContaining('карта •••• 9999'), findsOneWidget);
      await tapKey(tester, 'review-pick-${pending.id}-${demo.savings}');
      expect(find.byKey(const Key('review-empty')), findsOneWidget);
      final created = (await _txs(
        tester,
        c,
      )).firstWhere((t) => t.amount == 10000 && t.accountId == demo.savings);
      expect(created.status, TxStatus.draft);
    });

    testWidgets('нужен счёт: «Убрать»', (tester) async {
      final c = await pump(tester, location: '/finance/banks/review');
      final pending = await needsAccount(tester, c);
      await tapKey(tester, 'review-dismiss-${pending.id}');
      expect(find.byKey(const Key('review-empty')), findsOneWidget);
    });
  });

  group('онбординг уведомлений', () {
    testWidgets('Windows: «только Android»', (tester) async {
      await pump(tester, location: '/finance/banks/setup');
      expect(find.byKey(const Key('setup-unsupported')), findsOneWidget);
    });

    testWidgets('Android: доступ и батарея — статусы, кнопки, повторная '
        'проверка', (tester) async {
      final platform = FakeBankPlatform();
      await pump(tester, location: '/finance/banks/setup', platform: platform);
      expect(find.text('НЕ ВЫДАН'), findsOneWidget);
      expect(find.text('ОГРАНИЧЕНО'), findsOneWidget);
      // Инструкция для One UI и список банков.
      expect(
        find.textContaining('Никогда не спящие приложения'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Т-Банк: com.idamob.tinkoff.android'),
        findsOneWidget,
      );
      expect(find.textContaining('не отправляется на сервер'), findsOneWidget);

      await tapKey(tester, 'setup-open-access');
      expect(platform.openedListener, 1);
      await tapKey(tester, 'setup-open-battery');
      expect(platform.openedBattery, 1);

      platform
        ..listenerEnabled = true
        ..batteryExempt = true;
      await tapKey(tester, 'setup-recheck');
      await tapKey(tester, 'setup-recheck-battery');
      expect(find.text('ВЫДАН'), findsOneWidget);
      expect(find.text('БЕЗ ОГРАНИЧЕНИЙ'), findsOneWidget);
    });

    testWidgets('возврат из системных настроек перечитывает статусы', (
      tester,
    ) async {
      final platform = FakeBankPlatform();
      await pump(tester, location: '/finance/banks/setup', platform: platform);
      expect(find.text('НЕ ВЫДАН'), findsOneWidget);
      platform.listenerEnabled = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('ВЫДАН'), findsOneWidget);
    });
  });

  group('сверка с банком', () {
    testWidgets('счета, баланс, корректировка и источник последней сверки', (
      tester,
    ) async {
      final c = await pump(tester, location: '/finance/banks/reconcile');
      expect(find.byKey(Key('reconcile-account-${demo.bank}')), findsOneWidget);
      expect(find.byKey(Key('reconcile-last-${demo.bank}')), findsNothing);
      // Ввод фактического остатка: сверка вручную.
      await tapKey(tester, 'reconcile-open-${demo.bank}');
      await tester.enterText(
        find.byKey(const Key('reconcile-actual')),
        '170 000',
      );
      await tapKey(tester, 'reconcile-save');
      expect(find.byKey(Key('reconcile-last-${demo.bank}')), findsOneWidget);
      expect(find.textContaining('вручную'), findsOneWidget);
      expect(
        find.byKey(Key('reconcile-adjustment-${demo.bank}')),
        findsOneWidget,
      );
      // Остаток из уведомления — отдельный источник.
      await _run(
        tester,
        () => c
            .read(financeRepositoryProvider)
            .reconcile(
              accountId: demo.bank,
              actualBalance: 17000000,
              checkedAt: DateTime.utc(2026, 9, 30, 8, 41),
              source: CheckpointSource.notification,
            ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('из уведомления банка'), findsOneWidget);
    });

    testWidgets('нет счетов: пустое состояние', (tester) async {
      await pumpBanks(tester, location: '/finance/banks/reconcile');
      expect(find.byKey(const Key('reconcile-empty')), findsOneWidget);
    });

    test('источники точки сверки подписаны', () {
      expect(checkpointSourceLabel(CheckpointSource.manual), 'вручную');
      expect(
        checkpointSourceLabel(CheckpointSource.notification),
        'из уведомления банка',
      );
      expect(checkpointSourceLabel(CheckpointSource.statement), 'из выписки');
    });
  });
}
