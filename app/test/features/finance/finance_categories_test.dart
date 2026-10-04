import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';

import '../../support/finance_env.dart';

Future<List<FinCategory>> _categories(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(
  () async => [
    for (final r in await c.read(syncStoreProvider).visibleRows('categories'))
      FinCategory.fromRow(r),
  ],
))!;

void main() {
  Future<ProviderContainer> pump(WidgetTester tester, {bool seed = true}) =>
      pumpFinance(tester, location: '/finance/categories', seed: seed);

  group('«Категории»', () {
    testWidgets('предустановленные расходы деревом и доходы', (tester) async {
      await pump(tester);
      expect(find.text('Продукты'), findsOneWidget);
      expect(find.text('Транспорт'), findsOneWidget);
      // Подкатегория видна под родителем.
      expect(find.text('Такси'), findsOneWidget);
      expect(find.text('Общественный транспорт'), findsOneWidget);
      expect(find.text('Зарплата'), findsNothing);
      await tapKey(tester, 'categories-kind-income');
      expect(find.text('Зарплата'), findsOneWidget);
      expect(find.text('Доход с проектов'), findsOneWidget);
      expect(find.text('Продукты'), findsNothing);
    });

    testWidgets('пусто: «Стандартный набор» засевает 28 категорий', (
      tester,
    ) async {
      final container = await pump(tester, seed: false);
      expect(find.byKey(const Key('categories-empty')), findsOneWidget);
      await tester.tap(find.byKey(const Key('categories-seed')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(await _categories(tester, container), hasLength(28));
      expect(find.text('Продукты'), findsOneWidget);
    });

    testWidgets('пусто: своя категория; без стандартного набора после '
        'удаления всех', (tester) async {
      final container = await pump(tester, seed: false);
      await tapKey(tester, 'categories-empty-add');
      await tester.enterText(find.byKey(const Key('category-name')), 'Хобби');
      await tapKey(tester, 'category-save');
      final cats = await _categories(tester, container);
      expect(cats.single.name, 'Хобби');
      expect(cats.single.kind, CategoryKind.expense);
      expect(cats.single.parentId, isNull);
      expect(cats.single.systemKey, isNull);
      expect(find.text('Хобби'), findsOneWidget);
      // Категории уже есть — «Стандартный набор» не предлагается на другом
      // виде, а создать свою можно.
      await tapKey(tester, 'categories-kind-income');
      expect(find.byKey(const Key('categories-seed')), findsNothing);
      expect(find.byKey(const Key('categories-empty-add')), findsOneWidget);
    });

    testWidgets('правка предустановленной: имя, иконка; system_key цел', (
      tester,
    ) async {
      final container = await pump(tester);
      final id = categoryPresetId('expense.groceries');
      await tapKey(tester, 'category-$id');
      expect(
        find.textContaining('Предустановленная категория'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('category-name')), 'Еда');
      await tapKey(tester, 'category-icon-coins');
      await tapKey(tester, 'category-save');
      final cat = (await _categories(
        tester,
        container,
      )).firstWhere((c) => c.id == id);
      expect(cat.name, 'Еда');
      expect(cat.icon, 'coins');
      expect(cat.systemKey, 'expense.groceries');
      expect(find.text('Еда'), findsOneWidget);
    });

    testWidgets('подкатегория: родитель из дерева; две ступени, не больше', (
      tester,
    ) async {
      final container = await pump(tester);
      await tapKey(tester, 'categories-add');
      await tester.enterText(
        find.byKey(const Key('category-name')),
        'Бензин 95',
      );
      await tapKey(tester, 'category-parent');
      // В выборе родителя — только верхний уровень.
      expect(
        find.byKey(
          Key('category-pick-${categoryPresetId('expense.car')}'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          Key('category-pick-${categoryPresetId('expense.car.fuel')}'),
        ),
        findsNothing,
      );
      await pickCategory(tester, categoryPresetId('expense.car'));
      expect(find.text('Авто'), findsWidgets);
      await tapKey(tester, 'category-save');
      final created = (await _categories(
        tester,
        container,
      )).firstWhere((c) => c.name == 'Бензин 95');
      expect(created.parentId, categoryPresetId('expense.car'));
      expect(find.text('Бензин 95'), findsOneWidget);

      // У категории с подкатегориями выбора родителя нет.
      await tapKey(tester, 'category-${categoryPresetId('expense.car')}');
      expect(find.byKey(const Key('category-parent')), findsNothing);
    });

    testWidgets('ошибка: пустое название', (tester) async {
      await pump(tester);
      await tapKey(tester, 'categories-add');
      await tapKey(tester, 'category-save');
      expect(find.byKey(const Key('category-error')), findsOneWidget);
      expect(find.textContaining('не может быть пустым'), findsOneWidget);
    });

    testWidgets('новая категория дохода; смена вида сбрасывает родителя', (
      tester,
    ) async {
      final container = await pump(tester);
      await tapKey(tester, 'categories-add');
      await tester.enterText(find.byKey(const Key('category-name')), 'Аванс');
      await tapKey(tester, 'category-parent');
      await pickCategory(tester, categoryPresetId('expense.car'));
      await tapKey(tester, 'category-kind-income');
      expect(find.text('Нет (верхний уровень)'), findsOneWidget);
      await tapKey(tester, 'category-save');
      final created = (await _categories(
        tester,
        container,
      )).firstWhere((c) => c.name == 'Аванс');
      expect(created.kind, CategoryKind.income);
      expect(created.parentId, isNull);
    });

    testWidgets('удаление: операции остаются, подкатегории становятся '
        'категориями верхнего уровня', (tester) async {
      final container = await pump(tester);
      final car = categoryPresetId('expense.car');
      await tapKey(tester, 'category-$car');
      await tapKey(tester, 'category-delete');
      expect(find.textContaining('попадут в «Без категории»'), findsOneWidget);
      await tapKey(tester, 'confirm-ok');
      expect(find.byKey(Key('category-$car')), findsNothing);
      // Подкатегории «Авто» остались и стали верхнего уровня.
      expect(find.text('Топливо'), findsOneWidget);
      expect(find.text('Обслуживание авто'), findsOneWidget);
      final cats = await _categories(tester, container);
      expect(cats.map((c) => c.id), isNot(contains(car)));
      // Повторный засев удалённую не возвращает.
      expect(cats.firstWhere((c) => c.name == 'Топливо').parentId, car);
    });

    testWidgets('несуществующая категория в форме', (tester) async {
      await pump(tester);
      await tapKey(tester, 'category-${categoryPresetId('expense.other')}');
      expect(find.byKey(const Key('category-name')), findsOneWidget);
    });

    testWidgets('выбор категории: пустое дерево', (tester) async {
      await pumpFinance(
        tester,
        location: '/finance/transactions',
        seedWith: seedAccountOnly,
      );
      await tapKey(tester, 'transactions-add');
      await tapKey(tester, 'tx-category-pick');
      expect(find.byKey(const Key('category-pick-empty')), findsOneWidget);
    });
  });
}
