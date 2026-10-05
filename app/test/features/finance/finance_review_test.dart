import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/finance_context_source.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';
import 'package:my_tasker/features/finance/data/screen_security.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/trash/presentation/trash_screen.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../support/finance_env.dart';

void main() {
  late FinanceDemo demo;

  group('сверка не принимает будущее', () {
    testWidgets('нет чипов «Завтра» и «Пн»; сегодняшняя дата доступна', (
      tester,
    ) async {
      await pumpFinance(
        tester,
        location: '/finance/accounts',
        seedWith: (c) async => demo = await seedFinanceDemo(c),
      );
      await tester.tap(find.byKey(Key('account-${demo.bank}')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'account-reconcile');
      expect(find.byKey(const Key('reconcile-date-today')), findsOneWidget);
      expect(find.byKey(const Key('reconcile-date-tomorrow')), findsNothing);
      expect(find.byKey(const Key('reconcile-date-monday')), findsNothing);
      expect(find.byKey(const Key('reconcile-date-pick')), findsOneWidget);
    });
  });

  group('форма операции: предупреждения о дате', () {
    testWidgets('дата в будущем и раньше открытия счёта', (tester) async {
      late String young;
      await pumpFinance(
        tester,
        location: '/finance/transactions',
        seedWith: (c) async {
          demo = await seedFinanceDemo(c);
          final repo = c.read(financeRepositoryProvider);
          young = repo.newId();
          await repo.createAccount(
            Account(
              id: young,
              name: 'Новая карта',
              kind: AccountKind.debitCard,
              openingBalance: 0,
              openingDate: '2026-09-20',
            ),
          );
        },
      );
      await tapKey(tester, 'transactions-add');
      expect(find.byKey(const Key('tx-future')), findsNothing);
      expect(find.byKey(const Key('tx-before-opening')), findsNothing);

      await tapKey(tester, 'tx-date-tomorrow');
      expect(find.byKey(const Key('tx-future')), findsOneWidget);
      expect(find.textContaining('Дата в будущем'), findsOneWidget);

      await tapKey(tester, 'tx-date-today');
      expect(find.byKey(const Key('tx-future')), findsNothing);

      // Новый счёт открыт 20 сентября; выбираем 10 сентября.
      await tapKey(tester, 'tx-account-$young');
      await tester.tap(find.byKey(const Key('tx-date-pick')));
      await tester.pumpAndSettle();
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
      expect(find.byKey(const Key('tx-before-opening')), findsOneWidget);
      expect(find.textContaining('раньше открытия счёта'), findsOneWidget);
    });
  });

  group('«деньги по проекту пришли»: запись задним числом', () {
    testWidgets('платёж раньше открытия счёта — предупреждение', (
      tester,
    ) async {
      late String young;
      final container = await pumpFinance(
        tester,
        location: '/finance/work',
        seedWith: (c) async {
          demo = await seedFinanceDemo(c);
          final repo = c.read(financeRepositoryProvider);
          young = repo.newId();
          await repo.createAccount(
            Account(
              id: young,
              name: 'Новая карта',
              kind: AccountKind.debitCard,
              openingBalance: 0,
              openingDate: '2026-09-15',
            ),
          );
        },
      );
      final payment = container
          .read(financeDataProvider)
          .requireValue
          .work
          .payments
          .firstWhere((p) => p.amount == 1200000);
      await tapKey(tester, 'work-income-reflect-${payment.id}');
      // Первый (старый) счёт открыт в январе — предупреждения нет.
      await tapKey(tester, 'reflect-account-${demo.bank}');
      expect(find.byKey(const Key('reflect-backdated')), findsNothing);
      // Платёж от 20 августа, счёт открыт 15 сентября.
      await tapKey(tester, 'reflect-account-$young');
      expect(find.byKey(const Key('reflect-backdated')), findsOneWidget);
      expect(find.textContaining('задним числом'), findsOneWidget);
    });
  });

  group('«Повторить» перезапускает только упавшие потоки', () {
    testWidgets('счета не перечитываются, цели — да', (tester) async {
      var accountsBuilds = 0;
      var goalsBuilds = 0;
      await pumpFinance(
        tester,
        overrides: [
          accountsProvider.overrideWith((ref) {
            accountsBuilds++;
            return Stream<List<Account>>.value(const []);
          }),
          goalsProvider.overrideWith((ref) {
            goalsBuilds++;
            return goalsBuilds == 1
                ? Stream<List<Goal>>.error(StateError('сбой'))
                : Stream<List<Goal>>.value(const []);
          }),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
      expect((accountsBuilds, goalsBuilds), (1, 1));
      await tapKey(tester, 'finance-retry');
      expect(accountsBuilds, 1, reason: 'исправный поток не трогаем');
      expect(goalsBuilds, 2);
      expect(find.byKey(const Key('finance-error')), findsNothing);
    });
  });

  group('быстрый ввод операции и корзина при закрытом разделе', () {
    Future<(ProviderContainer, MemorySecretStore)> locked(
      WidgetTester tester, {
      String location = '/finance',
    }) async {
      final store = MemorySecretStore();
      await tester.runAsync(
        () => PinLockService(store, iterations: 5).setPin('4821'),
      );
      final container = await pumpFinance(
        tester,
        location: location,
        secretStore: store,
        seedWith: (c) async => demo = await seedFinanceDemo(c),
      );
      return (container, store);
    }

    testWidgets('«+» → «Операция» требует PIN, потом открывает форму', (
      tester,
    ) async {
      await locked(tester, location: '/today');
      await tapKey(tester, 'create-fab');
      await tapKey(tester, 'quick-create-transaction');
      expect(find.byKey(const Key('finance-unlock-dialog')), findsOneWidget);
      expect(find.byKey(const Key('tx-amount')), findsNothing);

      await tester.enterText(find.byKey(const Key('lock-pin')), '4821');
      await tester.tap(find.byKey(const Key('lock-submit')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-unlock-dialog')), findsNothing);
      expect(find.byKey(const Key('tx-amount')), findsOneWidget);
    });

    testWidgets('отмена разблокировки: форма не открывается', (tester) async {
      await locked(tester, location: '/today');
      await tapKey(tester, 'create-fab');
      await tapKey(tester, 'quick-create-transaction');
      await tapKey(tester, 'finance-unlock-cancel');
      expect(find.byKey(const Key('tx-amount')), findsNothing);
    });

    testWidgets('корзина: заголовки финансовых строк скрыты, пока замок '
        'закрыт', (tester) async {
      final (container, _) = await locked(tester, location: '/settings/trash');
      await tester.runAsync(
        () =>
            container.read(financeRepositoryProvider).deleteAccount(demo.cash),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('trash-hidden-${demo.cash}')), findsOneWidget);
      expect(find.text(hiddenFinanceTitle), findsOneWidget);
      expect(find.text('Наличные'), findsNothing);

      await tester.runAsync(
        () =>
            container.read(financeLockProvider.notifier).unlockWithPin('4821'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('trash-hidden-${demo.cash}')), findsNothing);
      expect(find.text('Наличные'), findsOneWidget);
    });
  });

  group('FLAG_SECURE: канал в платформу', () {
    testWidgets('setSecure уходит в канал my_tasker/screen_security', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformScreenSecurity.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          PlatformScreenSecurity.channel,
          null,
        ),
      );
      const security = PlatformScreenSecurity();
      await security.setSecure(secure: true);
      await security.setSecure(secure: false);
      expect([for (final c in calls) c.method], ['setSecure', 'setSecure']);
      expect([for (final c in calls) c.arguments], [true, false]);
    });

    testWidgets('ошибка платформы не ломает приложение', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformScreenSecurity.channel,
        (call) async => throw PlatformException(code: 'no_window'),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          PlatformScreenSecurity.channel,
          null,
        ),
      );
      await const PlatformScreenSecurity().setSecure(secure: true);
    });
  });

  group('суммы вне диапазона и неизвестные данные', () {
    test('formatAmountClamped не бросает; formatAmount — по-прежнему', () {
      expect(formatAmountClamped(maxKopecks + 1), '≈ ∞');
      expect(formatAmountClamped(-maxKopecks - 1), '≈ -∞');
      expect(formatAmountClamped(150000), formatAmount(150000));
      expect(() => formatAmount(maxKopecks + 1), throwsRangeError);
      const f = AmountFormat(hidden: false);
      expect(f.full(maxKopecks + 5), '≈ ∞');
      expect(f.signed(maxKopecks + 5), '+≈ ∞');
      expect(
        const AmountFormat(hidden: true).full(maxKopecks + 5),
        AmountFormat.mask,
      );
    });

    test(
      'операция неизвестного вида: «требует проверки», баланс не меняет',
      () {
        final tx = FinTransaction.fromRow(const {
          'id': 'a',
          'kind': 'swap',
          'account_id': 'acc',
          'amount': 100,
          'occurred_at': '2026-09-01T10:00:00Z',
          'status': 'confirmed',
        });
        expect(tx.status, TxStatus.needsReview);
        expect(tx.isConfirmed, isFalse);
        expect(effect(tx, 'acc'), 0);
        // Известный вид читается как раньше.
        final known = FinTransaction.fromRow(const {
          'id': 'b',
          'kind': 'income',
          'account_id': 'acc',
          'amount': 100,
          'occurred_at': '2026-09-01T10:00:00Z',
          'status': 'confirmed',
        });
        expect(known.status, TxStatus.confirmed);
        expect(TxKind.tryParse('swap'), isNull);
        expect(TxKind.parse('swap'), TxKind.expense);
      },
    );

    testWidgets('контекст ИИ: маска вместо сумм и «≈ ∞» вместо сбоя', (
      tester,
    ) async {
      final container = await pumpFinance(tester, seed: true);
      final env = container.read(contextEnvProvider)();
      const source = FinanceContextSource();
      final masked = (await tester.runAsync(
        () =>
            source.lines(env.copyWith(hideAmounts: true), source.defaultFilter),
      ))!;
      expect(masked.first, '- Общий баланс: $maskedAmount');
      expect(masked.join('\n'), isNot(contains(nb('54 000 ₽'))));
      expect(masked.join('\n'), contains(maskedAmount));
      final plain = (await tester.runAsync(
        () => source.lines(env, source.defaultFilter),
      ))!;
      expect(plain.first, '- Общий баланс: ${nb('361 000 ₽')}');
    });

    testWidgets('сумма вне диапазона: контекст и экран не падают', (
      tester,
    ) async {
      final container = await pumpFinance(
        tester,
        seedWith: (c) async {
          final repo = c.read(financeRepositoryProvider);
          for (final id in ['huge', 'huge2']) {
            await repo.createAccount(
              Account(
                id: id,
                name: 'Огромный $id',
                kind: AccountKind.other,
                openingBalance: maxKopecks,
                openingDate: '2026-01-01',
              ),
            );
          }
        },
      );
      const source = FinanceContextSource();
      final lines = (await tester.runAsync(
        () => source.lines(
          container.read(contextEnvProvider)(),
          source.defaultFilter,
        ),
      ))!;
      expect(lines.first, '- Общий баланс: ≈ ∞');
      expect(find.text('≈ ∞'), findsWidgets);
    });

    test('сборщик контекста не мешает маске: ContextEnv.copyWith', () {
      final env = ContextEnvSample.make();
      expect(env.hideAmounts, isFalse);
      expect(env.copyWith(hideAmounts: true).hideAmounts, isTrue);
      expect(
        const ContextBuilder([FinanceContextSource()]).sources,
        hasLength(1),
      );
      expect(const ContextPackage.withheld().withheld, isTrue);
      expect(const ContextPackage.withheld().containsSensitive, isTrue);
    });
  });
}

/// Окружение контекста без данных.
class ContextEnvSample {
  static ContextEnv make() => ContextEnv(
    now: DateTime.utc(2026, 9, 30),
    zone: tz.UTC,
    readRows: (_) async => const [],
  );
}
