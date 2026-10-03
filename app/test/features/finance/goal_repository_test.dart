import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

Goal _goal(
  int n, {
  String name = 'Отпуск',
  int target = 40000000,
  String? deadline,
  List<GoalTerm>? formula,
  bool archived = false,
}) => Goal(
  id: uuid(n),
  name: name,
  targetAmount: target,
  deadlineDate: deadline,
  formula: formula ?? defaultGoalFormula(),
  archived: archived,
);

Account _account(
  int n, {
  int opening = 1000000,
  bool inTotal = true,
  bool archived = false,
  AccountKind kind = AccountKind.debitCard,
}) => Account(
  id: uuid(n),
  name: 'Счёт $n',
  kind: kind,
  openingBalance: opening,
  openingDate: '2026-01-01',
  includeInTotal: inTotal,
  archived: archived,
);

/// Рубли -> копейки.
int _r(int rubles) => rubles * 100;

/// Проекты «Работы» из Excel заказчика: Рома должен 20 000 + 60 500 ₽.
WorkData _romaWork() => WorkData(
  projects: [
    {
      'id': uuid(701),
      'status': 'active',
      'client_id': uuid(700),
      'base_amount': _r(20000),
    },
    {
      'id': uuid(702),
      'status': 'active',
      'client_id': uuid(700),
      'base_amount': _r(60500),
    },
  ],
);

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late FinanceDevice d;
  late FinanceRepository repo;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    d = await FinanceDevice.create(
      server,
      clock: clock,
      newId: () => uuid(900 + ++counter),
    );
    repo = d.finance;
  });
  tearDown(() async {
    await d.close();
    await server.dispose();
  });

  Future<List<OutboxOp>> ops() => d.device.store.outbox();

  Future<String?> problem(Future<Object?> action) async {
    try {
      await action;
    } on ValidationError catch (e) {
      return e.message;
    }
    return null;
  }

  /// Excel заказчика: счета 54 000 + 174 000 + 8 000 + кредитка 125 000 и
  /// долги мне 7 500 + 2 600 + 3 000.
  Future<void> seedExcel() async {
    await repo.createAccount(_account(1, opening: _r(54000)));
    await repo.createAccount(_account(2, opening: _r(174000)));
    await repo.createAccount(
      _account(3, opening: _r(8000), kind: AccountKind.savings),
    );
    await repo.createAccount(
      _account(4, opening: _r(125000), kind: AccountKind.creditCard),
    );
    for (final (n, who, amount) in [
      (11, 'Эмир', 7500),
      (12, 'Bender', 2600),
      (13, 'Настя', 3000),
    ]) {
      await repo.createDebt(
        Debt(
          id: uuid(n),
          direction: DebtDirection.owedToMe,
          counterparty: who,
          amount: _r(amount),
          debtDate: '2026-09-01',
        ),
      );
    }
  }

  group('цели: CRUD', () {
    test('создание, чтение, обрезка названия, порядок по созданию', () async {
      await repo.createGoal(_goal(2, name: '  Ноутбук '));
      clock.advance(const Duration(seconds: 1));
      await repo.createGoal(_goal(1, deadline: '2026-12-31'));
      final all = await repo.goals();
      expect(all.map((g) => g.name), ['Ноутбук', 'Отпуск']);
      final got = (await repo.getGoal(uuid(1)))!;
      expect(got.deadlineDate, '2026-12-31');
      expect(got.formula, defaultGoalFormula());
      expect(got.archived, isFalse);
      expect(await repo.getGoal('нет'), isNull);
      final queue = await ops();
      expect(queue.map((o) => o.table), ['goals', 'goals']);
      expect(queue.first.fields!['name'], 'Ноутбук');
      // формула уходит JSON-списком, слагаемое receivables — как есть
      expect(queue.first.fields!['formula'], [
        {'kind': 'all_accounts', 'sign': '+'},
        {'kind': 'debts_to_me', 'sign': '+'},
        {'kind': 'receivables', 'sign': '+', 'client_ids': null},
      ]);
    });

    test('значения проверяются до записи в outbox', () async {
      final bad = <Goal>[
        _goal(1, name: ''),
        _goal(1, name: '  '),
        _goal(1, name: 'x' * 201),
        _goal(1, target: 0),
        _goal(1, target: 99999999999999 + 1),
        _goal(1, deadline: '2026-02-30'),
        _goal(1, formula: const []),
        _goal(1, formula: const [GoalTerm(kind: GoalTermKind.accounts)]),
        _goal(
          1,
          formula: [
            for (var i = 0; i < 31; i++)
              const GoalTerm(kind: GoalTermKind.myDebts),
          ],
        ),
      ];
      for (final b in bad) {
        expect(await problem(repo.createGoal(b)), isNotNull, reason: '$b');
      }
      expect(await ops(), isEmpty);
      await repo.createGoal(_goal(1, name: 'x' * 200, target: 1));
      expect(await repo.goals(), hasLength(1));
    });

    test('повтор счёта в слагаемом схлопывается до сохранения', () async {
      await repo.createGoal(
        _goal(
          1,
          formula: [
            GoalTerm(
              kind: GoalTermKind.accounts,
              accountIds: [uuid(1), uuid(2), uuid(1)],
            ),
          ],
        ),
      );
      final saved = (await repo.getGoal(uuid(1)))!;
      expect(saved.formula.single.accountIds, [uuid(1), uuid(2)]);
    });

    test('правка уносит только изменившиеся колонки; формула — по '
        'содержимому', () async {
      await repo.createGoal(_goal(1));
      await d.device.sync();
      final before = (await ops()).length;
      await repo.updateGoal(
        (await repo.getGoal(uuid(1)))!
            .copyWith(targetAmount: 50000000, deadlineDate: '2027-01-15'),
      );
      var all = await ops();
      expect(all, hasLength(before + 1));
      expect(all.last.fields, {
        'target_amount': 50000000,
        'deadline_date': '2027-01-15',
      });
      // без изменений — ничего не уходит, даже формула (список ≠ по ссылке)
      await repo.updateGoal((await repo.getGoal(uuid(1)))!);
      expect(await ops(), hasLength(before + 1));
      // новая формула уходит целиком (после отправки — отдельной операцией)
      await d.device.sync();
      final next = (await repo.getGoal(uuid(1)))!.copyWith(
        formula: [
          ...defaultGoalFormula(),
          GoalTerm.initial(GoalTermKind.myDebts),
        ],
      );
      await repo.updateGoal(next);
      all = await ops();
      expect(all, hasLength(1));
      expect(all.single.fields!.keys, ['formula']);
      expect((all.single.fields!['formula']! as List).last, {
        'kind': 'my_debts',
        'sign': '-',
      });
      await expectLater(repo.updateGoal(_goal(77)), throwsA(isA<StateError>()));
      expect(await problem(repo.updateGoal(_goal(1, name: ''))), isNotNull);
    });

    test(
      'архив и возврат из архива: только колонка archived, расчёт тот же',
      () async {
        await seedExcel();
        await repo.createGoal(_goal(1));
        await d.device.sync();
        final before = (await ops()).length;
        final value = (await repo.goalsOverview()).byId(uuid(1))!.progress.have;
        await repo.archiveGoal(uuid(1));
        expect((await repo.getGoal(uuid(1)))!.archived, isTrue);
        expect(await repo.goals(includeArchived: false), isEmpty);
        expect(await repo.goals(), hasLength(1));
        var all = await ops();
        expect(all, hasLength(before + 1));
        expect(all.last.fields, {'archived': true});
        await repo.archiveGoal(uuid(1)); // уже в архиве — ничего
        expect(await ops(), hasLength(before + 1));
        expect(
          (await repo.goalsOverview()).byId(uuid(1))!.progress.have,
          value,
        );
        await repo.archiveGoal(uuid(1), archived: false);
        expect((await repo.getGoal(uuid(1)))!.archived, isFalse);
        all = await ops();
        expect(all.last.fields, {'archived': false});
        await repo.archiveGoal('нет'); // нет такой — тихо
      },
    );

    test('удаление в корзину и восстановление: одна операция, цель '
        'скрывается и возвращается', () async {
      await repo.createGoal(_goal(1));
      await d.device.sync();
      await repo.deleteGoal(uuid(1));
      final queue = await ops();
      expect(queue, hasLength(1));
      expect(queue.single.type, 'delete');
      expect(queue.single.table, 'goals');
      expect(await repo.goals(), isEmpty);
      expect((await repo.goalsOverview()).isEmpty, isTrue);
      await repo.restoreGoal(uuid(1));
      expect(await repo.goals(), hasLength(1));
    });

    test('watchGoals отдаёт изменения', () async {
      final seen = <int>[];
      final sub = repo
          .watchGoals(includeArchived: false)
          .listen((g) => seen.add(g.length));
      addTearDown(sub.cancel);
      await repo.createGoal(_goal(1));
      await repo.createGoal(_goal(2, name: 'Б'));
      await repo.archiveGoal(uuid(2));
      for (var i = 0; i < 40 && seen.lastOrNull != 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(seen.last, 1);
    });
  });

  group('«Есть» цели: Excel заказчика (spec 6.3)', () {
    test('формула по умолчанию: данные Работы подставлены — 454 600, '
        'профицит 54 600, 113,6 %', () async {
      await seedExcel();
      await repo.createGoal(_goal(1));
      final state = (await repo.goalsOverview(work: _romaWork()))
          .byId(uuid(1))!;
      final p = state.progress;
      expect(p.have, _r(454600));
      expect(p.target, _r(400000));
      expect(p.missing, -_r(54600));
      expect(p.reached, isTrue);
      expect(p.surplus, _r(54600));
      expect(p.progressBp, 11365);
      expect(p.percentText, '113,6');
      expect(p.barFraction, 1);
      expect(p.terms.map((t) => t.value), [_r(361000), _r(13100), _r(80500)]);
      expect(p.terms.map((t) => t.term.kind), [
        GoalTermKind.allAccounts,
        GoalTermKind.debtsToMe,
        GoalTermKind.receivables,
      ]);
    });

    test('формула с тремя счетами (без кредитки): 329 600, не хватает '
        '70 400', () async {
      await seedExcel();
      await repo.createGoal(
        _goal(
          1,
          formula: [
            GoalTerm(
              kind: GoalTermKind.accounts,
              accountIds: [uuid(1), uuid(2), uuid(3)],
            ),
            const GoalTerm(kind: GoalTermKind.debtsToMe),
            const GoalTerm(kind: GoalTermKind.receivables),
          ],
        ),
      );
      final p = (await repo.goalsOverview(work: _romaWork()))
          .byId(uuid(1))!
          .progress;
      expect(p.have, _r(329600));
      expect(p.missing, _r(70400));
      expect(p.reached, isFalse);
      expect(p.surplus, 0);
      expect(p.progressBp, 8240);
      expect(p.percentText, '82,4');
    });

    test('без данных Работы (как в приложении сейчас) receivables = 0: '
        '361 000 + 13 100 = 374 100', () async {
      await seedExcel();
      await repo.createGoal(_goal(1));
      final p = (await repo.goalsOverview()).byId(uuid(1))!.progress;
      expect(p.have, _r(374100));
      expect(p.missing, _r(25900));
      expect(p.terms.last.value, 0);
      expect(p.terms.last.term.kind, GoalTermKind.receivables);
      // формула при этом хранится как есть, со слагаемым receivables
      expect((await repo.getGoal(uuid(1)))!.hasReceivables, isTrue);
    });

    test(
      '«мои долги» со знаком «−» вычитаются; заказчики с client_ids',
      () async {
        await seedExcel();
        await repo.createDebt(
          Debt(
            id: uuid(14),
            direction: DebtDirection.iOwe,
            counterparty: 'Влад',
            amount: _r(15000),
            debtDate: '2026-09-01',
          ),
        );
        await repo.createGoal(
          _goal(
            1,
            formula: [
              const GoalTerm(kind: GoalTermKind.allAccounts),
              GoalTerm.initial(GoalTermKind.myDebts),
              GoalTerm(kind: GoalTermKind.receivables, clientIds: [uuid(700)]),
              GoalTerm(
                kind: GoalTermKind.receivables,
                sign: GoalSign.minus,
                clientIds: [uuid(799)],
              ),
            ],
          ),
        );
        final p = (await repo.goalsOverview(work: _romaWork()))
            .byId(uuid(1))!
            .progress;
        expect(p.terms.map((t) => t.value), [
          _r(361000),
          -_r(15000),
          _r(80500),
          0,
        ]);
        expect(p.have, _r(361000) - _r(15000) + _r(80500));
      },
    );

    test('«Есть» следует за балансами: операции, сверка, архив счёта, '
        'удалённый счёт', () async {
      await repo.createAccount(_account(1, opening: _r(1000)));
      await repo.createAccount(_account(2, opening: _r(500), inTotal: false));
      await repo.createGoal(
        _goal(
          1,
          target: _r(2000),
          formula: [
            GoalTerm(
              kind: GoalTermKind.accounts,
              accountIds: [uuid(1), uuid(2)],
            ),
          ],
        ),
      );
      Future<int> have() async =>
          (await repo.goalsOverview()).byId(uuid(1))!.progress.have;
      // accounts считает счёт независимо от include_in_total
      expect(await have(), _r(1500));
      await repo.createTransaction(
        FinanceTransaction(
          id: uuid(50),
          kind: TransactionKind.income,
          accountId: uuid(1),
          amount: _r(300),
          occurredAt: DateTime.utc(2026, 10, 1, 9),
        ),
      );
      expect(await have(), _r(1800));
      await repo.reconcile(accountId: uuid(2), actualBalance: _r(700));
      expect(await have(), _r(2000));
      await repo.archiveAccount(uuid(2));
      expect(await have(), _r(2000), reason: 'архив счёта на расчёт не влияет');
      await repo.deleteAccount(uuid(2));
      expect(await have(), _r(1300), reason: 'удалённый счёт — 0');
      await repo.restoreAccount(uuid(2));
      expect(await have(), _r(2000));
    });

    test('нулевой и отрицательный «Есть»: прогресс 0, полоса пустая', () async {
      await repo.createAccount(_account(1, opening: -_r(5000)));
      await repo.createGoal(
        _goal(1, formula: const [GoalTerm(kind: GoalTermKind.allAccounts)]),
      );
      final p = (await repo.goalsOverview()).byId(uuid(1))!.progress;
      expect(p.have, -_r(5000));
      expect(p.progressBp, 0);
      expect(p.barFraction, 0);
      expect(p.missing, _r(405000));
      expect(p.percentText, '0,0');
    });

    test('активные цели: ближайший срок выше, затем без срока; архив '
        'отдельно', () async {
      await repo.createGoal(_goal(1, name: 'Без срока'));
      clock.advance(const Duration(seconds: 1));
      await repo.createGoal(_goal(2, name: 'Поздно', deadline: '2027-06-01'));
      clock.advance(const Duration(seconds: 1));
      await repo.createGoal(_goal(3, name: 'Скоро', deadline: '2026-11-01'));
      clock.advance(const Duration(seconds: 1));
      await repo.createGoal(_goal(4, name: 'Старая', archived: true));
      final overview = await repo.goalsOverview();
      expect(overview.active.map((s) => s.goal.name), [
        'Скоро',
        'Поздно',
        'Без срока',
      ]);
      expect(overview.archived.map((s) => s.goal.name), ['Старая']);
    });
  });

  group('basisPointsText и формула', () {
    test('процент усечением до одной цифры', () {
      expect(basisPointsText(11365), '113,6');
      expect(basisPointsText(7030), '70,3');
      expect(basisPointsText(9999), '99,9');
      expect(basisPointsText(10000), '100,0');
      expect(basisPointsText(5), '0,0');
      expect(basisPointsText(0), '0,0');
      expect(basisPointsText(-100), '0,0');
    });

    test('GoalTerm: JSON-круг, свои ключи, значения по умолчанию', () {
      expect(defaultGoalFormula().map((t) => t.toJson()), [
        {'kind': 'all_accounts', 'sign': '+'},
        {'kind': 'debts_to_me', 'sign': '+'},
        {'kind': 'receivables', 'sign': '+', 'client_ids': null},
      ]);
      expect(GoalTerm.initial(GoalTermKind.myDebts).sign, GoalSign.minus);
      for (final k in GoalTermKind.values) {
        if (k != GoalTermKind.myDebts) {
          expect(GoalTerm.initial(k).sign, GoalSign.plus, reason: k.wire);
        }
      }
      final accounts = GoalTerm(
        kind: GoalTermKind.accounts,
        sign: GoalSign.minus,
        accountIds: [uuid(1)],
      );
      expect(GoalTerm.tryParse(accounts.toJson()), accounts);
      expect(GoalTerm.tryParse(accounts.toJson())!.hashCode, accounts.hashCode);
      final receivables = GoalTerm(
        kind: GoalTermKind.receivables,
        clientIds: [uuid(2)],
      );
      expect(GoalTerm.tryParse(receivables.toJson()), receivables);
      expect(GoalTerm.tryParse({'kind': 'x', 'sign': '+'}), isNull);
      expect(GoalTerm.tryParse({'kind': 'my_debts', 'sign': '*'}), isNull);
      expect(GoalTerm.tryParse('мусор'), isNull);
      // у слагаемого без списка счетов JSON всё равно корректен
      expect(const GoalTerm(kind: GoalTermKind.accounts).toJson(), {
        'kind': 'accounts',
        'sign': '+',
        'account_ids': <String>[],
      });
    });

    test('formulaOverlap: только счета «в общем балансе» и только с '
        'all_accounts', () {
      final accounts = [_account(1), _account(2, inTotal: false), _account(3)];
      List<GoalTerm> formula({bool all = true}) => [
        if (all) const GoalTerm(kind: GoalTermKind.allAccounts),
        GoalTerm(
          kind: GoalTermKind.accounts,
          accountIds: [uuid(1), uuid(2), uuid(9)],
        ),
      ];
      expect(formulaOverlap(formula(), accounts), {uuid(1)});
      expect(formulaOverlap(formula(all: false), accounts), isEmpty);
      expect(
        formulaOverlap(const [
          GoalTerm(kind: GoalTermKind.allAccounts),
        ], accounts),
        isEmpty,
      );
    });

    test('Goal.fromRow пропускает нечитаемые слагаемые', () {
      final row = <String, Object?>{
        'id': uuid(1),
        'name': 'Ц',
        'target_amount': 100,
        'deadline_date': null,
        'archived': false,
        'formula': [
          {'kind': 'my_debts', 'sign': '-'},
          {'kind': 'неизвестно', 'sign': '+'},
          5,
        ],
      };
      final goal = Goal.fromRow(row);
      expect(goal.formula, [GoalTerm.initial(GoalTermKind.myDebts)]);
      final empty = <String, Object?>{
        'id': 'x',
        'name': 'Ц',
        'target_amount': 1,
        'archived': true,
        'formula': null,
      };
      expect(Goal.fromRow(empty).formula, isEmpty);
    });
  });

  test('Json-тип строки цели совпадает с колонками реестра', () {
    final fields = _goal(1).toFields();
    expect(fields.keys, [
      'name',
      'target_amount',
      'deadline_date',
      'formula',
      'archived',
    ]);
    expect(_goal(1).toRow()['id'], uuid(1));
  });
}
