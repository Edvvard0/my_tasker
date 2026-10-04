import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';
import 'package:my_tasker/features/finance/presentation/category_picker.dart';

import 'fake_server/fake_sync_server.dart';
import 'manual_clock.dart';
import 'pump_app.dart';
import 'sync_env.dart' show TestDevice;
import 'work_env.dart';

export 'pump_app.dart' show desktopSize, expandedSize, mediumSize, phoneSize;
export 'work_env.dart' show goTo, msk, nb, seedWorkDemo, tapKey, workNow;

/// «Сейчас» для экранов «Финансов»: среда, 30 сентября 2026, 11:40 по
/// Москве (как у «Работы»).
final DateTime financeNow = workNow;

/// Запускает приложение на экране «Финансы» с зафиксированным временем и
/// поясом Москвы; [seed] наполняет демо-данными («Работа» и «Финансы»),
/// [seedWith] — своими.
Future<ProviderContainer> pumpFinance(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/finance',
  bool seed = false,
  DateTime? now,
  Future<void> Function(ProviderContainer container)? seedWith,
  List<Override> overrides = const [],
  SecretStore? secretStore,
}) async {
  final container = await pumpApp(
    tester,
    size: size,
    location: location,
    now: now ?? financeNow,
    secretStore: secretStore,
    settle: false,
    overrides: [
      deviceTimeZoneSourceProvider.overrideWithValue(
        const FixedTimeZoneSource('Europe/Moscow'),
      ),
      ...overrides,
    ],
  );
  await tester.runAsync(() async {
    if (seed) await seedFinanceDemo(container);
    if (seedWith != null) await seedWith(container);
  });
  await tester.pumpAndSettle();
  return container;
}

/// Идентификаторы демо-данных.
class FinanceDemo {
  const FinanceDemo({
    required this.work,
    required this.cash,
    required this.bank,
    required this.savings,
    required this.credit,
    required this.debtPasha,
    required this.debtMasha,
    required this.debtSasha,
    required this.goal,
    required this.salary,
  });

  final WorkDemo work;
  final String cash;
  final String bank;
  final String savings;
  final String credit;
  final String debtPasha;
  final String debtMasha;
  final String debtSasha;
  final String goal;
  final String salary;
}

String groceriesId() => categoryPresetId('expense.groceries');
String cafeId() => categoryPresetId('expense.eating_out');
String taxiId() => categoryPresetId('expense.transport.taxi');
String transportId() => categoryPresetId('expense.transport');
String salaryCategoryId() => categoryPresetId('income.salary');

/// Демо по случаю Excel заказчика (spec 6.3), поверх демо «Работы»
/// (дебиторка 80 500 ₽: Рома 25 000 + Елена 55 500):
///
/// * счета: наличные 54 000, Т-Банк 174 000, накопительный 8 000 (итого
///   236 000) и кредитка 125 000 (баланс, в общем балансе);
/// * долги мне: 7 500 + 2 600 + 3 000 = 13 100;
/// * цель «Подушка» 400 000 с формулой по умолчанию: Есть 454 600, цель
///   достигнута с запасом 54 600 (без кредитки — «Есть» 329 600, не
///   хватает 70 400).
///
/// Операции августа и сентября, перевод 5 000 на накопительный, один
/// черновик (в итоги не входит).
Future<FinanceDemo> seedFinanceDemo(ProviderContainer container) async {
  final work = await seedWorkDemo(container);
  final repo = container.read(financeRepositoryProvider);
  await repo.seedPresetCategories();

  Future<String> account(
    String name,
    AccountKind kind,
    int opening, {
    String? bank,
    String? last4,
    int? limit,
  }) async {
    final id = repo.newId();
    await repo.createAccount(
      Account(
        id: id,
        name: name,
        kind: kind,
        bank: bank,
        cardLast4: last4,
        openingBalance: opening,
        openingDate: '2026-01-01',
        creditLimit: limit,
      ),
    );
    return id;
  }

  final cash = await account('Наличные', AccountKind.cash, 5450000);
  final bank = await account(
    'Т-Банк',
    AccountKind.debitCard,
    11200000,
    bank: 'Т-Банк',
    last4: '1234',
  );
  final savings = await account(
    'ВТБ',
    AccountKind.savings,
    300000,
    bank: 'ВТБ',
  );
  final credit = await account(
    'Кредитка',
    AccountKind.creditCard,
    12500000,
    bank: 'Т-Банк',
    last4: '4242',
    limit: 30000000,
  );

  Future<String> tx(
    TxKind kind,
    String accountId,
    int amount,
    DateTime at, {
    String? to,
    String? category,
    String? merchant,
    TxStatus status = TxStatus.confirmed,
  }) => repo.createTransaction(
    FinTransaction(
      id: repo.newId(),
      kind: kind,
      accountId: accountId,
      toAccountId: to,
      amount: amount,
      occurredAt: at,
      categoryId: category,
      merchant: merchant,
      status: status,
    ),
  );

  await tx(
    TxKind.expense,
    bank,
    700000,
    msk(2026, 8, 14, 13),
    category: groceriesId(),
    merchant: 'Лента',
  );
  await tx(
    TxKind.income,
    bank,
    8500000,
    msk(2026, 9, 5, 10),
    category: salaryCategoryId(),
    merchant: 'Работодатель',
  );
  await tx(
    TxKind.expense,
    bank,
    424990,
    msk(2026, 9, 2, 19),
    category: groceriesId(),
    merchant: 'Пятёрочка',
  );
  await tx(
    TxKind.expense,
    bank,
    175010,
    msk(2026, 9, 9, 18),
    category: groceriesId(),
    merchant: 'Лента',
  );
  await tx(
    TxKind.expense,
    bank,
    300000,
    msk(2026, 9, 15, 14),
    category: cafeId(),
    merchant: 'Кофемания',
  );
  await tx(
    TxKind.expense,
    bank,
    200000,
    msk(2026, 9, 20, 22),
    category: taxiId(),
    merchant: 'Яндекс Go',
  );
  await tx(TxKind.transfer, bank, 500000, msk(2026, 9, 12), to: savings);
  await tx(
    TxKind.expense,
    cash,
    50000,
    msk(2026, 9, 3, 11),
    category: groceriesId(),
    merchant: 'Рынок',
  );
  await tx(
    TxKind.expense,
    bank,
    99900,
    msk(2026, 9, 28),
    category: cafeId(),
    merchant: 'Черновик из уведомления',
    status: TxStatus.draft,
  );

  Future<String> debt(String who, int amount) async {
    final id = repo.newId();
    await repo.createDebt(
      Debt(
        id: id,
        direction: DebtDirection.owedToMe,
        counterparty: who,
        amount: amount,
        debtDate: '2026-09-01',
        dueDate: who == 'Паша' ? '2026-10-15' : null,
      ),
    );
    return id;
  }

  final pasha = await debt('Паша', 750000);
  final masha = await debt('Маша', 260000);
  final sasha = await debt('Саша', 300000);

  final goal = repo.newId();
  await repo.createGoal(
    Goal(
      id: goal,
      name: 'Подушка',
      targetAmount: 40000000,
      deadlineDate: '2026-11-15',
      formula: defaultGoalFormula(),
    ),
  );

  return FinanceDemo(
    work: work,
    cash: cash,
    bank: bank,
    savings: savings,
    credit: credit,
    debtPasha: pasha,
    debtMasha: masha,
    debtSasha: sasha,
    goal: goal,
    salary: salaryCategoryId(),
  );
}

/// Устройство с репозиториями «Работы» и «Финансов» поверх [TestDevice]
/// (тесты синхронизации).
class FinanceDevice {
  FinanceDevice(this.work, {String Function()? newId})
    : finance = FinanceRepository(
        work.device.store,
        newId: newId,
        now: () => work.device.clock.now,
      );

  static Future<FinanceDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    String Function()? newId,
  }) async => FinanceDevice(
    await WorkDevice.create(server, clock: clock, newId: newId),
    newId: newId,
  );

  final WorkDevice work;
  final FinanceRepository finance;

  TestDevice get device => work.device;

  Future<void> close() => work.close();
}

/// Один счёт без операций и категорий (тесты пустых состояний).
Future<String> seedAccountOnly(ProviderContainer container) async {
  final repo = container.read(financeRepositoryProvider);
  final id = repo.newId();
  await repo.createAccount(
    Account(
      id: id,
      name: 'Наличные',
      kind: AccountKind.cash,
      openingBalance: 100000,
      openingDate: '2026-01-01',
    ),
  );
  return id;
}

/// Выбирает категорию в открытом листе выбора (прокручивая список).
Future<void> pickCategory(WidgetTester tester, String id) async {
  final target = find.byKey(Key('category-pick-$id'));
  await tester.scrollUntilVisible(
    target,
    150,
    scrollable: find
        .descendant(
          of: find.byType(CategoryPickerSheet),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Включает режим «скрыть суммы» и ждёт перерисовки.
Future<void> pumpFinanceHidden(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.runAsync(
    () => container.read(hideAmountsProvider.notifier).set(hidden: true),
  );
  await tester.pumpAndSettle();
}
