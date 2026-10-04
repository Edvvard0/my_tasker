import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/calendar_env.dart';
import '../../support/manual_clock.dart';
import '../../support/work_env.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

Matcher _invalid([String? part]) => throwsA(
  isA<ValidationError>().having(
    (e) => e.message,
    'message',
    part == null ? isNotEmpty : contains(part),
  ),
);

void main() {
  late ManualClock clock;
  late WorkDevice dev;
  late WorkRepository repo;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    counter = 0;
    dev = await WorkDevice.create(
      appServer(clock),
      clock: clock,
      newId: () => _uuid(5000 + ++counter),
    );
    repo = dev.work;
  });
  tearDown(() => dev.close());

  Future<String> project({
    String title = 'Бот',
    int base = 10000000,
    ProjectStatus? status = ProjectStatus.active,
    String? completedDate,
  }) async {
    final id = repo.newId();
    await repo.createProject(
      WorkProject(
        id: id,
        title: title,
        baseAmount: base,
        status: status,
        completedDate: completedDate,
      ),
    );
    return id;
  }

  Future<String> changeRequest(
    String projectId, {
    String title = 'Фильтры',
    int amount = 2000000,
    ChangeRequestStatus status = ChangeRequestStatus.inProgress,
    String? closed,
  }) async {
    final id = repo.newId();
    await repo.createChangeRequest(
      ChangeRequest(
        id: id,
        projectId: projectId,
        title: title,
        amount: amount,
        status: status,
        closedDate: closed,
      ),
    );
    return id;
  }

  Payment payment(int amount, {DateTime? at, String? payerId}) => Payment(
    id: repo.newId(),
    paidAt: at ?? DateTime.utc(2026, 10, 5, 9),
    amount: amount,
    payerId: payerId,
  );

  group('проекты', () {
    test('создание и чтение: все поля, мягкие значения по умолчанию', () async {
      final id = repo.newId();
      await repo.createProject(
        WorkProject(
          id: id,
          title: '  Платформа  ',
          clientId: _uuid(1),
          status: ProjectStatus.paused,
          payType: PayType.hourly,
          hourlyRate: 150000,
          baseAmount: 5000000,
          startDate: '2026-09-01',
          deadlineDate: '2026-11-30',
          description: 'Заметка',
          links: const [ProjectLink(url: 'https://a.example', title: 'Док')],
        ),
      );
      final p = (await repo.getProject(id))!;
      expect(p.title, 'Платформа');
      expect(p.status, ProjectStatus.paused);
      expect(p.payType, PayType.hourly);
      expect(p.hourlyRate, 150000);
      expect(p.links.single.title, 'Док');
      expect(p.clientId, _uuid(1));
      // Строка этапа 2 (без новых колонок) читается как «в работе», фикс, 0.
      final bare = WorkProject.fromRow(const {'id': 'x', 'title': 'Старый'});
      expect(bare.effectiveStatus, ProjectStatus.active);
      expect(bare.effectivePayType, PayType.fixed);
      expect(bare.base, 0);
    });

    test('проверки повторяют серверные', () async {
      Future<void> bad(WorkProject p, String part) async {
        await expectLater(repo.createProject(p), _invalid(part));
      }

      await bad(WorkProject(id: repo.newId(), title: '  '), 'Название');
      await bad(
        WorkProject(id: repo.newId(), title: 'A', payType: PayType.hourly),
        'ставку',
      );
      await bad(
        WorkProject(
          id: repo.newId(),
          title: 'A',
          status: ProjectStatus.completed,
        ),
        'дату завершения',
      );
      await bad(
        WorkProject(
          id: repo.newId(),
          title: 'A',
          status: ProjectStatus.active,
          archived: true,
        ),
        'В архив',
      );
      await bad(
        WorkProject(
          id: repo.newId(),
          title: 'A',
          startDate: '2026-10-10',
          deadlineDate: '2026-10-01',
        ),
        'Срок раньше',
      );
      await bad(
        WorkProject(id: repo.newId(), title: 'A', deadlineDate: '2026-02-30'),
        'нет такой даты',
      );
      await bad(
        WorkProject(id: repo.newId(), title: 'A', baseAmount: -1),
        'Базовая сумма',
      );
      await bad(
        WorkProject(
          id: repo.newId(),
          title: 'A',
          links: const [ProjectLink(url: 'ftp://x')],
        ),
        'http',
      );
      await bad(
        WorkProject(id: repo.newId(), title: 'A', color: 'red'),
        'Цвет',
      );
    });

    test('правка отправляет только изменённые поля', () async {
      final id = await project();
      final before = (await dev.device.store.outbox()).length;
      final p = (await repo.getProject(id))!;
      await repo.updateProject(p.copyWith(baseAmount: 12000000));
      final ops = await dev.device.store.outbox();
      // Правка схлопывается с неотправленным созданием: одна операция.
      expect(ops.length, before);
      expect((await repo.getProject(id))!.base, 12000000);
      await repo.updateProject(p.copyWith(baseAmount: 12000000));
      await expectLater(
        repo.updateProject(WorkProject(id: _uuid(9999), title: 'нет')),
        throwsStateError,
      );
    });

    test(
      '«завершён» ставит дату завершения, возврат в работу снимает архив',
      () async {
        final id = await project();
        await repo.setProjectStatus(id, ProjectStatus.completed);
        var p = (await repo.getProject(id))!;
        expect(p.status, ProjectStatus.completed);
        expect(p.completedDate, '2026-10-05');
        await repo.setArchived(id, archived: true);
        expect((await repo.getProject(id))!.archived, isTrue);
        await repo.setProjectStatus(id, ProjectStatus.active);
        p = (await repo.getProject(id))!;
        expect(p.archived, isFalse);
        expect(p.status, ProjectStatus.active);
        // Явная дата не затирается.
        await repo.setProjectStatus(
          id,
          ProjectStatus.completed,
          completedDate: '2026-10-01',
        );
        expect((await repo.getProject(id))!.completedDate, '2026-10-05');
        await repo.setProjectStatus(_uuid(404), ProjectStatus.paused);
      },
    );

    test(
      'в архив — только завершённые и отменённые, обратно — любой',
      () async {
        final id = await project();
        await expectLater(
          repo.setArchived(id, archived: true),
          _invalid('только завершённый'),
        );
        await repo.setProjectStatus(id, ProjectStatus.cancelled);
        await repo.setArchived(id, archived: true);
        await repo.setArchived(id, archived: true);
        expect((await repo.getProject(id))!.archived, isTrue);
        await repo.setArchived(id, archived: false);
        expect((await repo.getProject(id))!.archived, isFalse);
        await repo.setArchived(_uuid(404), archived: true);
      },
    );

    test(
      'удаление скрывает доработки, распределения и время; платёж остаётся',
      () async {
        final id = await project();
        final cr = await changeRequest(id);
        final pay = payment(1000000);
        await repo.createPayment(pay, [
          AllocationDraft(projectId: id, changeRequestId: cr, amount: 500000),
        ]);
        await repo.addManualEntry(
          TimeEntry(
            id: repo.newId(),
            projectId: id,
            startedAt: DateTime.utc(2026, 10, 1, 7),
            endedAt: DateTime.utc(2026, 10, 1, 8),
            billable: true,
            source: TimeSource.manual,
          ),
        );
        final store = dev.device.store;
        expect(await store.visibleRows('change_requests'), hasLength(1));
        await repo.deleteProject(id);
        expect(await store.visibleRows('projects'), isEmpty);
        expect(await store.visibleRows('change_requests'), isEmpty);
        expect(await store.visibleRows('payment_allocations'), isEmpty);
        expect(await store.visibleRows('time_entries'), isEmpty);
        expect(await store.visibleRows('payments'), hasLength(1));
        await repo.restoreProject(id);
        expect(await store.visibleRows('change_requests'), hasLength(1));
        expect(await store.visibleRows('payment_allocations'), hasLength(1));
        expect(await store.visibleRows('time_entries'), hasLength(1));
      },
    );
  });

  group('люди', () {
    test('создание, правка, архив, удаление не трогает проекты', () async {
      final id = repo.newId();
      await repo.createPerson(
        WorkPerson(
          id: id,
          name: ' Рома ',
          role: PersonRole.client,
          contact: '@roma',
        ),
      );
      var p = (await repo.getPerson(id))!;
      expect(p.name, 'Рома');
      expect(p.isClient, isTrue);
      expect(p.contact, '@roma');
      await repo.updatePerson(
        p.copyWith(role: PersonRole.other, contact: null),
      );
      p = (await repo.getPerson(id))!;
      expect(p.role, PersonRole.other);
      expect(p.contact, isNull);
      await repo.updatePerson(p);
      await expectLater(
        repo.updatePerson(WorkPerson(id: _uuid(9998), name: 'нет')),
        throwsStateError,
      );
      await expectLater(
        repo.createPerson(WorkPerson(id: repo.newId(), name: ' ')),
        _invalid('Имя'),
      );
      await expectLater(
        repo.createPerson(
          WorkPerson(id: repo.newId(), name: 'A', contact: 'x' * 501),
        ),
        _invalid('Контакт'),
      );

      final projectId = repo.newId();
      await repo.createProject(
        WorkProject(id: projectId, title: 'П', clientId: id),
      );
      await repo.setPersonArchived(id, archived: true);
      expect((await repo.getPerson(id))!.archived, isTrue);
      await repo.deletePerson(id);
      expect(await dev.device.store.visibleRows('people'), isEmpty);
      // Ссылка на заказчика остаётся, проект цел.
      expect((await repo.getProject(projectId))!.clientId, id);
      expect(await dev.device.store.visibleRows('projects'), hasLength(1));
      await repo.restorePerson(id);
      expect(await dev.device.store.visibleRows('people'), hasLength(1));
    });
  });

  group('доработки', () {
    test('создание, закрытие ставит дату, проверки', () async {
      final pid = await project();
      final id = await changeRequest(pid);
      await repo.setChangeRequestStatus(id, ChangeRequestStatus.closed);
      var cr = (await repo.getChangeRequest(id))!;
      expect(cr.status, ChangeRequestStatus.closed);
      expect(cr.closedDate, '2026-10-05');
      await repo.setChangeRequestStatus(id, ChangeRequestStatus.cancelled);
      cr = (await repo.getChangeRequest(id))!;
      expect(cr.status, ChangeRequestStatus.cancelled);
      await repo.setChangeRequestStatus(_uuid(404), ChangeRequestStatus.closed);
      await repo.updateChangeRequest(cr);

      Future<void> bad(ChangeRequest c, String part) =>
          expectLater(repo.createChangeRequest(c), _invalid(part));
      await bad(
        ChangeRequest(
          id: repo.newId(),
          projectId: pid,
          title: '',
          amount: 1,
          status: ChangeRequestStatus.inProgress,
        ),
        'Название',
      );
      await bad(
        ChangeRequest(
          id: repo.newId(),
          projectId: pid,
          title: 'A',
          amount: -5,
          status: ChangeRequestStatus.inProgress,
        ),
        'Сумма',
      );
      await bad(
        ChangeRequest(
          id: repo.newId(),
          projectId: pid,
          title: 'A',
          amount: 5,
          status: ChangeRequestStatus.closed,
        ),
        'дату закрытия',
      );
      await bad(
        ChangeRequest(
          id: repo.newId(),
          projectId: pid,
          title: 'A',
          amount: 5,
          status: ChangeRequestStatus.closed,
          closedDate: '2026-13-40',
        ),
        'нет такой даты',
      );
      await bad(
        ChangeRequest(
          id: repo.newId(),
          projectId: pid,
          title: 'A',
          amount: 5,
          status: ChangeRequestStatus.inProgress,
          estimateMinutes: 700000,
        ),
        'Оценка',
      );
      await expectLater(
        repo.updateChangeRequest(
          ChangeRequest(
            id: _uuid(9997),
            projectId: pid,
            title: 'A',
            amount: 5,
            status: ChangeRequestStatus.inProgress,
          ),
        ),
        throwsStateError,
      );
    });

    test('удаление доработки: деньги остаются оплатой базовой суммы', () async {
      final pid = await project();
      final cr = await changeRequest(pid, amount: 3000000);
      await repo.createPayment(payment(2000000), [
        AllocationDraft(projectId: pid, changeRequestId: cr, amount: 2000000),
      ]);
      await repo.deleteChangeRequest(cr);
      final store = dev.device.store;
      final p = WorkProject.fromRow((await store.getRow('projects', pid))!);
      final crs = [
        for (final r in await store.visibleRows('change_requests'))
          ChangeRequest.fromRow(r),
      ];
      final allocations = [
        for (final r in await store.visibleRows('payment_allocations'))
          Allocation.fromRow(r),
      ];
      expect(crs, isEmpty);
      final s = projectSummary(p, crs, allocations);
      expect(s.received, 2000000);
      expect(s.baseReceived, 2000000);
      expect(s.total, 10000000);
      await repo.restoreChangeRequest(cr);
      expect(await store.visibleRows('change_requests'), hasLength(1));
    });
  });

  group('платежи и распределения', () {
    test('платёж с распределениями создаётся одной операцией', () async {
      final a = await project(title: 'A');
      final b = await project(title: 'B');
      final cr = await changeRequest(a);
      final pay = payment(5000000);
      await repo.createPayment(pay, [
        AllocationDraft(projectId: a, amount: 1000000),
        AllocationDraft(projectId: a, changeRequestId: cr, amount: 1500000),
        AllocationDraft(projectId: b, amount: 1500000),
      ]);
      final stored = (await repo.getPayment(pay.id))!;
      expect(stored.amount, 5000000);
      final allocations = await repo.allocationsOfPayment(pay.id);
      expect(allocations, hasLength(3));
      expect(
        allocations.fold<int>(0, (s, x) => s + x.amount),
        4000000,
        reason: 'не разнесённая часть допустима',
      );
    });

    test(
      'проверки клиента: переплата, дубли, чужая доработка, суммы',
      () async {
        final a = await project(title: 'A');
        final b = await project(title: 'B');
        final cr = await changeRequest(a);
        await expectLater(
          repo.createPayment(payment(100), [
            AllocationDraft(projectId: a, amount: 101),
          ]),
          _invalid('Распределено больше'),
        );
        await expectLater(
          repo.createPayment(payment(100), [
            AllocationDraft(projectId: a, amount: 10),
            AllocationDraft(projectId: a, amount: 20),
          ]),
          _invalid('дважды'),
        );
        await expectLater(
          repo.createPayment(payment(100), [
            AllocationDraft(projectId: b, changeRequestId: cr, amount: 10),
          ]),
          _invalid('другому проекту'),
        );
        await expectLater(
          repo.createPayment(payment(0), const []),
          _invalid('Сумма платежа'),
        );
        await expectLater(
          repo.createPayment(payment(100), [
            AllocationDraft(projectId: a, amount: 0),
          ]),
          _invalid('Сумма распределения'),
        );
        await expectLater(
          repo.createPayment(
            Payment(
              id: repo.newId(),
              paidAt: DateTime.utc(2014, 12, 31),
              amount: 100,
            ),
            const [],
          ),
          _invalid('2015'),
        );
        await expectLater(
          repo.createPayment(
            Payment(
              id: repo.newId(),
              paidAt: DateTime.utc(2026),
              amount: 100,
              comment: 'x' * 2001,
            ),
            const [],
          ),
          _invalid('Комментарий'),
        );
        expect(await dev.device.store.visibleRows('payments'), isEmpty);
      },
    );

    test('правка платежа: сумма, новые и убранные строки', () async {
      final a = await project(title: 'A');
      final b = await project(title: 'B');
      final pay = payment(3000000);
      await repo.createPayment(pay, [
        AllocationDraft(projectId: a, amount: 1000000),
        AllocationDraft(projectId: b, amount: 500000),
      ]);
      final before = await repo.allocationsOfPayment(pay.id);
      final aId = before.firstWhere((x) => x.projectId == a).id;
      await repo.updatePayment(
        Payment(
          id: pay.id,
          paidAt: pay.paidAt,
          amount: 4000000,
          comment: 'Октябрь',
        ),
        [AllocationDraft(projectId: a, amount: 1200000)],
      );
      final stored = (await repo.getPayment(pay.id))!;
      expect(stored.amount, 4000000);
      expect(stored.comment, 'Октябрь');
      final after = await repo.allocationsOfPayment(pay.id);
      expect(after, hasLength(1));
      expect(after.single.id, aId, reason: 'та же строка, новая сумма');
      expect(after.single.amount, 1200000);

      await repo.updatePayment(stored, [
        AllocationDraft(projectId: a, amount: 1200000),
        AllocationDraft(projectId: b, amount: 100),
      ]);
      expect(await repo.allocationsOfPayment(pay.id), hasLength(2));
      await expectLater(
        repo.updatePayment(payment(100), const []),
        throwsStateError,
      );
      await expectLater(
        repo.updatePayment(stored, [
          AllocationDraft(projectId: a, amount: 9000000),
        ]),
        _invalid('Распределено больше'),
      );
    });

    test(
      'правка платежа: дубли распределений на одно «куда» удаляются',
      () async {
        final a = await project(title: 'A');
        final b = await project(title: 'B');
        final pay = payment(5000);
        await repo.createPayment(pay, [
          AllocationDraft(projectId: a, amount: 1000),
        ]);
        // Вторая строка на тот же проект пришла с другого устройства, и ещё
        // две — на проект B, которого в форме уже нет.
        for (final (target, amount) in [(a, 700), (b, 300), (b, 200)]) {
          await dev.device.store.create('payment_allocations', repo.newId(), {
            'payment_id': pay.id,
            'project_id': target,
            'change_request_id': null,
            'amount': amount,
          });
        }
        expect(await repo.allocationsOfPayment(pay.id), hasLength(4));
        final stored = (await repo.getPayment(pay.id))!;
        await repo.updatePayment(stored, [
          AllocationDraft(projectId: a, amount: 1500),
        ]);
        final after = await repo.allocationsOfPayment(pay.id);
        expect(after, hasLength(1));
        expect(after.single.projectId, a);
        expect(after.single.amount, 1500);
        final rows = await dev.device.store.visibleRows('payment_allocations');
        expect(rows, hasLength(1), reason: 'лишние строки удалены мягко');
      },
    );

    test(
      'удаление платежа скрывает распределения, возврат — возвращает',
      () async {
        final a = await project();
        final pay = payment(1000);
        await repo.createPayment(pay, [
          AllocationDraft(projectId: a, amount: 600),
        ]);
        await repo.deletePayment(pay.id);
        final store = dev.device.store;
        expect(await store.visibleRows('payments'), isEmpty);
        expect(await store.visibleRows('payment_allocations'), isEmpty);
        await repo.restorePayment(pay.id);
        expect(await store.visibleRows('payment_allocations'), hasLength(1));
      },
    );
  });

  group('время', () {
    TimeEntry entry(String projectId, DateTime start, DateTime? end) =>
        TimeEntry(
          id: repo.newId(),
          projectId: projectId,
          startedAt: start,
          endedAt: end,
          billable: true,
          source: TimeSource.manual,
        );

    test('запись вручную: проверки и правка', () async {
      final pid = await project();
      final start = DateTime.utc(2026, 10, 1, 7);
      await expectLater(
        repo.addManualEntry(entry(pid, start, null)),
        _invalid('окончание'),
      );
      await expectLater(
        repo.addManualEntry(
          entry(pid, start, start.subtract(const Duration(hours: 1))),
        ),
        _invalid('раньше начала'),
      );
      await expectLater(
        repo.addManualEntry(
          entry(pid, start, start.add(const Duration(days: 14))),
        ),
        _invalid('14 суток'),
      );
      await expectLater(
        repo.addManualEntry(
          entry(pid, DateTime.utc(2014), DateTime.utc(2014, 1, 2)),
        ),
        _invalid('2015'),
      );
      final ok = entry(pid, start, start.add(const Duration(hours: 2)));
      await repo.addManualEntry(ok);
      final read = (await repo.getEntry(ok.id))!;
      expect(entrySeconds(read), 7200);
      expect(read.source, TimeSource.manual);
      await repo.updateEntry(read.copyWith(billable: false, note: 'созвон'));
      final changed = (await repo.getEntry(ok.id))!;
      expect(changed.billable, isFalse);
      expect(changed.note, 'созвон');
      await repo.updateEntry(changed);
      await expectLater(
        repo.updateEntry(entry(pid, start, start)),
        throwsStateError,
      );
      await repo.deleteEntry(ok.id);
      expect(await dev.device.store.visibleRows('time_entries'), isEmpty);
      await repo.restoreEntry(ok.id);
      expect(await dev.device.store.visibleRows('time_entries'), hasLength(1));
    });

    test('таймер: старт пишет запись без окончания, стоп закрывает', () async {
      final pid = await project();
      final started = await repo.startTimer(projectId: pid, note: 'вход');
      expect(started.stopped, isEmpty);
      expect(started.started.isRunning, isTrue);
      expect(started.started.source, TimeSource.timer);
      expect(started.started.startedAt, clock.now);
      expect(await repo.runningEntries(), hasLength(1));
      clock.advance(const Duration(minutes: 72, seconds: 43));
      final stopped = (await repo.stopTimer(started.started.id))!;
      expect(stopped.endedAt, clock.now);
      expect(entrySeconds(stopped), 72 * 60 + 43);
      expect(await repo.runningEntries(), isEmpty);
      // Повторная остановка и остановка неизвестной записи — не ошибка.
      expect(await repo.stopTimer(started.started.id), isNull);
      expect(await repo.stopTimer(_uuid(404)), isNull);
    });

    test('один таймер на устройстве: новый останавливает идущий', () async {
      final a = await project(title: 'A');
      final b = await project(title: 'B');
      final first = await repo.startTimer(projectId: a);
      clock.advance(const Duration(minutes: 30));
      final second = await repo.startTimer(projectId: b);
      expect(second.stopped.map((e) => e.id), [first.started.id]);
      expect(second.stopped.single.endedAt, clock.now);
      final running = await repo.runningEntries();
      expect(running.map((e) => e.id), [second.started.id]);
      final firstRow = (await repo.getEntry(first.started.id))!;
      expect(entrySeconds(firstRow), 1800);
    });

    test('старт идемпотентен: двойной тап возвращает идущий таймер', () async {
      final a = await project(title: 'A');
      final cr = await changeRequest(a);
      final first = await repo.startTimer(projectId: a);
      clock.advance(const Duration(seconds: 1));
      final again = await repo.startTimer(projectId: a);
      expect(again.started.id, first.started.id);
      expect(again.stopped, isEmpty);
      expect(await repo.runningEntries(), hasLength(1));
      expect(
        await dev.device.store.visibleRows('time_entries'),
        hasLength(1),
        reason: 'записи «0 мин» не появилось',
      );
      // Та же доработка — другой таймер: прежний останавливается.
      final other = await repo.startTimer(projectId: a, changeRequestId: cr);
      expect(other.started.id, isNot(first.started.id));
      expect(other.stopped.single.id, first.started.id);
      final same = await repo.startTimer(projectId: a, changeRequestId: cr);
      expect(same.started.id, other.started.id);
      expect(same.stopped, isEmpty);
    });

    test('таймер из чужого устройства тоже останавливается новым', () async {
      final a = await project();
      // Идущая запись пришла с другого устройства (видима, без окончания).
      final foreign = TimeEntry(
        id: repo.newId(),
        projectId: a,
        startedAt: clock.now.subtract(const Duration(hours: 1)),
        billable: true,
        source: TimeSource.timer,
      );
      await dev.device.store.create(
        'time_entries',
        foreign.id,
        foreign.toFields(),
      );
      final b = await project(title: 'B');
      final result = await repo.startTimer(projectId: b);
      expect(result.stopped.single.id, foreign.id);
    });

    test('забытый таймер: остановка не длиннее 14 суток', () async {
      final a = await project();
      final started = await repo.startTimer(projectId: a);
      clock.advance(const Duration(days: 20));
      final stopped = (await repo.stopTimer(started.started.id))!;
      expect(
        stopped.endedAt!.difference(stopped.startedAt),
        const Duration(days: 14) - const Duration(seconds: 1),
      );
      expect(repo.stopMoment(stopped, DateTime.utc(2000)), stopped.startedAt);
    });

    test('«Отменить запись»: идущий таймер уходит в корзину', () async {
      final a = await project();
      final started = await repo.startTimer(projectId: a);
      await repo.discardTimer(started.started.id);
      expect(await repo.runningEntries(), isEmpty);
    });

    test('таймер хранит доработку и задачу', () async {
      final a = await project();
      final cr = await changeRequest(a);
      final taskId = _uuid(777);
      final r = await repo.startTimer(
        projectId: a,
        changeRequestId: cr,
        taskId: taskId,
      );
      final stored = (await repo.getEntry(r.started.id))!;
      expect(stored.changeRequestId, cr);
      expect(stored.taskId, taskId);
      expect(stored.originDeviceId, isNotNull);
    });
  });

  test('сумма проекта и остаток после ввода данных репозиторием', () async {
    final id = await project();
    final cr = await changeRequest(id);
    await changeRequest(
      id,
      title: 'Отменённая',
      amount: 1500000,
      status: ChangeRequestStatus.cancelled,
    );
    await repo.createPayment(payment(7000000), [
      AllocationDraft(projectId: id, amount: 6000000),
      AllocationDraft(projectId: id, changeRequestId: cr, amount: 1000000),
    ]);
    final store = dev.device.store;
    final p = WorkProject.fromRow((await store.getRow('projects', id))!);
    final s = projectSummary(
      p,
      [
        for (final r in await store.visibleRows('change_requests'))
          ChangeRequest.fromRow(r),
      ],
      [
        for (final r in await store.visibleRows('payment_allocations'))
          Allocation.fromRow(r),
      ],
    );
    expect(s.total, 12000000);
    expect(s.received, 7000000);
    expect(s.remaining, 5000000);
    expect(s.paidBp, 5833);
    expect(formatDate(DateTime.utc(2026, 10, 5)), '2026-10-05');
  });
}
