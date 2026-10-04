import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/finance/data/finance_context_source.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../../support/finance_env.dart';

void main() {
  const source = FinanceContextSource();

  test('описание источника: чувствительный, фильтр периода', () {
    expect(source.id, 'finance');
    expect(source.label, 'Финансы');
    expect(source.description, contains('локальной модели'));
    // Суммы нельзя отправлять в облако (spec Этапа 3, 1.3 и 5.2).
    expect(source.sensitive, isTrue);
    expect(source.defaultFilter, {'period': 'month'});
    expect(source.filters.single.options.keys, ['month', 'quarter', 'all']);
    expect(
      source.summary(const {'period': 'quarter'}),
      'доход и расход за три месяца',
    );
    expect(
      source.summary(const {'period': 'all'}),
      'доход и расход за всё время',
    );
    expect(source.summary(const {}), 'доход и расход за месяц');
  });

  test('сборщик контекста помечает пакет чувствительным без чтения данных', () {
    const builder = ContextBuilder([FinanceContextSource()]);
    expect(
      builder.isSensitive(const [ContextSourceRef(source: 'finance')]),
      isTrue,
    );
  });

  testWidgets('нет данных — нет строк', (tester) async {
    final container = await pumpFinance(tester);
    final env = container.read(contextEnvProvider)();
    expect(await source.lines(env, source.defaultFilter), isEmpty);
  });

  testWidgets('счета, месяц по категориям, долги, цель по формуле', (
    tester,
  ) async {
    final container = await pumpFinance(tester, seed: true);
    final env = container.read(contextEnvProvider)();
    final lines = (await tester.runAsync(
      () => source.lines(env, source.defaultFilter),
    ))!;
    expect(lines[0], '- Общий баланс: ${nb('361 000 ₽')}');
    expect(lines.where((l) => l.startsWith('- счёт «')), hasLength(4));
    expect(lines, contains('- счёт «Наличные» · наличные · ${nb('54 000 ₽')}'));
    expect(
      lines,
      contains('- счёт «Кредитка» · кредитная карта · ${nb('125 000 ₽')}'),
    );
    expect(
      lines,
      contains(
        '- Доход за месяц: ${nb('85 000 ₽')} · расход: ${nb('11 500 ₽')} · '
        'итог: ${nb('73 500 ₽')}',
      ),
    );
    expect(
      lines,
      contains(
        '- Расходы по категориям за месяц: Продукты ${nb('6 500 ₽')}, '
        'Кафе и рестораны ${nb('3 000 ₽')}, Транспорт ${nb('2 000 ₽')}',
      ),
    );
    expect(
      lines,
      contains(
        '- Мне должны (открытые долги): ${nb('13 100 ₽')} · я должен: '
        '${nb('0 ₽')}',
      ),
    );
    expect(
      lines,
      contains(
        '- Долг · мне должны · Паша: осталось ${nb('7 500 ₽')} из '
        '${nb('7 500 ₽')} · срок 2026-10-15',
      ),
    );
    expect(
      lines,
      contains('- Ожидаемые поступления из «Работы»: ${nb('80 500 ₽')}'),
    );
    expect(
      lines.last,
      '- цель «Подушка» · есть ${nb('454 600 ₽')} из ${nb('400 000 ₽')} '
      '(113,6 %) · цель достигнута, запас ${nb('54 600 ₽')} · срок 2026-11-15',
    );
  });

  testWidgets('период: три месяца и всё время включают август', (tester) async {
    final container = await pumpFinance(tester, seed: true);
    final env = container.read(contextEnvProvider)();
    for (final period in ['quarter', 'all']) {
      final lines = (await tester.runAsync(
        () => source.lines(env, {'period': period}),
      ))!;
      final caption = period == 'quarter' ? 'за три месяца' : 'за всё время';
      expect(
        lines,
        contains(
          '- Доход $caption: ${nb('85 000 ₽')} · расход: ${nb('18 500 ₽')} · '
          'итог: ${nb('66 500 ₽')}',
        ),
        reason: period,
      );
    }
  });

  testWidgets('закрытые долги и архивные счета не попадают; погашение '
      'уменьшает остаток', (tester) async {
    late FinanceDemo demo;
    final container = await pumpFinance(
      tester,
      seedWith: (c) async {
        demo = await seedFinanceDemo(c);
        final repo = c.read(financeRepositoryProvider);
        await repo.setAccountArchived(demo.cash, archived: true);
        final sasha = (await repo.getDebt(demo.debtSasha))!;
        await repo.repayDebt(
          debt: sasha,
          amount: 300000,
          repaidOn: '2026-09-20',
        );
        final masha = (await repo.getDebt(demo.debtMasha))!;
        await repo.repayDebt(
          debt: masha,
          amount: 60000,
          repaidOn: '2026-09-20',
        );
      },
    );
    final env = container.read(contextEnvProvider)();
    final lines = (await tester.runAsync(
      () => source.lines(env, source.defaultFilter),
    ))!;
    expect(lines.where((l) => l.contains('«Наличные»')), isEmpty);
    expect(lines.where((l) => l.contains('Саша')), isEmpty);
    expect(
      lines,
      contains(
        '- Долг · мне должны · Маша: осталось ${nb('2 000 ₽')} из '
        '${nb('2 600 ₽')}',
      ),
    );
    expect(
      lines,
      contains(
        '- Мне должны (открытые долги): ${nb('9 500 ₽')} · я должен: '
        '${nb('0 ₽')}',
      ),
    );
  });

  testWidgets('цель не достигнута: «не хватает»; просроченный долг '
      'помечен; «я должен»', (tester) async {
    final container = await pumpFinance(
      tester,
      seedWith: (c) async {
        final repo = c.read(financeRepositoryProvider);
        await repo.createDebt(
          Debt(
            id: repo.newId(),
            direction: DebtDirection.iOwe,
            counterparty: 'Банк',
            amount: 500000,
            debtDate: '2026-08-01',
            dueDate: '2026-09-01',
          ),
        );
        await repo.createGoal(
          Goal(
            id: repo.newId(),
            name: 'Машина',
            targetAmount: 100000000,
            formula: const [GoalTerm(kind: GoalTermKind.myDebts, plus: false)],
          ),
        );
      },
    );
    final env = container.read(contextEnvProvider)();
    final lines = (await tester.runAsync(
      () => source.lines(env, source.defaultFilter),
    ))!;
    expect(
      lines,
      contains(
        '- Долг · я должен · Банк: осталось ${nb('5 000 ₽')} из '
        '${nb('5 000 ₽')} · срок 2026-09-01 (просрочен)',
      ),
    );
    expect(
      lines.last,
      '- цель «Машина» · есть -${nb('5 000 ₽')} из ${nb('1 000 000 ₽')} '
      '(0 %) · не хватает ${nb('1 005 000 ₽')}',
    );
  });
}
