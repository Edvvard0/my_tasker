import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/work/data/work_context_source.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/work_env.dart';

void main() {
  const source = WorkContextSource();

  test('описание источника', () {
    expect(source.id, 'work');
    expect(source.label, 'Работа');
    expect(source.sensitive, isFalse);
    expect(source.description, isNotEmpty);
    expect(source.defaultFilter, {'period': 'month'});
    expect(source.filters.single.options.keys, ['month', 'week', 'all']);
    expect(source.summary(const {'period': 'week'}), 'часы за неделю');
    expect(source.summary(const {'period': 'all'}), 'часы за всё время');
    expect(source.summary(const {}), 'часы за месяц');
  });

  testWidgets('нет проектов — нет строк', (tester) async {
    final container = await pumpWork(tester);
    final env = container.read(contextEnvProvider)();
    expect(await source.lines(env, source.defaultFilter), isEmpty);
  });

  testWidgets('должники, часы за месяц и проекты по убыванию остатка', (
    tester,
  ) async {
    final container = await pumpWork(tester, seed: true);
    final env = container.read(contextEnvProvider)();
    final lines = (await tester.runAsync(
      () => source.lines(env, source.defaultFilter),
    ))!;
    expect(lines[0], '- Мне должны всего: ${nb('80 500 ₽')}');
    expect(
      lines[1],
      '- Долг · Елена: ${nb('55 500 ₽')} (Платформа Creora ${nb('55 500 ₽')})',
    );
    expect(
      lines[2],
      '- Долг · Рома: ${nb('25 000 ₽')} (SaaS Лены ${nb('20 000 ₽')}, '
      'Бот разборов ИИ ${nb('5 000 ₽')})',
    );
    expect(
      lines[3],
      '- Часы за месяц: 34 ч · получено ${nb('19 000 ₽')} · доход в час по '
      'факту ${nb('558,82 ₽')}/ч, по начисленному ${nb('0 ₽')}/ч',
    );
    expect(
      lines[4],
      startsWith('- проект «Платформа Creora» · в работе · Елена'),
    );
    expect(lines[4], contains('остаток ${nb('55 500 ₽')}'));
    expect(lines[4], contains('срок 2026-11-30'));
    expect(lines[5], startsWith('- проект «SaaS Лены»'));
    expect(lines[6], startsWith('- проект «Бот разборов ИИ»'));
    expect(lines[6], contains('получено ${nb('21 000 ₽')} (80,7 %)'));
    expect(lines, hasLength(7));
  });

  testWidgets('неделя, всё время; архив и переплата', (tester) async {
    final container = await pumpWork(tester, seed: true);
    final repo = container.read(workRepositoryProvider);
    final env = container.read(contextEnvProvider)();
    final week = (await tester.runAsync(
      () => source.lines(env, {'period': 'week'}),
    ))!;
    // Неделя 28 сент.–4 окт.: 8 ч у Creora, получено 0.
    expect(
      week[3],
      startsWith('- Часы за неделю: 8 ч · получено ${nb('0 ₽')}'),
    );
    final all = (await tester.runAsync(
      () => source.lines(env, {'period': 'all'}),
    ))!;
    // Всего 14 + 24 + 4 ч… Бот 14 ч, Creora 24 ч = 38 ч.
    expect(
      all[3],
      startsWith('- Часы за всё время: 38 ч · получено ${nb('45 500 ₽')}'),
    );

    final saas = projectIdOf(container, 'SaaS Лены');
    late List<String> after;
    await tester.runAsync(() async {
      await repo.createPayment(
        Payment(id: repo.newId(), paidAt: msk(2026, 9, 29), amount: 2500000),
        [AllocationDraft(projectId: saas, amount: 2500000)],
      );
      await repo.setProjectStatus(saas, ProjectStatus.completed);
      await repo.setArchived(saas, archived: true);
      after = await source.lines(
        container.read(contextEnvProvider)(),
        source.defaultFilter,
      );
    });
    expect(after.any((l) => l.contains('SaaS Лены')), isFalse);
    expect(after[0], '- Мне должны всего: ${nb('60 500 ₽')}');
  });

  testWidgets('переплата проекта и неизвестный заказчик', (tester) async {
    final container = await pumpWork(tester);
    final repo = container.read(workRepositoryProvider);
    late List<String> lines;
    await tester.runAsync(() async {
      final id = repo.newId();
      await repo.createProject(
        WorkProject(id: id, title: 'Сайт', baseAmount: 100000),
      );
      await repo.createPayment(
        Payment(id: repo.newId(), paidAt: msk(2026, 9, 29), amount: 150000),
        [AllocationDraft(projectId: id, amount: 150000)],
      );
      lines = await source.lines(
        container.read(contextEnvProvider)(),
        source.defaultFilter,
      );
    });
    expect(lines[0], '- Мне должны всего: ${nb('0 ₽')}');
    expect(lines.last, contains('заказчик не указан'));
    expect(lines.last, contains('переплата ${nb('500 ₽')}'));
    expect(lines.last, isNot(contains('срок')));
  });

  testWidgets('раздел «Работа» собирается в контекст чата', (tester) async {
    final container = await pumpWork(tester, seed: true);
    final builder = container.read(contextBuilderProvider);
    final env = container.read(contextEnvProvider)();
    final pack = (await tester.runAsync(
      () => builder.build([
        const ContextSourceRef(source: 'work', tokenLimit: 2000),
      ], env),
    ))!;
    expect(pack.sections.single.label, 'Работа');
    expect(pack.text, contains('## Работа (часы за месяц)'));
    expect(pack.text, contains('Мне должны всего'));
    expect(pack.containsSensitive, isFalse);
    expect(
      container.read(contextSourcesProvider).map((s) => s.id),
      contains('work'),
    );
  });
}
