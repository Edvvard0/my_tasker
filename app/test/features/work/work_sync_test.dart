import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/work/application/timer_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/work_env.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Таблицы «Работы» через общий стек синхронизации и фейковый сервер:
/// «сделал офлайн — появилась сеть — данные на втором устройстве».
void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late WorkDevice phone;
  late WorkDevice pc;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => _uuid(2000 + ++counter);
    phone = await WorkDevice.create(server, clock: clock, newId: next);
    pc = await WorkDevice.create(server, clock: clock, newId: next);
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

  Future<List<T>> read<T>(
    WorkDevice d,
    String table,
    T Function(Map<String, Object?>) parse,
  ) async => [
    for (final r in await d.device.store.visibleRows(table)) parse(r),
  ];

  test('реестр: шесть таблиц «Работы», родители раньше детей', () {
    final names = [for (final s in registeredSyncTables) s.name];
    for (final name in [
      'projects',
      'people',
      'change_requests',
      'payments',
      'payment_allocations',
      'time_entries',
    ]) {
      expect(names, contains(name));
    }
    expect(
      names.indexOf('projects'),
      lessThan(names.indexOf('change_requests')),
    );
    expect(
      names.indexOf('payments'),
      lessThan(names.indexOf('payment_allocations')),
    );
    final registry = SyncRegistry(registeredSyncTables);
    expect(
      registry.spec('payment_allocations').parents.map((r) => r.parentTable),
      ['payments', 'projects'],
    );
    expect(registry.spec('payments').parents, isEmpty);
    // Мягкие ссылки не объявлены родителями (spec 2).
    expect(registry.spec('projects').parents, isEmpty);
    expect(
      registry.spec('time_entries').parents.single.parentTable,
      'projects',
    );
    // Неизменяемые колонки по контракту.
    expect(
      registry.spec('change_requests').column('project_id')!.immutable,
      isTrue,
    );
    for (final c in ['payment_id', 'project_id', 'change_request_id']) {
      expect(registry.spec('payment_allocations').column(c)!.immutable, isTrue);
    }
    expect(
      registry.spec('time_entries').column('project_id')!.immutable,
      isFalse,
    );
    expect(
      registry.spec('payments').titleOf({
        'paid_at': '2026-10-05T09:00:00Z',
        'comment': 'Аванс',
      }),
      contains('Аванс'),
    );
    expect(registry.spec('payment_allocations').titleOf(const {}), isNotEmpty);
    expect(
      registry.spec('time_entries').titleOf({
        'started_at': '2026-10-05T09:00:00Z',
      }),
      contains('2026-10-05'),
    );
    expect(
      registry.spec('change_requests').titleOf({'title': 'Фильтры'}),
      'Фильтры',
    );
  });

  test('офлайн на телефоне: проект, платёж, время доезжают до ПК', () async {
    phone.device.remote.faults.offline = true;
    final romaId = _uuid(1);
    await phone.work.createPerson(
      WorkPerson(id: romaId, name: 'Рома', role: PersonRole.client),
    );
    final pid = _uuid(2);
    await phone.work.createProject(
      WorkProject(
        id: pid,
        title: 'Бот',
        clientId: romaId,
        status: ProjectStatus.active,
        payType: PayType.hourly,
        hourlyRate: 150000,
        baseAmount: 2000000,
        startDate: '2026-09-01',
        deadlineDate: '2026-10-15',
        description: 'Описание',
        links: const [ProjectLink(url: 'https://x.example', title: 'Док')],
      ),
    );
    final crId = _uuid(3);
    await phone.work.createChangeRequest(
      ChangeRequest(
        id: crId,
        projectId: pid,
        title: 'Вход',
        amount: 200000,
        status: ChangeRequestStatus.closed,
        closedDate: '2026-10-01',
        estimateMinutes: 90,
        note: 'ок',
      ),
    );
    final payId = _uuid(4);
    await phone.work.createPayment(
      Payment(
        id: payId,
        paidAt: DateTime.utc(2026, 9, 30, 20, 59, 59),
        amount: 1000000,
        payerId: romaId,
      ),
      [
        AllocationDraft(projectId: pid, amount: 800000),
        AllocationDraft(projectId: pid, changeRequestId: crId, amount: 100000),
      ],
    );
    await phone.work.addManualEntry(
      TimeEntry(
        id: _uuid(5),
        projectId: pid,
        changeRequestId: crId,
        startedAt: DateTime.utc(2026, 10, 1, 7),
        endedAt: DateTime.utc(2026, 10, 1, 9, 30),
        billable: true,
        source: TimeSource.manual,
      ),
    );
    phone.device.remote.faults.offline = false;
    await syncBoth();

    final project = (await read(pc, 'projects', WorkProject.fromRow)).single;
    expect(project.title, 'Бот');
    expect(project.clientId, romaId);
    expect(project.payType, PayType.hourly);
    expect(project.hourlyRate, 150000);
    expect(project.baseAmount, 2000000);
    expect(project.links.single.url, 'https://x.example');
    expect(project.deadlineDate, '2026-10-15');
    final person = (await read(pc, 'people', WorkPerson.fromRow)).single;
    expect(person.role, PersonRole.client);

    final crs = await read(pc, 'change_requests', ChangeRequest.fromRow);
    final payments = await read(pc, 'payments', Payment.fromRow);
    final allocations = await read(
      pc,
      'payment_allocations',
      Allocation.fromRow,
    );
    final entries = await read(pc, 'time_entries', TimeEntry.fromRow);
    expect(crs.single.estimateMinutes, 90);
    expect(payments.single.paidAt, DateTime.utc(2026, 9, 30, 20, 59, 59));
    expect(allocations, hasLength(2));
    expect(entrySeconds(entries.single), 9000);

    // Расчёты на обоих устройствах совпадают с серверными данными.
    final s = projectSummary(project, crs, allocations);
    expect(s.total, 2200000);
    expect(s.received, 900000);
    expect(s.remaining, 1300000);
    final r = receivables([project], crs, allocations);
    expect(r.total, 1300000);
    expect(r.clients.single.clientId, romaId);
    // 30 сентября 20:59:59Z — ещё сентябрь по Москве.
    expect(monthlyReceived(payments, allocations).single.month, '2026-09');
    expect(server.snapshot('payment_allocations'), hasLength(2));
  });

  test('проекты этапа 2 без новых колонок читаются как «в работе»', () async {
    final id = await TaskRepository(
      phone.device.store,
      newId: () => _uuid(60),
    ).createProject('Старый проект');
    await syncBoth();
    final p = (await read(pc, 'projects', WorkProject.fromRow)).single;
    expect(p.id, id);
    expect(p.effectiveStatus, ProjectStatus.active);
    expect(p.effectivePayType, PayType.fixed);
    expect(p.base, 0);
    expect(p.clientId, isNull);
  });

  test('удаление проекта каскадом скрывает доработки, оплаты и время; '
      'платёж остаётся; восстановление возвращает', () async {
    final pid = _uuid(10);
    await phone.work.createProject(
      WorkProject(id: pid, title: 'П', baseAmount: 100),
    );
    final crId = _uuid(11);
    await phone.work.createChangeRequest(
      ChangeRequest(
        id: crId,
        projectId: pid,
        title: 'Д',
        amount: 50,
        status: ChangeRequestStatus.inProgress,
      ),
    );
    await phone.work.createPayment(
      Payment(id: _uuid(12), paidAt: DateTime.utc(2026, 10), amount: 100),
      [AllocationDraft(projectId: pid, amount: 60)],
    );
    await phone.work.addManualEntry(
      TimeEntry(
        id: _uuid(13),
        projectId: pid,
        startedAt: DateTime.utc(2026, 10, 1, 7),
        endedAt: DateTime.utc(2026, 10, 1, 8),
        billable: true,
        source: TimeSource.manual,
      ),
    );
    await syncBoth();
    expect(
      await read(pc, 'payment_allocations', Allocation.fromRow),
      hasLength(1),
    );

    await phone.work.deleteProject(pid);
    await syncBoth();
    expect(await read(pc, 'projects', WorkProject.fromRow), isEmpty);
    expect(await read(pc, 'change_requests', ChangeRequest.fromRow), isEmpty);
    expect(await read(pc, 'payment_allocations', Allocation.fromRow), isEmpty);
    expect(await read(pc, 'time_entries', TimeEntry.fromRow), isEmpty);
    expect(await read(pc, 'payments', Payment.fromRow), hasLength(1));

    await phone.work.restoreProject(pid);
    await syncBoth();
    expect(
      await read(pc, 'change_requests', ChangeRequest.fromRow),
      hasLength(1),
    );
    expect(
      await read(pc, 'payment_allocations', Allocation.fromRow),
      hasLength(1),
    );
    expect(await read(pc, 'time_entries', TimeEntry.fromRow), hasLength(1));
  });

  test('удаление платежа каскадом скрывает его распределения', () async {
    final pid = _uuid(20);
    await phone.work.createProject(WorkProject(id: pid, title: 'П'));
    final payId = _uuid(21);
    await phone.work.createPayment(
      Payment(id: payId, paidAt: DateTime.utc(2026, 10), amount: 100),
      [AllocationDraft(projectId: pid, amount: 100)],
    );
    await syncBoth();
    await phone.work.deletePayment(payId);
    await syncBoth();
    expect(await read(pc, 'payments', Payment.fromRow), isEmpty);
    expect(await read(pc, 'payment_allocations', Allocation.fromRow), isEmpty);
    expect(await read(pc, 'projects', WorkProject.fromRow), hasLength(1));
  });

  test('одновременная правка разных полей доработки сливается', () async {
    final pid = _uuid(30);
    final crId = _uuid(31);
    await phone.work.createProject(WorkProject(id: pid, title: 'П'));
    await phone.work.createChangeRequest(
      ChangeRequest(
        id: crId,
        projectId: pid,
        title: 'Было',
        amount: 100,
        status: ChangeRequestStatus.inProgress,
      ),
    );
    await syncBoth();
    clock.advance(const Duration(seconds: 5));
    await phone.work.updateChangeRequest(
      (await phone.work.getChangeRequest(crId))!.copyWith(title: 'Стало'),
    );
    clock.advance(const Duration(seconds: 5));
    await pc.work.updateChangeRequest(
      (await pc.work.getChangeRequest(crId))!.copyWith(amount: 777),
    );
    await syncBoth();
    for (final d in [phone, pc]) {
      final cr = (await d.work.getChangeRequest(crId))!;
      expect(cr.title, 'Стало');
      expect(cr.amount, 777);
    }
  });

  test('два таймера, запущенные офлайн на разных устройствах: после '
      'синхронизации видны оба, остановка любого уходит на второе', () async {
    final pid = _uuid(40);
    await phone.work.createProject(WorkProject(id: pid, title: 'П'));
    await syncBoth();
    phone.device.remote.faults.offline = true;
    pc.device.remote.faults.offline = true;
    clock.advance(const Duration(minutes: 1));
    final a = await phone.work.startTimer(projectId: pid, note: 'телефон');
    clock.advance(const Duration(minutes: 2));
    final b = await pc.work.startTimer(projectId: pid, note: 'ПК');
    // Офлайн на каждом устройстве идёт ровно один таймер.
    expect(await phone.work.runningEntries(), hasLength(1));
    expect(await pc.work.runningEntries(), hasLength(1));
    expect(hasTimerConflict(await phone.work.runningEntries()), isFalse);

    phone.device.remote.faults.offline = false;
    pc.device.remote.faults.offline = false;
    await syncBoth();
    final onPhone = await phone.work.runningEntries();
    final onPc = await pc.work.runningEntries();
    expect(onPhone.map((e) => e.id).toSet(), {a.started.id, b.started.id});
    expect(onPc.map((e) => e.id).toSet(), {a.started.id, b.started.id});
    expect(hasTimerConflict(onPhone), isTrue);
    expect(hasTimerConflict(onPc), isTrue);
    // Главный — самый поздний по началу.
    expect(primaryTimer(onPhone)!.id, b.started.id);

    clock.advance(const Duration(minutes: 5));
    await phone.work.stopTimer(b.started.id);
    await syncBoth();
    for (final d in [phone, pc]) {
      final running = await d.work.runningEntries();
      expect(running.map((e) => e.id), [a.started.id]);
      expect(hasTimerConflict(running), isFalse);
    }
    // Запись, остановленная на телефоне, закрыта и на ПК.
    expect((await pc.work.getEntry(b.started.id))!.endedAt, isNotNull);
  });
}
