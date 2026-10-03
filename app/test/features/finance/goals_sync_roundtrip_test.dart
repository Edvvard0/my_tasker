import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/finance_env.dart';
import '../../support/manual_clock.dart';

/// Цели через общий клиентский стек синхронизации и фейковый сервер:
/// «создал офлайн — сеть появилась — всё на втором устройстве»; формула со
/// слагаемым `receivables` доезжает без изменений; слияние правок разных
/// полей; корзина и восстановление.
void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late FinanceDevice phone;
  late FinanceDevice pc;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => uuid(1000 + ++counter);
    phone = await FinanceDevice.create(server, clock: clock, newId: next);
    pc = await FinanceDevice.create(server, clock: clock, newId: next);
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
  }

  Goal goal({
    int n = 10,
    String name = 'Отпуск',
    List<GoalTerm>? formula,
    String? deadline = '2026-12-31',
  }) => Goal(
    id: uuid(n),
    name: name,
    targetAmount: 40000000,
    deadlineDate: deadline,
    formula: formula ?? defaultGoalFormula(),
  );

  test('офлайн: цель с формулой по умолчанию доезжает до второго '
      'устройства без изменений (receivables сохраняется)', () async {
    phone.device.remote.faults.offline = true;
    await phone.finance.createAccount(
      Account(
        id: uuid(1),
        name: 'Карта',
        kind: AccountKind.debitCard,
        openingBalance: 36100000,
        openingDate: '2026-01-01',
      ),
    );
    await phone.finance.createDebt(
      Debt(
        id: uuid(20),
        direction: DebtDirection.owedToMe,
        counterparty: 'Эмир',
        amount: 1310000,
        debtDate: '2026-09-01',
      ),
    );
    await phone.finance.createGoal(goal());
    expect(await phone.device.sync(), SyncOutcome.offline);
    phone.device.remote.faults.offline = false;
    expect(await phone.device.sync(), SyncOutcome.success);
    expect(await pc.device.sync(), SyncOutcome.success);

    final got = (await pc.finance.getGoal(uuid(10)))!;
    expect(got.name, 'Отпуск');
    expect(got.targetAmount, 40000000);
    expect(got.deadlineDate, '2026-12-31');
    expect(got.archived, isFalse);
    expect(formulaToJson(got.formula), [
      {'kind': 'all_accounts', 'sign': '+'},
      {'kind': 'debts_to_me', 'sign': '+'},
      {'kind': 'receivables', 'sign': '+', 'client_ids': null},
    ]);
    // на сервере формула лежит ровно так, как её ввёл клиент
    expect(server.snapshot('goals').values.single['formula'], [
      {'kind': 'all_accounts', 'sign': '+'},
      {'kind': 'debts_to_me', 'sign': '+'},
      {'kind': 'receivables', 'sign': '+', 'client_ids': null},
    ]);
    // «Есть» на втором устройстве совпадает с первым (Работы там тоже нет)
    final a = (await phone.finance.goalsOverview()).byId(uuid(10))!.progress;
    final b = (await pc.finance.goalsOverview()).byId(uuid(10))!.progress;
    expect(b.have, 37410000);
    expect(b.have, a.have);
    expect(b.missing, a.missing);
    expect(b.progressBp, 9352);
    // …а с данными Работы на втором устройстве формула посчитается полностью
    final full = (await pc.finance.goalsOverview(
      work: const WorkData(
        projects: [
          {
            'id': 'p',
            'status': 'active',
            'client_id': null,
            'base_amount': 8050000,
          },
        ],
      ),
    )).byId(uuid(10))!.progress;
    expect(full.have, 37410000 + 8050000);
  });

  test('формула со всеми видами слагаемых, знаками и списками id '
      'сохраняется побайтно', () async {
    final formula = [
      GoalTerm(
        kind: GoalTermKind.accounts,
        sign: GoalSign.minus,
        accountIds: [uuid(1), uuid(2)],
      ),
      const GoalTerm(kind: GoalTermKind.allAccounts),
      const GoalTerm(kind: GoalTermKind.debtsToMe),
      GoalTerm.initial(GoalTermKind.myDebts),
      GoalTerm(kind: GoalTermKind.receivables, clientIds: [uuid(700)]),
    ];
    await phone.finance.createGoal(goal(formula: formula, deadline: null));
    await syncBoth();
    final got = (await pc.finance.getGoal(uuid(10)))!;
    expect(got.formula, formula);
    expect(got.deadlineDate, isNull);
    expect(formulaToJson(got.formula), formulaToJson(formula));
  });

  test(
    'правки разных полей с двух устройств сливаются; архив и срок',
    () async {
      await phone.finance.createGoal(goal());
      await syncBoth();
      clock.advance(const Duration(minutes: 5));
      await phone.finance.updateGoal(
        (await phone.finance.getGoal(uuid(10)))!
            .copyWith(targetAmount: 50000000),
      );
      await pc.finance.updateGoal(
        (await pc.finance.getGoal(uuid(10)))!
            .copyWith(deadlineDate: '2027-02-01'),
      );
      await pc.finance.archiveGoal(uuid(10));
      await syncBoth();
      for (final d in [phone, pc]) {
        final g = (await d.finance.getGoal(uuid(10)))!;
        expect(g.targetAmount, 50000000);
        expect(g.deadlineDate, '2027-02-01');
        expect(g.archived, isTrue);
      }
    },
  );

  test(
    'правка формулы на одном устройстве не затирает название с другого',
    () async {
      await phone.finance.createGoal(goal());
      await syncBoth();
      clock.advance(const Duration(minutes: 5));
      await phone.finance.updateGoal(
        (await phone.finance.getGoal(uuid(10)))!.copyWith(
          formula: [
            ...defaultGoalFormula(),
            GoalTerm.initial(GoalTermKind.myDebts),
          ],
        ),
      );
      await pc.finance.updateGoal(
        (await pc.finance.getGoal(uuid(10)))!.copyWith(name: 'Отпуск мечты'),
      );
      await syncBoth();
      final g = (await phone.finance.getGoal(uuid(10)))!;
      expect(g.name, 'Отпуск мечты');
      expect(g.formula, hasLength(4));
      expect(g.formula.last, GoalTerm.initial(GoalTermKind.myDebts));
      expect((await pc.finance.getGoal(uuid(10)))!.formula, hasLength(4));
    },
  );

  test('удаление: одна операция, цель скрывается на втором устройстве, '
      'восстановление возвращает', () async {
    await phone.finance.createGoal(goal());
    await phone.finance.createGoal(goal(n: 11, name: 'Ноутбук'));
    await syncBoth();
    expect(await pc.finance.goals(), hasLength(2));
    await phone.finance.deleteGoal(uuid(10));
    final queue = await phone.device.store.outbox();
    expect(queue, hasLength(1));
    expect(queue.single.type, 'delete');
    expect(queue.single.table, 'goals');
    await syncBoth();
    expect((await pc.finance.goals()).map((g) => g.name), ['Ноутбук']);
    final row = server.snapshot('goals')[uuid(10)]!;
    expect(row['deleted_at'], isNotNull);
    // без каскадов: вторая цель на месте
    expect(server.snapshot('goals')[uuid(11)]!['deleted_at'], isNull);
    await pc.finance.restoreGoal(uuid(10));
    await syncBoth();
    expect(await phone.finance.goals(), hasLength(2));
    expect(
      (await phone.finance.getGoal(uuid(10)))!.formula,
      defaultGoalFormula(),
    );
  });

  test('сервер отклоняет недопустимую формулу — клиент до этого не '
      'допускает', () async {
    // 31 слагаемое клиент не запишет; цель на сервере остаётся валидной
    await expectLater(
      phone.finance.createGoal(
        goal(
          formula: [
            for (var i = 0; i < 31; i++)
              const GoalTerm(kind: GoalTermKind.myDebts),
          ],
        ),
      ),
      throwsA(isA<ValidationError>()),
    );
    await syncBoth();
    expect(server.snapshot('goals'), isEmpty);
  });
}
