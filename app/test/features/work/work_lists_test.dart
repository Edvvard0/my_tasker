import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/pump_app.dart';
import '../../support/work_env.dart';

WorkData _data(ProviderContainer c) => c.read(workDataProvider).requireValue;

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

/// Перехватывает буфер обмена: возвращает то, что в него записали.
List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text']! as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

void main() {
  group('«Мне должны»', () {
    testWidgets('итог и долги по заказчикам: Елена, затем Рома', (
      tester,
    ) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/receivables');
      final data = _data(container);
      final roma = data.people.firstWhere((p) => p.name == 'Рома');
      final elena = data.people.firstWhere((p) => p.name == 'Елена');

      expect(_text(tester, 'receivables-total'), nb('80 500 ₽'));
      expect(find.text('2 заказчика'), findsOneWidget);
      expect(_text(tester, 'receivable-amount-${elena.id}'), nb('55 500 ₽'));
      expect(_text(tester, 'receivable-amount-${roma.id}'), nb('25 000 ₽'));
      // Порядок: по убыванию долга.
      expect(
        tester.getTopLeft(find.byKey(Key('receivable-${elena.id}'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(Key('receivable-${roma.id}'))).dy,
        ),
      );
      // Внутри Ромы: SaaS 20 000 выше, чем Бот 5 000.
      final saas = projectIdOf(container, 'SaaS Лены');
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      expect(
        tester.getTopLeft(find.byKey(Key('receivable-project-$saas'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(Key('receivable-project-$bot'))).dy,
        ),
      );
      expect(find.text('2 проекта'), findsOneWidget);
      expect(find.text('1 проект'), findsOneWidget);
    });

    testWidgets('лиды и отменённые не должны; пауза и завершённые — должны; '
        'без заказчика — последним', (tester) async {
      final container = await pumpWork(tester, seed: true);
      final repo = container.read(workRepositoryProvider);
      await tester.runAsync(() async {
        Future<void> project(String title, ProjectStatus status, int base) =>
            repo.createProject(
              WorkProject(
                id: repo.newId(),
                title: title,
                status: status,
                baseAmount: base,
                completedDate: status == ProjectStatus.completed
                    ? '2026-09-01'
                    : null,
              ),
            );
        await project('Лид', ProjectStatus.lead, 9900000);
        await project('Отменён', ProjectStatus.cancelled, 9900000);
        await project('На паузе', ProjectStatus.paused, 300000);
        await project('Сдан', ProjectStatus.completed, 100000);
      });
      await goTo(tester, container, '/work/receivables');
      expect(_text(tester, 'receivables-total'), nb('84 500 ₽'));
      expect(find.text('Заказчик не указан'), findsOneWidget);
      expect(_text(tester, 'receivable-amount-none'), nb('4 000 ₽'));
      expect(find.text('Лид'), findsNothing);
      expect(find.text('Отменён'), findsNothing);
      expect(find.text('На паузе'), findsOneWidget);
      expect(find.text('Сдан'), findsOneWidget);
      // Заказчик без долга в список не попадает, а «без заказчика» — в конце.
      final none = tester
          .getTopLeft(find.byKey(const Key('receivable-none')))
          .dy;
      final elena = _data(container).people
          .firstWhere((p) => p.name == 'Елена');
      expect(
        tester.getTopLeft(find.byKey(Key('receivable-${elena.id}'))).dy,
        lessThan(none),
      );
    });

    testWidgets('удалённый заказчик: долг остаётся, имя — «не указан»', (
      tester,
    ) async {
      final container = await pumpWork(tester, seed: true);
      final roma = _data(container).people.firstWhere((p) => p.name == 'Рома');
      await tester.runAsync(
        () => container.read(workRepositoryProvider).deletePerson(roma.id),
      );
      await goTo(tester, container, '/work/receivables');
      expect(_text(tester, 'receivables-total'), nb('80 500 ₽'));
      expect(find.text('Заказчик не указан'), findsOneWidget);
      expect(_text(tester, 'receivable-amount-${roma.id}'), nb('25 000 ₽'));
    });

    testWidgets('«Скопировать напоминание» кладёт текст в буфер', (
      tester,
    ) async {
      final copied = _captureClipboard(tester);
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/receivables');
      final elena = _data(container).people
          .firstWhere((p) => p.name == 'Елена');
      await tapKey(tester, 'receivable-copy-${elena.id}');
      expect(copied.single, startsWith('Привет! Напоминаю про оплату: '));
      expect(copied.single, contains(nb('55 500 ₽')));
      expect(copied.single, contains('Платформа Creora'));
      expect(find.text('Текст напоминания скопирован'), findsOneWidget);
    });

    testWidgets('нажатие на проект открывает его', (tester) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/receivables');
      final creora = projectIdOf(container, 'Платформа Creora');
      await tapKey(tester, 'receivable-project-$creora');
      expect(locationOf(tester), '/work/projects/$creora');
    });

    testWidgets('всё оплачено: подсказка вместо списка', (tester) async {
      final container = await pumpWork(tester);
      await goTo(tester, container, '/work/receivables');
      expect(find.byKey(const Key('receivables-empty')), findsOneWidget);
      expect(find.text('Все проекты оплачены'), findsOneWidget);
      expect(_text(tester, 'receivables-total'), nb('0 ₽'));
    });

    testWidgets('десктоп', (tester) async {
      final container = await pumpWork(tester, seed: true, size: desktopSize);
      await goTo(tester, container, '/work/receivables');
      expect(_text(tester, 'receivables-total'), nb('80 500 ₽'));
    });
  });

  group('«Люди»', () {
    testWidgets('создание заказчика, правка, архив и удаление', (tester) async {
      final container = await pumpWork(tester, location: '/work/people');
      expect(find.byKey(const Key('people-empty')), findsOneWidget);
      await tapKey(tester, 'people-add');
      await tapKey(tester, 'person-save');
      expect(find.textContaining('Имя не может быть пустым'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('person-name')), 'Рома');
      await tester.enterText(find.byKey(const Key('person-contact')), '@roma');
      await tapKey(tester, 'person-save');
      final roma = _data(container).people.single;
      expect(roma.role, PersonRole.client);
      expect(find.text('Рома'), findsOneWidget);
      expect(find.text('Заказчик · @roma'), findsOneWidget);

      await tapKey(tester, 'person-${roma.id}');
      await tapKey(tester, 'person-role-other');
      await tester.enterText(find.byKey(const Key('person-contact')), '');
      await tapKey(tester, 'person-save');
      expect(_data(container).people.single.role, PersonRole.other);
      expect(find.text('Другое'), findsOneWidget);

      await tapKey(tester, 'person-${roma.id}');
      await tester.tap(find.byKey(const Key('person-archived')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'person-save');
      expect(find.byKey(const Key('people-empty')), findsOneWidget);
      await tapKey(tester, 'people-filter-archive');
      expect(find.text('Рома'), findsOneWidget);
      expect(find.text('Архив · 1'), findsOneWidget);

      await tapKey(tester, 'person-${roma.id}');
      await tapKey(tester, 'person-delete');
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(_data(container).people, isEmpty);
    });

    testWidgets('у заказчика видны проекты и долг', (tester) async {
      final container = await pumpWork(
        tester,
        seed: true,
        location: '/work/people',
      );
      final roma = _data(container).people.firstWhere((p) => p.name == 'Рома');
      expect(find.textContaining('Заказчик · 2 проекта'), findsNWidgets(1));
      expect(_text(tester, 'person-owed-${roma.id}'), nb('25 000 ₽'));
      expect(find.text('должен'), findsNWidgets(2));
      await tapKey(tester, 'people-filter-archive');
      expect(find.byKey(const Key('people-empty')), findsOneWidget);
      expect(find.text('Архив пуст'), findsOneWidget);
    });

    testWidgets('форма удалённого человека объясняет', (tester) async {
      final container = await pumpWork(
        tester,
        seed: true,
        location: '/work/people',
      );
      final roma = _data(container).people.firstWhere((p) => p.name == 'Рома');
      await tapKey(tester, 'person-${roma.id}');
      await tester.runAsync(
        () => container.read(workRepositoryProvider).deletePerson(roma.id),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('person-${roma.id}')), findsNothing);
    });
  });

  group('«Поступления»', () {
    testWidgets('месяцы по убыванию, платежи, не разнесённая часть', (
      tester,
    ) async {
      final container = await pumpWork(
        tester,
        seed: true,
        location: '/work/payments',
      );
      final data = _data(container);
      expect(find.byKey(const Key('month-2026-09')), findsOneWidget);
      expect(find.byKey(const Key('month-2026-08')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('month-2026-09'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('month-2026-08'))).dy),
      );
      // Сентябрь: 9 000 + 10 000 = 19 000; август: 12 000 + 14 500.
      final sept = find.descendant(
        of: find.byKey(const Key('month-2026-09')),
        matching: find.byType(Text),
      );
      expect(tester.widgetList<Text>(sept).map((t) => t.data), [
        'сент.',
        nb('19 000 ₽'),
      ]);
      expect(find.byKey(const Key('payments-list')), findsOneWidget);
      for (final p in data.payments) {
        expect(find.byKey(Key('payment-${p.id}')), findsOneWidget);
      }

      final repo = container.read(workRepositoryProvider);
      await tester.runAsync(
        () => repo.createPayment(
          Payment(id: repo.newId(), paidAt: msk(2026, 9, 30), amount: 500000),
          const [],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('не разнесено ${nb('5 000 ₽')}'),
        findsWidgets,
      );
    });

    testWidgets('нарушение целостности показано предупреждением', (
      tester,
    ) async {
      final container = await pumpWork(
        tester,
        seed: true,
        location: '/work/payments',
      );
      final data = _data(container);
      final payment = data.payments.firstWhere((p) => p.amount == 900000);
      final project = data.allocationsOfPayment(payment.id).first.projectId;
      expect(
        find.byKey(Key('payments-overallocated-${payment.id}')),
        findsNothing,
      );
      // Слияние двух устройств дало распределений больше платежа (spec 3.3).
      await tester.runAsync(
        () => container.read(syncStoreProvider).create(
          'payment_allocations',
          container.read(workRepositoryProvider).newId(),
          {
            'payment_id': payment.id,
            'project_id': project,
            'change_request_id': null,
            'amount': 250000,
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('payments-overallocated-${payment.id}')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'распределено больше, чем пришло, на ${nb('2 500 ₽')}',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('распределено больше на'), findsOneWidget);
      await tapKey(tester, 'payments-overallocated-${payment.id}');
    });

    testWidgets('пусто: подсказка и добавление', (tester) async {
      await pumpWork(tester, location: '/work/payments');
      expect(find.byKey(const Key('payments-empty')), findsOneWidget);
      await tapKey(tester, 'payments-empty-add');
      expect(find.byKey(const Key('payment-amount')), findsOneWidget);
    });
  });
}
