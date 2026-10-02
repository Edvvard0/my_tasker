import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/category_editor.dart';

import '../../support/finance_ui_env.dart';
import '../../support/ui_helpers.dart';

Future<ProviderContainer> _open(
  WidgetTester tester, {
  bool seed = true,
  List<Override> overrides = const [],
}) => pumpFinance(
  tester,
  location: '/finance/categories',
  overrides: overrides,
  seedWith: seed ? seedFinanceDemo : null,
);

Future<List<FinanceCategory>> _cats(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(() => financeRepo(c).categories()))!;

String _id(List<FinanceCategory> all, String name, CategoryKind kind) =>
    all.firstWhere((c) => c.name == name && c.kind == kind).id;

void main() {
  group('список', () {
    testWidgets('расходы: два уровня, подкатегории под родителем', (
      tester,
    ) async {
      final c = await _open(tester);
      final all = await _cats(tester, c);
      expect(find.byKey(const Key('cats-list')), findsOneWidget);
      final transport = _id(all, 'Транспорт', CategoryKind.expense);
      final taxi = _id(all, 'Такси', CategoryKind.expense);
      expect(find.byKey(Key('cat-row-$transport')), findsOneWidget);
      // Подкатегория вложена правее родителя и без кнопки «+».
      final parent = tester.getTopLeft(find.byKey(Key('cat-row-$transport')));
      final child = tester.getTopLeft(find.byKey(Key('cat-row-$taxi')));
      expect(child.dx, greaterThan(parent.dx));
      expect(find.byKey(Key('cat-add-sub-$transport')), findsOneWidget);
      expect(find.byKey(Key('cat-add-sub-$taxi')), findsNothing);
      // Доходов в списке расходов нет.
      expect(find.text('Зарплата'), findsNothing);
    });

    testWidgets('доходы: переключатель вида', (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const Key('cats-kind-income')));
      await tester.pumpAndSettle();
      expect(find.text('Зарплата'), findsOneWidget);
      expect(find.text('Доход с проектов'), findsOneWidget);
      expect(find.text('Продукты'), findsNothing);
    });

    testWidgets('пусто: стартовые категории ещё не засеяны', (tester) async {
      await _open(tester, seed: false);
      expect(find.byKey(const Key('cats-empty')), findsOneWidget);
      expect(find.text('Категорий нет'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cats-empty-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cat-name')), findsOneWidget);
    });

    testWidgets('загрузка: скелетон', (tester) async {
      final gate = StreamController<List<Json>>();
      addTearDown(gate.close);
      await _open(
        tester,
        seed: false,
        overrides: [categoryRowsProvider.overrideWith((ref) => gate.stream)],
      );
      expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    });

    testWidgets('ошибка чтения: плашка и «Повторить»', (tester) async {
      await _open(
        tester,
        seed: false,
        overrides: [
          categoryRowsProvider.overrideWith(
            (ref) => Stream<List<Json>>.error(StateError('boom')),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('finance-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-error')), findsOneWidget);
    });

    testWidgets('офлайн: плашка, список работает', (tester) async {
      await _open(
        tester,
        overrides: [
          syncStatusProvider.overrideWith(
            () => FixedStatus(statusOf(SyncIndicatorKind.offline)),
          ),
        ],
      );
      expect(find.byKey(const Key('finance-offline')), findsOneWidget);
      expect(find.byKey(const Key('cats-list')), findsOneWidget);
    });

    testWidgets('подкатегория удалённого родителя — на верхнем уровне', (
      tester,
    ) async {
      final c = await _open(tester);
      final all = await _cats(tester, c);
      final transport = _id(all, 'Транспорт', CategoryKind.expense);
      final taxi = _id(all, 'Такси', CategoryKind.expense);
      await tester.runAsync(() => financeRepo(c).deleteCategory(transport));
      await settleDb(tester);
      expect(find.byKey(Key('cat-row-$transport')), findsNothing);
      // «Такси» осталась и теперь с кнопкой «+» (верхний уровень).
      expect(find.byKey(Key('cat-add-sub-$taxi')), findsOneWidget);
    });

    testWidgets('назад ведёт на обзор', (tester) async {
      await _open(tester);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });
  });

  group('создание', () {
    testWidgets('название, иконка, цвет — новая категория верхнего уровня', (
      tester,
    ) async {
      final c = await _open(tester);
      await tester.tap(find.byKey(const Key('cat-add')));
      await tester.pumpAndSettle();
      expect(find.text('Новая категория'), findsOneWidget);
      await enter(tester, 'cat-name', '  Кофе ');
      await tapKey(tester, 'cat-icon-restaurant');
      await tapKey(tester, 'cat-color-4C8DFF');
      await tapKey(tester, 'cat-save');
      await settleDb(tester);
      final all = await _cats(tester, c);
      final coffee = all.firstWhere((x) => x.name == 'Кофе');
      expect(coffee.kind, CategoryKind.expense);
      expect(coffee.parentId, isNull);
      expect(coffee.icon, 'restaurant');
      expect(coffee.color, '#4C8DFF');
      expect(coffee.systemKey, isNull);
      expect(find.byKey(Key('cat-row-${coffee.id}')), findsOneWidget);
    });

    testWidgets('доход создаётся из вкладки «Доход»; родитель того же вида', (
      tester,
    ) async {
      final c = await _open(tester);
      await tester.tap(find.byKey(const Key('cats-kind-income')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cat-add')));
      await tester.pumpAndSettle();
      await enter(tester, 'cat-name', 'Фриланс');
      // В списке родителей — только доходные категории.
      final all = await _cats(tester, c);
      final salary = _id(all, 'Зарплата', CategoryKind.income);
      final groceries = _id(all, 'Продукты', CategoryKind.expense);
      expect(find.byKey(Key('cat-parent-$salary')), findsOneWidget);
      expect(find.byKey(Key('cat-parent-$groceries')), findsNothing);
      await tapKey(tester, 'cat-parent-$salary');
      await tapKey(tester, 'cat-save');
      await settleDb(tester);
      final created = (await _cats(
        tester,
        c,
      )).firstWhere((x) => x.name == 'Фриланс');
      expect(created.kind, CategoryKind.income);
      expect(created.parentId, salary);
    });

    testWidgets('«+» у категории создаёт подкатегорию с этим родителем', (
      tester,
    ) async {
      final c = await _open(tester);
      final all = await _cats(tester, c);
      final groceries = _id(all, 'Продукты', CategoryKind.expense);
      await tapKey(tester, 'cat-add-sub-$groceries');
      await enter(tester, 'cat-name', 'Овощи');
      await tapKey(tester, 'cat-save');
      await settleDb(tester);
      final created = (await _cats(
        tester,
        c,
      )).firstWhere((x) => x.name == 'Овощи');
      expect(created.parentId, groceries);
    });

    testWidgets('смена вида в форме сбрасывает родителя', (tester) async {
      final c = await _open(tester);
      final all = await _cats(tester, c);
      final groceries = _id(all, 'Продукты', CategoryKind.expense);
      await tapKey(tester, 'cat-add-sub-$groceries');
      await enter(tester, 'cat-name', 'Подработка');
      await tester.tap(find.byKey(const Key('cat-kind-income')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'cat-save');
      await settleDb(tester);
      final created = (await _cats(
        tester,
        c,
      )).firstWhere((x) => x.name == 'Подработка');
      expect(created.kind, CategoryKind.income);
      expect(created.parentId, isNull);
    });

    testWidgets('пустое название: ошибка, категория не создана', (
      tester,
    ) async {
      final c = await _open(tester);
      final count = (await _cats(tester, c)).length;
      await tester.tap(find.byKey(const Key('cat-add')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'cat-save');
      expect(find.byKey(const Key('cat-error')), findsOneWidget);
      expect(find.textContaining('Название категории'), findsOneWidget);
      expect((await _cats(tester, c)).length, count);
    });
  });

  group('правка и удаление', () {
    testWidgets('правка: поля заполнены, вид не меняется, подкатегория '
        'переезжает к другому родителю', (tester) async {
      final c = await _open(tester);
      final all = await _cats(tester, c);
      final taxi = _id(all, 'Такси', CategoryKind.expense);
      final transport = _id(all, 'Транспорт', CategoryKind.expense);
      final car = _id(all, 'Авто', CategoryKind.expense);
      await tapKey(tester, 'cat-row-$taxi');
      expect(find.text('Категория'), findsOneWidget);
      expect(fieldText(tester, 'cat-name'), 'Такси');
      expect(find.byKey(const Key('cat-kind-income')), findsNothing);
      // Родитель выбран.
      await tapKey(tester, 'cat-parent-$car');
      await enter(tester, 'cat-name', 'Такси и каршеринг');
      await tapKey(tester, 'cat-save');
      await settleDb(tester);
      final edited = (await _cats(tester, c)).firstWhere((x) => x.id == taxi);
      expect(edited.name, 'Такси и каршеринг');
      expect(edited.parentId, car);
      expect(edited.systemKey, 'expense.transport.taxi');
      expect(edited.parentId, isNot(transport));
    });

    testWidgets('подкатегорию можно сделать категорией верхнего уровня', (
      tester,
    ) async {
      final c = await _open(tester);
      final all = await _cats(tester, c);
      final taxi = _id(all, 'Такси', CategoryKind.expense);
      await tapKey(tester, 'cat-row-$taxi');
      await tapKey(tester, 'cat-parent-none');
      await tapKey(tester, 'cat-save');
      await settleDb(tester);
      final edited = (await _cats(tester, c)).firstWhere((x) => x.id == taxi);
      expect(edited.parentId, isNull);
    });

    testWidgets('у категории с подкатегориями выбора родителя нет', (
      tester,
    ) async {
      final c = await _open(tester);
      final all = await _cats(tester, c);
      final transport = _id(all, 'Транспорт', CategoryKind.expense);
      await tapKey(tester, 'cat-row-$transport');
      expect(find.byKey(const Key('cat-parent-none')), findsNothing);
    });

    testWidgets('удаление: вопрос про последствия, снэкбар «Отменить»', (
      tester,
    ) async {
      final c = await _open(tester);
      final all = await _cats(tester, c);
      final cafe = _id(all, 'Кафе и рестораны', CategoryKind.expense);
      await tapKey(tester, 'cat-row-$cafe');
      await tapKey(tester, 'cat-delete');
      expect(find.textContaining('Операции останутся'), findsOneWidget);
      // Отмена в диалоге — категория на месте.
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cat-name')), findsOneWidget);
      await tapKey(tester, 'cat-delete');
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await settleDb(tester);
      expect(find.byKey(Key('cat-row-$cafe')), findsNothing);
      expect(find.text('Категория «Кафе и рестораны» удалена'), findsOne);
      // Операции с этой категорией остались.
      final txs = (await tester.runAsync(() => financeRepo(c).transactions()))!;
      expect(txs.where((t) => t.categoryId == cafe), hasLength(1));
      await tester.tap(find.text('Отменить'));
      await settleDb(tester);
      expect(find.byKey(Key('cat-row-$cafe')), findsOneWidget);
    });

    testWidgets('категории нет: «Категория не найдена»', (tester) async {
      await _open(tester);
      unawaited(
        showCategoryEditor(
          tester.element(find.byType(Scaffold).first),
          categoryId: 'nope',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cat-missing')), findsOneWidget);
    });
  });
}
