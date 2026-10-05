import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';
import 'package:my_tasker/features/sleep/domain/sleep_format.dart';
import 'package:my_tasker/features/sleep/domain/sleep_habits.dart';
import 'package:my_tasker/features/sleep/domain/sleep_ids.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/sleep/domain/sleep_tasks.dart';
import 'package:my_tasker/features/sleep/domain/sleep_validation.dart';

const _a = '01900000-0000-7000-8000-00000000000a';
const _b = '01900000-0000-7000-8000-00000000000b';

SleepEntry _entry({
  String date = '2026-10-05',
  DateTime? bed,
  DateTime? wake,
  String wakeTz = 'Europe/Moscow',
  String? bedTz,
  int? quality,
  String? note,
}) => SleepEntry(
  id: sleepEntryId(date),
  date: date,
  bedAt: bed ?? DateTime.utc(2026, 10, 4, 20, 40),
  wakeAt: wake ?? DateTime.utc(2026, 10, 5, 4, 10),
  wakeTz: wakeTz,
  bedTz: bedTz,
  quality: quality,
  note: note,
);

void main() {
  ensureTimeZones();

  group('идентификаторы', () {
    test('детерминированы: одна дата — один id, разные таблицы — разные', () {
      expect(sleepEntryId('2026-10-05'), sleepEntryId('2026-10-05'));
      expect(sleepEntryId('2026-10-05'), isNot(sleepEntryId('2026-10-06')));
      expect(sleepEntryId('2026-10-05'), isNot(dailyPlanId('2026-10-05')));
      expect(dailyPlanId('2026-10-05'), isNot(eveningCheckinId('2026-10-05')));
      // Формула сервера: uuid5(ns(table), date) — значение зафиксировано.
      expect(sleepEntryId('2026-10-05'), hasLength(36));
    });
  });

  group('модели', () {
    test('SleepEntry: чтение строки, строка расчётов и вид', () {
      final e = SleepEntry.fromRow(const {
        'id': 'x',
        'date': '2026-10-05',
        'bed_at': '2026-10-04T20:40:00Z',
        'wake_at': '2026-10-05T04:10:00Z',
        'bed_tz': null,
        'wake_tz': 'Europe/Moscow',
        'source': 'morning_notification',
        'quality': 4,
        'note': 'н',
      });
      expect(e.source, SleepSource.morningNotification);
      expect(e.view!.minutes, 450);
      expect(e.view!.bedLocal, '23:40');
      expect(e.toRow()['bed_at'], '2026-10-04T20:40:00Z');
      expect(e.toFields()['source'], 'morning_notification');
      expect(e.toFields().containsKey('date'), isFalse);
      final c = e.copyWith(quality: null, note: 'другая');
      expect(c.quality, isNull);
      expect(c.note, 'другая');
      expect(e.copyWith(source: SleepSource.manual).source, SleepSource.manual);
    });

    test('мягкое чтение: неизвестный источник и битый момент', () {
      final e = SleepEntry.fromRow(const {
        'source': 'health_connect',
        'bed_at': 'мусор',
      });
      expect(e.source, SleepSource.manual);
      expect(e.view, isNull);
      expect(SleepSource.parse(null), SleepSource.manual);
    });

    test('DailyPlan и EveningCheckin: чтение и колонки', () {
      final p = DailyPlan.fromRow(const {
        'id': 'p',
        'date': '2026-10-05',
        'task_ids': [_a, 3, _b],
        'main_task_id': _b,
        'note': null,
      });
      expect(p.taskIds, [_a, _b]);
      expect(p.toFields(), {
        'task_ids': [_a, _b],
        'main_task_id': _b,
        'note': null,
      });
      final c = EveningCheckin.fromRow(const {
        'id': 'c',
        'date': '2026-10-05',
        'rating': 4,
        'done_task_ids': [_a],
        'carry_over': [
          {'task_id': _a, 'to': 'tomorrow'},
          {'task_id': _b, 'to': 'date', 'date': '2026-10-09'},
          {'task_id': _b, 'to': 'later'},
          'мусор',
        ],
        'note': 'ок',
      });
      expect(c.carryOver, hasLength(2));
      expect(c.toFields()['carry_over'], [
        {'task_id': _a, 'to': 'tomorrow'},
        {'task_id': _b, 'to': 'date', 'date': '2026-10-09'},
      ]);
      expect(EveningCheckin.fromRow(const {}).carryOver, isEmpty);
      expect(DailyPlan.fromRow(const {}).taskIds, isEmpty);
    });

    test('CarryDecision: равенство и разбор', () {
      expect(
        const CarryDecision.tomorrow('a'),
        const CarryDecision.tomorrow('a'),
      );
      expect(
        const CarryDecision.onDate('a', '2026-10-09').hashCode,
        const CarryDecision.onDate('a', '2026-10-09').hashCode,
      );
      expect(const CarryDecision.tomorrow('a').isTomorrow, isTrue);
      expect(CarryDecision.tryParse(null), isNull);
      expect(CarryDecision.tryParse({'to': 'tomorrow'}), isNull);
      expect(CarryDecision.tryParse({'task_id': 'a', 'to': 'date'}), isNull);
    });
  });

  group('проверки', () {
    test('сон: допустимый и каждая проблема', () {
      expect(sleepProblem(_entry()), isNull);
      expect(sleepProblem(_entry(date: '2026-02-30')), contains('Дата'));
      expect(sleepProblem(_entry(wakeTz: 'Mars/Base')), contains('пояс'));
      expect(sleepProblem(_entry(bedTz: 'Mars/Base')), contains('пояс'));
      expect(
        sleepProblem(_entry(wake: DateTime.utc(2026, 10, 4, 20, 40))),
        contains('позже'),
      );
      expect(
        sleepProblem(_entry(wake: DateTime.utc(2026, 10, 5, 20, 41))),
        contains('24'),
      );
      expect(sleepProblem(_entry(quality: 6)), contains('Самочувствие'));
      expect(
        sleepProblem(_entry(date: '2026-10-06')),
        contains('день пробуждения'),
      );
      expect(sleepProblem(_entry(note: 'я' * 2001)), contains('Заметка'));
      expect(sleepProblem(_entry(bedTz: 'Asia/Vladivostok')), isNull);
    });

    test('сон: не дальше суток вперёд от часов', () {
      final now = DateTime.utc(2026, 10, 5, 9);
      expect(sleepTimeProblem(_entry(), now), isNull);
      expect(
        sleepTimeProblem(_entry(wake: DateTime.utc(2026, 10, 6, 10)), now),
        contains('будущем'),
      );
    });

    test('план и чек-ин', () {
      expect(
        planProblem(
          const DailyPlan(id: 'p', date: '2026-10-05', taskIds: [_a]),
        ),
        isNull,
      );
      expect(
        planProblem(const DailyPlan(id: 'p', date: '2026-13-01')),
        isNotNull,
      );
      expect(
        planProblem(
          const DailyPlan(id: 'p', date: '2026-10-05', taskIds: [_a, _a]),
        ),
        contains('повторяется'),
      );
      expect(
        planProblem(
          const DailyPlan(id: 'p', date: '2026-10-05', taskIds: ['не-uuid']),
        ),
        contains('идентификатор'),
      );
      expect(
        planProblem(
          DailyPlan(
            id: 'p',
            date: '2026-10-05',
            taskIds: [
              for (var i = 0; i < 11; i++)
                '01900000-0000-7000-8000-0000000000${i.toString().padLeft(2, '0')}',
            ],
          ),
        ),
        contains('не больше 10'),
      );
      expect(
        planProblem(
          const DailyPlan(id: 'p', date: '2026-10-05', mainTaskId: 'x'),
        ),
        contains('Главное'),
      );
      expect(
        planProblem(DailyPlan(id: 'p', date: '2026-10-05', note: 'я' * 2001)),
        contains('Заметка'),
      );

      EveningCheckin c({
        int? rating,
        List<CarryDecision> carry = const [],
        List<String> done = const [],
        String date = '2026-10-05',
      }) => EveningCheckin(
        id: 'c',
        date: date,
        rating: rating,
        doneTaskIds: done,
        carryOver: carry,
      );
      expect(checkinProblem(c(rating: 5)), isNull);
      expect(checkinProblem(c(rating: 0)), contains('Оценка'));
      expect(checkinProblem(c(date: 'x')), contains('Дата'));
      expect(checkinProblem(c(done: [_a, _a])), contains('повторяется'));
      expect(
        checkinProblem(
          c(
            carry: [
              const CarryDecision.tomorrow(_a),
              const CarryDecision.tomorrow(_a),
            ],
          ),
        ),
        contains('повторяется'),
      );
      expect(
        checkinProblem(c(carry: [const CarryDecision.tomorrow('нет')])),
        contains('идентификатор'),
      );
      expect(
        checkinProblem(
          c(carry: [const CarryDecision.onDate(_a, '2026-02-30')]),
        ),
        contains('нет такой даты'),
      );
      expect(
        checkinProblem(
          c(carry: [const CarryDecision.onDate(_a, '2026-10-09')]),
        ),
        isNull,
      );
      expect(
        checkinProblem(
          c(
            carry: [
              for (var i = 0; i < 51; i++)
                CarryDecision.tomorrow(
                  '01900000-0000-7000-8000-0000000001${i.toString().padLeft(2, '0')}',
                ),
            ],
          ),
        ),
        contains('не больше 50'),
      );
    });
  });

  group('форматы', () {
    test('длительность, доли, разница, уровни тепловой карты', () {
      expect(durationShort(452), '7:32');
      expect(durationShort(60), '1:00');
      expect(sharePercent(6666), '66 %');
      expect(differencePoints(2500), '+25 п. п.');
      expect(differencePoints(-1000), '−10 п. п.');
      expect(differencePoints(50), '0 п. п.');
      expect(heatLevel(60), 1);
      expect(heatLevel(150), 2);
      expect(heatLevel(300), 3);
      expect(heatLevel(420), 4);
      expect(heatLevel(600), 4);
    });

    test('окно дат и подписи', () {
      expect(windowDates('2026-03-02', 3), [
        '2026-02-28',
        '2026-03-01',
        '2026-03-02',
      ]);
      expect(dateShort('2026-10-05'), 'Пн, 5 окт.');
      expect(dateShort('мусор'), 'мусор');
      expect(dateLong('2026-10-05'), '5 октября');
      expect(dateLong('мусор'), 'мусор');
      expect(clockOfMinutes(425), '07:05');
    });

    test('разбор времени из текста', () {
      expect(parseClockInput('23:40'), 23 * 60 + 40);
      expect(parseClockInput('8:05'), 8 * 60 + 5);
      expect(parseClockInput('8.05'), 8 * 60 + 5);
      expect(parseClockInput('0740'), 7 * 60 + 40);
      expect(parseClockInput('740'), 7 * 60 + 40);
      expect(parseClockInput('8'), 480);
      expect(parseClockInput(' 23:59 '), 23 * 60 + 59);
      expect(parseClockInput('24:00'), isNull);
      expect(parseClockInput('7:60'), isNull);
      expect(parseClockInput('abc'), isNull);
      expect(parseClockInput(''), isNull);
    });
  });

  group('привычный режим', () {
    test('без записей — 23:30 → 07:30', () {
      expect(usualTimes(const []), defaultUsualTimes);
      expect(bedSpread(const []), isNull);
    });

    test('медианы по ночам; отбой после полуночи не ломает медиану', () {
      final e = [
        _entry(),
        _entry(
          date: '2026-10-04',
          bed: DateTime.utc(2026, 10, 3, 21, 10),
          wake: DateTime.utc(2026, 10, 4, 4, 30),
        ),
        _entry(
          date: '2026-10-03',
          bed: DateTime.utc(2026, 10, 2, 21),
          wake: DateTime.utc(2026, 10, 3, 4),
        ),
      ];
      // Отбой 23:40, 00:10, 00:00 (по Москве) -> медиана 00:00.
      final u = usualTimes(e);
      expect(clockOfMinutes(u.bed), '00:00');
      expect(clockOfMinutes(u.wake), '07:10');
      expect(bedSpread(e), 20);
      expect(bedSpread([e.first]), isNull);
    });

    test('невалидная запись пропускается', () {
      final bad = SleepEntry.fromRow(const {'date': '2026-10-05'});
      expect(usualTimes([bad]), defaultUsualTimes);
      expect(bedSpread([bad, bad]), isNull);
    });
  });

  group('расчёты: дополнительные случаи', () {
    test('невалидные входы', () {
      expect(durationMinutes('x', '2026-10-05T04:10:00Z'), isNull);
      expect(entryView({'bed_at': 1}), isNull);
      expect(
        entryView({
          'bed_at': '2026-10-04T20:40:00Z',
          'wake_at': '2026-10-05T04:10:00Z',
          'wake_tz': 'Mars/Base',
        }),
        isNull,
      );
      expect(localMoment('x', 'UTC'), isNull);
      expect(sleepDate('2026-10-05T04:10:00Z', 'Mars/Base'), isNull);
      expect(() => window('мусор', 7), throwsArgumentError);
      expect(() => window('2026-10-05', 0), throwsArgumentError);
      expect(() => streak(const [], 'x'), throwsArgumentError);
      expect(() => planCarryOver('x', const [], const []), throwsArgumentError);
    });

    test('taskDay: свой часовой пояс и мусор', () {
      expect(
        taskDay({'due_at': '2026-10-05T22:00:00Z', 'due_tz': 'Europe/Moscow'}),
        '2026-10-06',
      );
      expect(taskDay({'due_at': 'x', 'due_tz': 'Europe/Moscow'}), isNull);
      expect(taskDay({}), isNull);
    });

    test('CarryChange: JSON всех видов', () {
      expect(const CarryChange.skip('a', 'closed').toJson(), {
        'task_id': 'a',
        'action': 'skip',
        'reason': 'closed',
      });
      expect(const CarryChange.skip('a', 'closed').isSkip, isTrue);
      expect(
        const CarryChange.dueDate('a', '2026-10-06', 'todo').toJson()['status'],
        'todo',
      );
      expect(
        const CarryChange.dueAt(
          'a',
          '2026-10-06T07:00:00Z',
          'UTC',
          null,
        ).toJson()['due_tz'],
        'UTC',
      );
    });

    test('taskLinkRow: строгий момент, неизвестная зона -> UTC', () {
      final r = taskLinkRow({
        'id': 'a',
        'status': 'todo',
        'due_date': null,
        'due_at': '2026-10-05T07:00:00.000Z',
        'due_tz': 'Mars/Base',
        'rrule': null,
        'title': 'лишнее',
      });
      expect(r['due_at'], '2026-10-05T07:00:00Z');
      expect(r['due_tz'], 'UTC');
      expect(r.containsKey('title'), isFalse);
      expect(taskLinkRow({'id': 'b'})['due_tz'], isNull);
    });
  });
}
