import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/domain/work_validation.dart';

import '../../support/work_env.dart';

void main() {
  group('форматирование', () {
    test('суммы для плиток: усечение, без округления вверх', () {
      expect(formatAmountShort(0), nb('0 ₽'));
      expect(formatAmountShort(999999), nb('9 999,99 ₽'));
      expect(formatAmountShort(1000000), nb('10к ₽'));
      expect(formatAmountShort(1999999), nb('19,9к ₽'));
      expect(formatAmountShort(8050000), nb('80,5к ₽'));
      expect(formatAmountShort(99999999), nb('999,9к ₽'));
      expect(formatAmountShort(100000000), nb('1 млн ₽'));
      expect(formatAmountShort(129999999), nb('1,2 млн ₽'));
      expect(formatAmountShort(-8050000), nb('-80,5к ₽'));
      expect(formatAmountShort(-250000000), nb('-2,5 млн ₽'));
    });

    test('доля оплаты: усечением, «100 %» только при полной оплате', () {
      expect(formatPercentBp(0), '0 %');
      expect(formatPercentBp(3333), '33,3 %');
      expect(formatPercentBp(9999), '99,9 %');
      expect(formatPercentBp(10000), '100 %');
      expect(formatPercentBp(15000), '150 %');
      expect(formatPercentWhole(9999), '99%');
      expect(formatPercentWhole(8076), '80%');
    });

    test('часы, таймер, доход в час', () {
      expect(formatHours(0), '0 мин');
      expect(formatHours(59), '0 мин');
      expect(formatHours(45 * 60), '45 мин');
      expect(formatHours(3600), '1 ч');
      expect(formatHours(34 * 3600 + 15 * 60), '34 ч 15 мин');
      expect(formatTimer(Duration.zero), '00:00:00');
      expect(
        formatTimer(const Duration(hours: 1, minutes: 12, seconds: 43)),
        '01:12:43',
      );
      expect(formatTimer(const Duration(hours: 100)), '100:00:00');
      expect(formatTimer(const Duration(seconds: -5)), '00:00:00');
      expect(formatPerHour(null), '—');
      expect(formatPerHour(33333), '${nb('333,33 ₽')}/ч');
      expect(formatPerHourShort(null), '—');
      expect(formatPerHourShort(33333), nb('333,33 ₽'));
    });

    test('месяцы и даты', () {
      final now = DateTime.utc(2026, 9, 30);
      expect(formatMonthKey('2026-09', now), 'сент.');
      expect(formatMonthKey('2025-12', now), 'дек. 2025');
      expect(formatMonthKey('2026-05', now), 'май');
      expect(formatDateText('2026-10-15', now), '15 окт.');
      expect(formatDateText('2027-01-02', now), '2 янв. 2027');
      expect(formatDateText(null, now), '—');
      expect(formatDateText('15.10.2026', now), '—');
      expect(formatDateText('2026-xx-15', now), '—');
    });
  });

  group('модели', () {
    test('чтение строки с неизвестными значениями — значения по умолчанию', () {
      final p = WorkProject.fromRow(const {
        'id': 'p',
        'title': 'П',
        'status': 'from_the_future',
        'pay_type': '???',
        'links': [
          {'url': 'https://a.example'},
          {'title': 'без адреса'},
          'мусор',
        ],
      });
      expect(p.status, isNull);
      expect(p.effectiveStatus, ProjectStatus.active);
      expect(p.payType, isNull);
      expect(p.links.single.url, 'https://a.example');
      expect(
        WorkProject.fromRow(const {'id': 'p', 'links': 'не список'}).links,
        isEmpty,
      );
      expect(PersonRole.parse('boss'), isNull);
      expect(
        WorkPerson.fromRow(const {'id': 'h', 'name': 'Х'}).isClient,
        isFalse,
      );
      expect(ChangeRequestStatus.parse('???'), ChangeRequestStatus.inProgress);
      expect(TimeSource.parse('manual'), TimeSource.manual);
      expect(TimeSource.parse('timer'), TimeSource.timer);
      expect(TimeSource.parse(null), TimeSource.timer);
    });

    test('toFields ↔ fromRow: проект, платёж, запись времени', () {
      const project = WorkProject(
        id: 'p',
        title: 'П',
        archived: true,
        clientId: 'c',
        status: ProjectStatus.completed,
        payType: PayType.hourly,
        baseAmount: 100,
        hourlyRate: 50,
        startDate: '2026-01-01',
        deadlineDate: '2026-02-01',
        completedDate: '2026-02-02',
        description: 'д',
        links: [ProjectLink(url: 'https://x.example', title: 'Т')],
      );
      final f = project.toFields();
      expect(f['status'], 'completed');
      expect(f['links'], [
        {'url': 'https://x.example', 'title': 'Т'},
      ]);
      final back = WorkProject.fromRow({'id': 'p', ...f});
      expect(back.toFields(), f);
      expect(
        const WorkProject(id: 'p', title: 'П').toFields()['links'],
        isNull,
      );

      final payment = Payment(
        id: 'a',
        paidAt: DateTime.utc(2026, 9, 30, 20, 59, 59, 900),
        amount: 5,
      );
      expect(payment.toFields()['paid_at'], '2026-09-30T20:59:59Z');
      final entry = TimeEntry(
        id: 'e',
        projectId: 'p',
        startedAt: DateTime.utc(2026, 10, 1, 7),
        billable: false,
        source: TimeSource.timer,
      );
      expect(entry.isRunning, isTrue);
      expect(entry.toFields()['ended_at'], isNull);
      expect(entry.toFields()['billable'], isFalse);
      expect(storedWorkInstant(null), isNull);
    });

    test('copyWith сбрасывает необязательные значения в null', () {
      const cr = ChangeRequest(
        id: 'c',
        projectId: 'p',
        title: 'Д',
        amount: 1,
        status: ChangeRequestStatus.closed,
        closedDate: '2026-01-01',
        estimateMinutes: 5,
        note: 'н',
      );
      final cleared = cr.copyWith(
        closedDate: null,
        estimateMinutes: null,
        note: null,
      );
      expect(cleared.closedDate, isNull);
      expect(cleared.estimateMinutes, isNull);
      expect(cleared.note, isNull);
      expect(cr.copyWith().closedDate, '2026-01-01');
      const person = WorkPerson(
        id: 'h',
        name: 'Х',
        role: PersonRole.client,
        contact: 'к',
      );
      expect(person.copyWith(role: null, contact: null).role, isNull);
      expect(person.copyWith().contact, 'к');
      const project = WorkProject(
        id: 'p',
        title: 'П',
        color: '#112233',
        clientId: 'c',
      );
      final p2 = project.copyWith(
        color: null,
        clientId: null,
        status: null,
        payType: null,
        baseAmount: null,
        hourlyRate: null,
        startDate: null,
        deadlineDate: null,
        completedDate: null,
        description: null,
      );
      expect(p2.color, isNull);
      expect(p2.clientId, isNull);
      expect(project.copyWith().color, '#112233');
      final entry = TimeEntry(
        id: 'e',
        projectId: 'p',
        changeRequestId: 'c',
        taskId: 't',
        startedAt: DateTime.utc(2026),
        endedAt: DateTime.utc(2026, 1, 2),
        billable: true,
        note: 'н',
        source: TimeSource.manual,
      );
      final e2 = entry.copyWith(
        changeRequestId: null,
        taskId: null,
        endedAt: null,
        note: null,
      );
      expect(e2.changeRequestId, isNull);
      expect(e2.taskId, isNull);
      expect(e2.endedAt, isNull);
      expect(e2.note, isNull);
      expect(entry.copyWith().taskId, 't');
    });
  });

  group('период и месяцы', () {
    test('период включает границы; null — без ограничения', () {
      const p = DatePeriod(from: '2026-09-01', to: '2026-09-30');
      expect(p.contains('2026-09-01'), isTrue);
      expect(p.contains('2026-09-30'), isTrue);
      expect(p.contains('2026-08-31'), isFalse);
      expect(p.contains('2026-10-01'), isFalse);
      expect(p.contains(null), isFalse);
      expect(const DatePeriod().contains('1999-01-01'), isTrue);
      expect(
        const DatePeriod(from: '2026-01-01').contains('2025-12-31'),
        isFalse,
      );
      expect(
        const DatePeriod(to: '2026-01-01').contains('2026-01-02'),
        isFalse,
      );
    });

    test('monthPeriod: последний день месяца', () {
      expect(monthPeriod('2026-02').to, '2026-02-28');
      expect(monthPeriod('2028-02').to, '2028-02-29');
      expect(monthPeriod('2026-09'), isA<DatePeriod>());
      expect(monthPeriod('2026-12').from, '2026-12-01');
      expect(monthPeriod('2026-12').to, '2026-12-31');
    });
  });

  group('проверки клиента', () {
    test('ссылки', () {
      expect(linksProblem(const []), isNull);
      expect(
        linksProblem([
          for (var i = 0; i < 21; i++)
            const ProjectLink(url: 'https://a.example'),
        ]),
        contains('не больше 20'),
      );
      expect(
        linksProblem(const [ProjectLink(url: '')]),
        contains('от 1 до 500'),
      );
      expect(
        linksProblem([ProjectLink(url: 'https://${'a' * 500}')]),
        contains('от 1 до 500'),
      );
      expect(
        linksProblem(const [ProjectLink(url: 'ftp://a')]),
        contains('http'),
      );
      expect(
        linksProblem([ProjectLink(url: 'https://a.example', title: 'т' * 101)]),
        contains('100'),
      );
    });

    test('проект: суммы, описание, даты', () {
      const ok = WorkProject(id: 'p', title: 'П');
      expect(projectProblem(ok), isNull);
      expect(projectProblem(ok.copyWith(hourlyRate: -1)), contains('Ставка'));
      expect(
        projectProblem(ok.copyWith(baseAmount: maxWorkKopecks + 1)),
        contains('Базовая'),
      );
      expect(projectProblem(ok.copyWith(baseAmount: maxWorkKopecks)), isNull);
      expect(
        projectProblem(ok.copyWith(description: 'x' * 10001)),
        contains('Описание'),
      );
      expect(
        projectProblem(ok.copyWith(startDate: '2026-02-30')),
        contains('нет такой даты'),
      );
      expect(
        projectProblem(
          ok.copyWith(startDate: '2026-02-01', completedDate: '2026-01-31'),
        ),
        contains('завершения раньше'),
      );
      // Старые архивные проекты без статуса остаются допустимыми.
      expect(projectProblem(ok.copyWith(archived: true)), isNull);
    });

    test('платёж, распределения, запись времени', () {
      final pay = Payment(id: 'a', paidAt: DateTime.utc(2026), amount: 100);
      expect(paymentProblem(pay), isNull);
      expect(
        paymentProblem(
          Payment(
            id: 'a',
            paidAt: DateTime.utc(2026),
            amount: maxWorkKopecks + 1,
          ),
        ),
        contains('Сумма платежа'),
      );
      expect(
        allocationProblem(
          const Allocation(id: '', paymentId: 'a', projectId: 'p', amount: 0),
        ),
        isNotNull,
      );
      expect(
        allocationsProblem(pay, const [
          Allocation(id: '', paymentId: 'a', projectId: 'p', amount: 100),
        ], const []),
        isNull,
      );
      final entry = TimeEntry(
        id: 'e',
        projectId: 'p',
        startedAt: DateTime.utc(2026),
        endedAt: DateTime.utc(2026, 1, 1, 1),
        billable: true,
        note: 'x' * 2001,
        source: TimeSource.manual,
      );
      expect(timeEntryProblem(entry), contains('Заметка'));
      expect(timeEntryProblem(entry.copyWith(note: null)), isNull);
      // Идущий таймер допустим, пока запись не «ручная».
      expect(
        timeEntryProblem(entry.copyWith(endedAt: null)),
        contains('окончание'),
      );
      expect(
        timeEntryProblem(
          TimeEntry(
            id: 'e',
            projectId: 'p',
            startedAt: DateTime.utc(2026),
            billable: true,
            source: TimeSource.timer,
          ),
        ),
        isNull,
      );
    });
  });
}
