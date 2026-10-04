import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/pump_app.dart';
import '../../support/work_env.dart';

WorkData _data(ProviderContainer c) => c.read(workDataProvider).requireValue;

void main() {
  Future<(ProviderContainer, String)> openProject(
    WidgetTester tester, {
    String title = 'Бот разборов ИИ',
    Size size = phoneSize,
  }) async {
    final container = await pumpWork(tester, size: size, seed: true);
    final id = projectIdOf(container, title);
    await goTo(tester, container, '/work/projects/$id');
    return (container, id);
  }

  Future<void> menu(WidgetTester tester, String item) async {
    await tester.tap(find.byKey(const Key('project-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(item)));
    await tester.pumpAndSettle();
  }

  Finder error(String key) => find.byKey(Key(key));

  group('редактор проекта', () {
    testWidgets('проверки: название, сумма, ставка почасового проекта', (
      tester,
    ) async {
      final (container, id) = await openProject(tester);
      await menu(tester, 'project-menu-edit');
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('project-title')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        'Бот разборов ИИ',
      );

      await tester.enterText(find.byKey(const Key('project-title')), '  ');
      await tapKey(tester, 'project-save');
      expect(error('project-error'), findsOneWidget);
      expect(
        find.textContaining('Название не может быть пустым'),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(const Key('project-title')), 'Бот 2');
      await tester.enterText(find.byKey(const Key('project-base')), '1,234,5');
      await tapKey(tester, 'project-save');
      expect(
        find.textContaining('Базовая сумма: введите сумму'),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(const Key('project-base')), '20 000');
      await tapKey(tester, 'project-paytype-hourly');
      await tapKey(tester, 'project-save');
      expect(find.textContaining('укажите ставку'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('project-rate')), '1500');
      await tapKey(tester, 'project-save');
      expect(error('project-error'), findsNothing);
      final p = _data(container).projectById[id]!;
      expect(p.title, 'Бот 2');
      expect(p.payType, PayType.hourly);
      expect(p.hourlyRate, 150000);
      expect(find.text('Бот 2'), findsOneWidget);
      // Почасовой проект: ставка в шапке и «набежало по ставке» во времени.
      expect(find.textContaining('${nb('1 500 ₽')}/ч'), findsWidgets);
      expect(find.textContaining('По ставке набежало'), findsOneWidget);
    });

    testWidgets('«Завершён» ставит дату, затем проект уходит в архив и '
        'возвращается', (tester) async {
      final (container, id) = await openProject(tester, title: 'SaaS Лены');
      expect(find.byKey(const Key('project-menu-archive')), findsNothing);
      await menu(tester, 'project-menu-edit');
      await tapKey(tester, 'project-status-completed');
      expect(find.byKey(const Key('project-completed-today')), findsOneWidget);
      await tapKey(tester, 'project-save');
      var p = _data(container).projectById[id]!;
      expect(p.status, ProjectStatus.completed);
      expect(p.completedDate, '2026-09-30');
      // Доход «по начисленному» учёл базу завершённого проекта.
      expect(
        _data(container)
            .incomeFor(projectId: id, period: _data(container).thisMonth)
            .accrued,
        2000000,
      );

      await menu(tester, 'project-menu-archive');
      expect(find.text('В АРХИВЕ'), findsOneWidget);
      expect(_data(container).projectById[id]!.archived, isTrue);
      await menu(tester, 'project-menu-unarchive');
      expect(find.text('В АРХИВЕ'), findsNothing);
      p = _data(container).projectById[id]!;
      expect(p.archived, isFalse);
    });

    testWidgets('новый заказчик, ссылка, описание, срок и дата начала', (
      tester,
    ) async {
      final container = await pumpWork(tester);
      await tapKey(tester, 'work-add-project');
      await tester.enterText(find.byKey(const Key('project-title')), 'Сайт');
      await tapKey(tester, 'project-client-new');
      await tester.enterText(find.byKey(const Key('ask-text')), 'Елена');
      await tapKey(tester, 'ask-text-ok');
      await tester.enterText(
        find.byKey(const Key('project-link-url')),
        'https://example.com/doc',
      );
      await tester.enterText(
        find.byKey(const Key('project-link-title')),
        'Документ',
      );
      await tapKey(tester, 'project-link-add');
      expect(find.byKey(const Key('project-link-0')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('project-description')),
        'Лендинг и админка',
      );
      await tapKey(tester, 'project-start-today');
      await tapKey(tester, 'project-deadline-tomorrow');
      // Ссылку из недописанного поля сохранение подхватывает само.
      await tester.enterText(
        find.byKey(const Key('project-link-url')),
        'https://example.com/second',
      );
      await tapKey(tester, 'project-save');

      final p = _data(container).projects.single;
      expect(p.title, 'Сайт');
      expect(_data(container).clientOf(p)!.name, 'Елена');
      expect(_data(container).clientOf(p)!.role, PersonRole.client);
      expect(p.startDate, '2026-09-30');
      expect(p.deadlineDate, '2026-10-01');
      expect(p.description, 'Лендинг и админка');
      expect(p.links.map((l) => l.url), [
        'https://example.com/doc',
        'https://example.com/second',
      ]);
      expect(p.links.first.title, 'Документ');
    });

    testWidgets('ошибка ссылки не теряет введённое', (tester) async {
      await pumpWork(tester);
      await tapKey(tester, 'work-add-project');
      await tester.enterText(find.byKey(const Key('project-title')), 'Сайт');
      await tester.enterText(
        find.byKey(const Key('project-link-url')),
        'ftp://x',
      );
      await tapKey(tester, 'project-save');
      expect(find.textContaining('http://'), findsOneWidget);
      expect(find.byKey(const Key('project-title')), findsOneWidget);
    });

    testWidgets('удаление проекта: подтверждение, «Отменить» возвращает', (
      tester,
    ) async {
      final (container, id) = await openProject(tester, title: 'SaaS Лены');
      await menu(tester, 'project-menu-delete');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(_data(container).projectById[id], isNotNull);

      await menu(tester, 'project-menu-delete');
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/work');
      expect(_data(container).projectById[id], isNull);
      expect(find.text('Удалено: «SaaS Лены»'), findsOneWidget);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(_data(container).projectById[id], isNotNull);
    });

    testWidgets('редактор несуществующего проекта объясняет', (tester) async {
      final (container, id) = await openProject(tester, title: 'SaaS Лены');
      await menu(tester, 'project-menu-edit');
      // Другое устройство удалило проект, пока форма была открыта — повторное
      // открытие формы по старому id.
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => container.read(workRepositoryProvider).deleteProject(id),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('project-missing')), findsOneWidget);
    });
  });

  group('редактор доработки', () {
    testWidgets('добавление: проверки и сохранение, правка и закрытие', (
      tester,
    ) async {
      final (container, id) = await openProject(tester);
      await tapKey(tester, 'cr-add');
      await tapKey(tester, 'cr-save');
      expect(find.textContaining('Укажите сумму доработки'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('cr-amount')), '3 500');
      await tapKey(tester, 'cr-save');
      expect(
        find.textContaining('Название не может быть пустым'),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(const Key('cr-title')), 'Админка');
      await tester.enterText(find.byKey(const Key('cr-estimate')), 'много');
      await tapKey(tester, 'cr-save');
      expect(find.textContaining('число часов'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('cr-estimate')), '1,5');
      await tester.enterText(find.byKey(const Key('cr-note')), 'Заметка');
      await tapKey(tester, 'cr-save');
      var cr = _data(container)
          .changeRequestsOf(id)
          .firstWhere((c) => c.title == 'Админка');
      expect(cr.amount, 350000);
      expect(cr.estimateMinutes, 90);
      expect(cr.note, 'Заметка');
      expect(cr.status, ChangeRequestStatus.inProgress);
      // Сумма проекта выросла: 26 000 + 3 500.
      expect(find.text(nb('29,5к ₽')), findsOneWidget);

      await tapKey(tester, 'money-row-${cr.id}');
      expect(find.byKey(const Key('cr-delete')), findsOneWidget);
      await tapKey(tester, 'cr-status-closed');
      expect(find.byKey(const Key('cr-closed-today')), findsOneWidget);
      await tapKey(tester, 'cr-save');
      cr = _data(container).changeRequestById[cr.id]!;
      expect(cr.status, ChangeRequestStatus.closed);
      expect(cr.closedDate, '2026-09-30');
      expect(find.text('ЗАКРЫТА'), findsOneWidget);

      await tapKey(tester, 'money-row-${cr.id}');
      await tapKey(tester, 'cr-status-cancelled');
      await tapKey(tester, 'cr-save');
      // Отменённая доработка не входит в сумму проекта.
      expect(find.text(nb('26к ₽')), findsOneWidget);
      expect(find.text('ОТМЕНЕНА'), findsOneWidget);
    });

    testWidgets('удаление доработки с подтверждением', (tester) async {
      final (container, id) = await openProject(tester);
      final cr = _data(container).changeRequestsOf(id).last;
      await tapKey(tester, 'money-row-${cr.id}');
      await tapKey(tester, 'cr-delete');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(_data(container).changeRequestById[cr.id], isNull);
      expect(find.byKey(Key('money-row-${cr.id}')), findsNothing);
    });

    testWidgets('«Добавить доработку» из меню проекта', (tester) async {
      final (container, id) = await openProject(tester);
      await menu(tester, 'project-menu-add-cr');
      expect(find.byKey(const Key('cr-title')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('cr-title')), 'Новая');
      await tester.enterText(find.byKey(const Key('cr-amount')), '100');
      await tapKey(tester, 'cr-save');
      expect(_data(container).changeRequestsOf(id), hasLength(3));
    });
  });

  group('ввод платежа', () {
    testWidgets('из проекта: сумма повторяется в строке, остаток 0', (
      tester,
    ) async {
      final (container, id) = await openProject(tester);
      await tapKey(tester, 'project-add-payment');
      expect(find.text('Бот разборов ИИ'), findsWidgets);
      await tester.enterText(find.byKey(const Key('payment-amount')), '5 000');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('alloc-amount-0')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '5000',
      );
      expect(find.text('Всё распределено'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('payment-comment')),
        'Закрытие',
      );
      await tapKey(tester, 'payment-save');
      expect(error('payment-error'), findsNothing);

      final data = _data(container);
      final summary = data.summaryOf(id);
      expect(summary.received, 2600000);
      expect(summary.remaining, 0);
      expect(summary.paidBp, 10000);
      expect(data.payments.first.comment, 'Закрытие');
      expect(find.text('100 % оплач.'), findsOneWidget);
    });

    testWidgets('один платёж на проект и доработку; остаток; ошибки', (
      tester,
    ) async {
      final (container, id) = await openProject(tester);
      final data = _data(container);
      final login = data
          .changeRequestsOf(id)
          .firstWhere((c) => c.title == 'Доработка входа в бот');
      await tapKey(tester, 'project-add-payment');
      await tester.enterText(find.byKey(const Key('payment-amount')), '3 000');
      // Первая строка — на доработку входа.
      await tapKey(tester, 'alloc-target-0');
      await tapKey(tester, 'alloc-target-0-${login.id}');
      expect(find.text('Доработка входа в бот'), findsWidgets);
      await tester.enterText(find.byKey(const Key('alloc-amount-0')), '1 000');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Не распределено: ${nb('2 000 ₽')}'),
        findsOneWidget,
      );

      // Вторая строка — на другой проект, остаток одной кнопкой.
      await tapKey(tester, 'alloc-add');
      await tapKey(tester, 'alloc-project-1');
      await tapKey(
        tester,
        'alloc-project-1-${projectIdOf(container, 'SaaS Лены')}',
      );
      await tapKey(tester, 'alloc-rest');
      expect(find.text('Всё распределено'), findsOneWidget);

      // Больше, чем пришло: ошибка до записи.
      await tester.enterText(find.byKey(const Key('alloc-amount-1')), '5 000');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Распределено больше, чем пришло'),
        findsOneWidget,
      );
      await tapKey(tester, 'payment-save');
      expect(error('payment-error'), findsOneWidget);
      expect(_data(container).payments.length, 4);

      await tester.enterText(find.byKey(const Key('alloc-amount-1')), '2 000');
      await tapKey(tester, 'payment-save');
      expect(error('payment-error'), findsNothing);
      final after = _data(container);
      expect(after.payments.length, 5);
      final payment = after.payments.firstWhere((p) => p.amount == 300000);
      final allocations = after.allocationsOfPayment(payment.id);
      expect(allocations, hasLength(2));
      expect(
        allocations.map(
          (a) => (a.projectId == id, a.changeRequestId == login.id),
        ),
        containsAll([(true, true), (false, false)]),
      );
      expect(
        after
            .summaryOf(id)
            .changeRequests
            .firstWhere((c) => c.id == login.id)
            .received,
        200000,
      );
      // Не распределённая часть платежа допустима и видна в «Поступлениях».
      expect(after.unallocatedOf(payment), 0);
    });

    testWidgets('строка без проекта и пустая сумма отвергаются', (
      tester,
    ) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/payments');
      await tapKey(tester, 'payments-add');
      await tapKey(tester, 'payment-save');
      expect(find.textContaining('Укажите сумму платежа'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('payment-amount')), 'abc');
      await tapKey(tester, 'payment-save');
      expect(error('payment-error'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('payment-amount')), '1 000');
      await tester.enterText(find.byKey(const Key('alloc-amount-0')), '500');
      await tapKey(tester, 'payment-save');
      expect(
        find.text('Выберите проект для строки распределения'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('alloc-amount-0')), '');
      await tapKey(tester, 'payment-save');
      // Платёж без распределения допустим: деньги «не разнесены».
      expect(error('payment-error'), findsNothing);
      final data = _data(container);
      final created = data.payments.firstWhere((p) => p.amount == 100000);
      expect(data.unallocatedOf(created), 100000);
    });

    testWidgets('правка платежа: другая дата, плательщик, строки', (
      tester,
    ) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/payments');
      final data = _data(container);
      final septBot = data.payments.firstWhere((p) => p.amount == 900000);
      await tapKey(tester, 'payment-${septBot.id}');
      // В форме — исходные значения; дата по Москве.
      expect(find.byKey(const Key('alloc-row-0')), findsOneWidget);
      expect(find.byKey(const Key('alloc-row-1')), findsOneWidget);
      await tapKey(tester, 'payment-date-today');
      await tester.enterText(find.byKey(const Key('payment-amount')), '9 500');
      await tapKey(tester, 'alloc-remove-1');
      await tapKey(tester, 'payment-save');
      final after = _data(container);
      final p = after.payments.firstWhere((x) => x.id == septBot.id);
      expect(p.amount, 950000);
      expect(moscowDate(p.paidAt), '2026-09-30');
      expect(after.allocationsOfPayment(p.id), hasLength(1));
      // Сентябрьская колонка: 8 000 + 10 000, не разнесено 1 500.
      final sept = after.monthly().firstWhere((m) => m.month == '2026-09');
      expect(sept.received, 1800000);
      expect(sept.unallocated, 150000);
    });

    testWidgets('удаление платежа с подтверждением', (tester) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/payments');
      final victim = _data(container).payments.first;
      await tapKey(tester, 'payment-${victim.id}');
      await tapKey(tester, 'payment-delete');
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(_data(container).payments.any((p) => p.id == victim.id), isFalse);
      expect(
        _data(container).allocations.any((a) => a.paymentId == victim.id),
        isFalse,
      );
    });
  });

  group('время вручную', () {
    testWidgets('из проекта: запись и проверки', (tester) async {
      final (container, id) = await openProject(tester);
      await tapKey(tester, 'project-add-entry');
      await tester.enterText(find.byKey(const Key('entry-minutes')), '0');
      await tapKey(tester, 'entry-save');
      expect(find.textContaining('больше нуля'), findsOneWidget);
      await tapKey(tester, 'entry-minutes-30');
      await tester.enterText(find.byKey(const Key('entry-note')), 'Созвон');
      await tester.tap(find.byKey(const Key('entry-billable')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'entry-save');
      final entries = _data(container).entriesOf(id);
      expect(entries, hasLength(4));
      final added = entries.firstWhere((e) => e.note == 'Созвон');
      expect(entrySeconds(added), 1800);
      expect(added.billable, isFalse);
      expect(added.source, TimeSource.manual);
      // Неоплачиваемая запись не входит в часы проекта: по-прежнему 14 ч.
      expect(find.text('Оплачиваемых часов: 14 ч'), findsOneWidget);
    });

    testWidgets('без проекта нельзя; правка и удаление с «Отменить»', (
      tester,
    ) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/time');
      await tapKey(tester, 'time-add');
      await tapKey(tester, 'entry-save');
      expect(
        find.descendant(
          of: find.byKey(const Key('entry-error')),
          matching: find.text('Выберите проект'),
        ),
        findsOneWidget,
      );
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      await tapKey(tester, 'entry-project-$bot');
      await tapKey(tester, 'entry-minutes-120');
      await tapKey(tester, 'entry-date-today');
      await tapKey(tester, 'entry-start-1500');
      await tapKey(tester, 'entry-save');
      final added = _data(container).entriesOf(bot).first;
      expect(entrySeconds(added), 7200);
      expect(added.startedAt, msk(2026, 9, 30, 15));

      await tapKey(tester, 'time-entry-${added.id}');
      await tester.enterText(find.byKey(const Key('entry-note')), 'Правка');
      await tapKey(tester, 'entry-save');
      final edited = _data(container).entries
          .firstWhere((e) => e.id == added.id);
      expect(edited.note, 'Правка');
      // Время не трогали — секунды те же.
      expect(edited.startedAt, added.startedAt);
      expect(edited.endedAt, added.endedAt);

      await tapKey(tester, 'time-entry-${added.id}');
      await tapKey(tester, 'entry-delete');
      expect(find.text('Запись времени удалена'), findsOneWidget);
      expect(_data(container).entries.any((e) => e.id == added.id), isFalse);
      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(_data(container).entries.any((e) => e.id == added.id), isTrue);
    });

    testWidgets('идущую запись формой не правят', (tester) async {
      final container = await pumpWork(tester, seed: true);
      final bot = projectIdOf(container, 'Бот разборов ИИ');
      late TimerStartResult started;
      await tester.runAsync(() async {
        started = await container
            .read(workRepositoryProvider)
            .startTimer(projectId: bot);
      });
      await tester.pumpAndSettle();
      await goTo(tester, container, '/work/projects/$bot');
      await tapKey(tester, 'entry-${started.started.id}');
      // Идущий таймер открывает лист таймера, а не форму записи.
      expect(find.byKey(const Key('timer-stop')), findsOneWidget);
    });
  });
}
