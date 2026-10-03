import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';
import 'package:my_tasker/features/finance/presentation/widgets/amount_field.dart';

import 'privacy_env.dart';
import 'pump_app.dart';
import 'stage2_env.dart' show demoNow;

export 'stage2_env.dart' show demoNow;

/// Демо-данные Финансов: счета, категории и операции двух месяцев.
class FinanceDemo {
  const FinanceDemo({
    required this.cash,
    required this.tbank,
    required this.vtb,
    required this.savings,
    required this.groceries,
    required this.salary,
    required this.shop,
  });

  final String cash;
  final String tbank;
  final String vtb;
  final String savings;

  /// Категория «Продукты» (расход) и «Зарплата» (доход).
  final String groceries;
  final String salary;

  /// Операция «Пятёрочка».
  final String shop;
}

DateTime _at(String iso) => DateTime.parse('${iso}Z');

/// Запускает приложение на экране Финансов: время зафиксировано на
/// 30 сентября 2026, 11:40 по Москве (как у экранов этапа 2), пояс — Москва.
/// [seedWith] кладёт данные в БД до первого кадра.
Future<ProviderContainer> pumpFinance(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/finance',
  Future<void> Function(ProviderContainer container)? seedWith,
  List<Override> overrides = const [],
  MemoryFinancePrivacyStore? privacyStore,
  FakeBiometric? biometric,
  DateTime Function()? clock,
}) async {
  final container = await pumpApp(
    tester,
    size: size,
    location: location,
    now: demoNow,
    settle: false,
    privacyStore: privacyStore,
    biometric: biometric,
    clock: clock,
    overrides: [
      deviceTimeZoneSourceProvider.overrideWithValue(
        const FixedTimeZoneSource('Europe/Moscow'),
      ),
      ...overrides,
    ],
  );
  if (seedWith != null) await tester.runAsync(() => seedWith(container));
  await tester.pumpAndSettle();
  return container;
}

/// Переходит на маршрут [location] внутри приложения.
Future<void> goTo(WidgetTester tester, String location) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
  await tester.pumpAndSettle();
}

/// Даёт реальному циклу событий выполнить запросы к БД и обновить потоки.
Future<void> settleDb(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Репозиторий Финансов приложения.
FinanceRepository financeRepo(ProviderContainer c) =>
    c.read(financeRepositoryProvider);

/// Счёт для тестов (открыт 1 января 2026).
Future<String> addAccount(
  ProviderContainer c,
  String name, {
  AccountKind kind = AccountKind.debitCard,
  int opening = 0,
  String? bank,
  String? last4,
  bool includeInTotal = true,
  int? limit,
  bool archived = false,
}) {
  final repo = financeRepo(c);
  return repo.createAccount(
    Account(
      id: repo.newId(),
      name: name,
      kind: kind,
      bank: bank,
      cardLast4: last4,
      openingBalance: opening,
      openingDate: '2026-01-01',
      includeInTotal: includeInTotal,
      creditLimit: limit,
      archived: archived,
    ),
  );
}

/// Операция для тестов.
Future<String> addTx(
  ProviderContainer c, {
  required String account,
  required int amount,
  TransactionKind kind = TransactionKind.expense,
  String? to,
  String? category,
  String? merchant,
  String? comment,
  String at = '2026-09-29T09:00:00',
}) {
  final repo = financeRepo(c);
  return repo.createTransaction(
    FinanceTransaction(
      id: repo.newId(),
      kind: kind,
      accountId: account,
      toAccountId: to,
      amount: amount,
      occurredAt: _at(at),
      categoryId: category,
      merchant: merchant,
      comment: comment,
    ),
  );
}

/// Наполняет БД демо-данными: счета «Наличные», «Т-Банк Black», «ВТБ»
/// (кредитка), «Накопительный»; стартовые категории; операции августа и
/// сентября 2026 (время UTC; Москва = UTC+3).
Future<FinanceDemo> seedFinanceDemo(ProviderContainer c) async {
  final repo = financeRepo(c);
  await repo.ensurePresetCategories(requireFirstSync: false);
  final categories = await repo.categories();
  String category(String name, CategoryKind kind) =>
      categories.firstWhere((x) => x.name == name && x.kind == kind).id;
  final groceries = category('Продукты', CategoryKind.expense);
  final cafe = category('Кафе и рестораны', CategoryKind.expense);
  final transport = category('Транспорт', CategoryKind.expense);
  final salary = category('Зарплата', CategoryKind.income);
  final projects = category('Доход с проектов', CategoryKind.income);

  final cash = await addAccount(
    c,
    'Наличные',
    kind: AccountKind.cash,
    opening: 5400000,
  );
  final tbank = await addAccount(
    c,
    'Т-Банк Black',
    bank: 'Т-Банк',
    last4: '4242',
  );
  final vtb = await addAccount(
    c,
    'ВТБ Мир',
    kind: AccountKind.creditCard,
    bank: 'ВТБ',
    last4: '7788',
    opening: -1250000,
    limit: 15000000,
  );
  final savings = await addAccount(
    c,
    'Накопительный',
    kind: AccountKind.savings,
    bank: 'Т-Банк',
    opening: 800000,
  );

  await addTx(
    c,
    account: tbank,
    amount: 18500000,
    kind: TransactionKind.income,
    category: salary,
    merchant: 'Creora',
    at: '2026-08-25T08:00:00',
  );
  await addTx(
    c,
    account: tbank,
    amount: 640000,
    category: groceries,
    merchant: 'Перекрёсток',
    at: '2026-08-28T16:10:00',
  );
  await addTx(
    c,
    account: tbank,
    amount: 2000000,
    kind: TransactionKind.income,
    category: projects,
    merchant: 'Рома · Бот',
    at: '2026-09-20T10:00:00',
  );
  await addTx(
    c,
    account: cash,
    amount: 500000,
    kind: TransactionKind.transfer,
    to: savings,
    at: '2026-09-22T12:00:00',
  );
  await addTx(
    c,
    account: tbank,
    amount: 131000,
    category: cafe,
    merchant: 'Додо Пицца',
    at: '2026-09-27T17:30:00',
  );
  await addTx(
    c,
    account: tbank,
    amount: 42000,
    category: transport,
    merchant: 'Яндекс Go',
    at: '2026-09-29T07:15:00',
  );
  final shop = await addTx(
    c,
    account: tbank,
    amount: 124990,
    category: groceries,
    merchant: 'Пятёрочка',
    at: '2026-09-30T06:02:00',
  );
  return FinanceDemo(
    cash: cash,
    tbank: tbank,
    vtb: vtb,
    savings: savings,
    groceries: groceries,
    salary: salary,
    shop: shop,
  );
}

/// Демо-долги: «мне должны» — Эмир (просрочен), Bender, Настя (частично),
/// Тимур (закрыт); «я должен» — Влад. «Сегодня» (демо-время) — 30 сентября
/// 2026 по Москве.
class DebtsDemo {
  const DebtsDemo({
    required this.emir,
    required this.bender,
    required this.nastya,
    required this.vlad,
    required this.timur,
  });

  final String emir;
  final String bender;
  final String nastya;
  final String vlad;
  final String timur;
}

/// Долг для тестов.
Future<String> addDebt(
  ProviderContainer c, {
  required String who,
  required int amount,
  DebtDirection direction = DebtDirection.owedToMe,
  String date = '2026-09-01',
  String? due,
  String? comment,
  String? loanAccount,
}) {
  final repo = financeRepo(c);
  return repo.createDebt(
    Debt(
      id: repo.newId(),
      direction: direction,
      counterparty: who,
      amount: amount,
      debtDate: date,
      dueDate: due,
      comment: comment,
    ),
    loanAccountId: loanAccount,
  );
}

/// Погашение для тестов (без операции счёта, если [account] не задан).
Future<String> addRepaymentTo(
  ProviderContainer c, {
  required String debt,
  required int amount,
  String on = '2026-09-28',
  String? account,
  String? note,
}) => financeRepo(c).addRepayment(
  debtId: debt,
  amount: amount,
  repaidOn: on,
  accountId: account,
  note: note,
);

/// Наполняет БД демо-долгами (без счетов и операций).
Future<DebtsDemo> seedDebtsDemo(ProviderContainer c) async {
  final emir = await addDebt(
    c,
    who: 'Эмир',
    amount: 750000,
    date: '2026-08-27',
    due: '2026-09-20',
  );
  final bender = await addDebt(
    c,
    who: 'Bender',
    amount: 300000,
    date: '2026-09-18',
    due: '2026-10-15',
  );
  final nastya = await addDebt(
    c,
    who: 'Настя',
    amount: 260000,
    date: '2026-09-25',
  );
  await addRepaymentTo(c, debt: nastya, amount: 60000);
  final vlad = await addDebt(
    c,
    who: 'Влад',
    amount: 1500000,
    direction: DebtDirection.iOwe,
    date: '2026-09-10',
    due: '2026-10-10',
  );
  final timur = await addDebt(c, who: 'Тимур', amount: 400000);
  await addRepaymentTo(c, debt: timur, amount: 400000, on: '2026-09-15');
  return DebtsDemo(
    emir: emir,
    bender: bender,
    nastya: nastya,
    vlad: vlad,
    timur: timur,
  );
}

/// Демо-цели поверх счетов и долгов из Excel заказчика (spec 6.3): счета
/// 54 000 + 174 000 + 8 000 + кредитка 125 000, долги мне 7 500 + 2 600 +
/// 3 000, мой долг 15 000.
class GoalsDemo {
  const GoalsDemo({
    required this.cash,
    required this.tbank,
    required this.savings,
    required this.credit,
    required this.vacation,
    required this.laptop,
    required this.cushion,
    required this.courses,
  });

  final String cash;
  final String tbank;
  final String savings;
  final String credit;

  /// «Отпуск»: 400 000 ₽ до 31 декабря, формула по умолчанию.
  final String vacation;

  /// «Ноутбук»: 150 000 ₽ до 15 ноября, счета «Накопительный» и «Наличные».
  final String laptop;

  /// «Подушка безопасности»: 300 000 ₽ без срока, «все счета» минус мои
  /// долги — цель достигнута.
  final String cushion;

  /// «Курсы»: в архиве.
  final String courses;
}

/// Цель для тестов.
Future<String> addGoal(
  ProviderContainer c, {
  required String name,
  required int target,
  String? deadline,
  List<GoalTerm>? formula,
  bool archived = false,
}) {
  final repo = financeRepo(c);
  return repo.createGoal(
    Goal(
      id: repo.newId(),
      name: name,
      targetAmount: target,
      deadlineDate: deadline,
      formula: formula ?? defaultGoalFormula(),
      archived: archived,
    ),
  );
}

/// Счета и долги из Excel заказчика (без целей).
Future<GoalsDemo> seedExcelAccounts(ProviderContainer c) async {
  final cash = await addAccount(
    c,
    'Наличные',
    kind: AccountKind.cash,
    opening: 5400000,
  );
  final tbank = await addAccount(
    c,
    'Т-Банк Black',
    bank: 'Т-Банк',
    opening: 17400000,
  );
  final savings = await addAccount(
    c,
    'Накопительный',
    kind: AccountKind.savings,
    bank: 'Т-Банк',
    opening: 800000,
  );
  final credit = await addAccount(
    c,
    'ВТБ Мир',
    kind: AccountKind.creditCard,
    bank: 'ВТБ',
    opening: 12500000,
    limit: 30000000,
  );
  await addDebt(c, who: 'Эмир', amount: 750000);
  await addDebt(c, who: 'Bender', amount: 260000);
  await addDebt(c, who: 'Настя', amount: 300000);
  await addDebt(c, who: 'Влад', amount: 1500000, direction: DebtDirection.iOwe);
  return GoalsDemo(
    cash: cash,
    tbank: tbank,
    savings: savings,
    credit: credit,
    vacation: '',
    laptop: '',
    cushion: '',
    courses: '',
  );
}

/// Наполняет БД счетами, долгами и четырьмя целями ([GoalsDemo]).
Future<GoalsDemo> seedGoalsDemo(ProviderContainer c) async {
  final base = await seedExcelAccounts(c);
  final vacation = await addGoal(
    c,
    name: 'Отпуск',
    target: 40000000,
    deadline: '2026-12-31',
  );
  final laptop = await addGoal(
    c,
    name: 'Ноутбук',
    target: 15000000,
    deadline: '2026-11-15',
    formula: [
      GoalTerm(
        kind: GoalTermKind.accounts,
        accountIds: [base.savings, base.cash],
      ),
    ],
  );
  final cushion = await addGoal(
    c,
    name: 'Подушка безопасности',
    target: 30000000,
    formula: [
      const GoalTerm(kind: GoalTermKind.allAccounts),
      GoalTerm.initial(GoalTermKind.myDebts),
    ],
  );
  final courses = await addGoal(
    c,
    name: 'Курсы',
    target: 5000000,
    archived: true,
  );
  return GoalsDemo(
    cash: base.cash,
    tbank: base.tbank,
    savings: base.savings,
    credit: base.credit,
    vacation: vacation,
    laptop: laptop,
    cushion: cushion,
    courses: courses,
  );
}

/// Данные Работы из Excel: Рома должен 20 000 + 60 500 ₽ по двум проектам
/// (подставляются в `workDataProvider`, пока клиента Работы нет).
WorkData excelWorkData() => const WorkData(
  projects: [
    {
      'id': '01900000-0000-7000-8000-000000000701',
      'status': 'active',
      'client_id': '01900000-0000-7000-8000-000000000700',
      'base_amount': 2000000,
    },
    {
      'id': '01900000-0000-7000-8000-000000000702',
      'status': 'active',
      'client_id': '01900000-0000-7000-8000-000000000700',
      'base_amount': 6050000,
    },
  ],
);

/// Находит поле по ключу и вводит текст.
Future<void> enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

/// Прокручивает до элемента с ключом и нажимает его.
Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Текст поля ввода (`FormTextField` или `AmountField`) с ключом.
String fieldText(WidgetTester tester, String key) {
  final widget = tester.widget(find.byKey(Key(key)));
  if (widget is FormTextField) return widget.controller.text;
  if (widget is AmountField) return widget.controller.text;
  throw StateError('Не поле ввода: $key');
}

/// Текст виджета `Text` с ключом.
String textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;
