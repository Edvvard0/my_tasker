import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart' show durationText;
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';
import 'package:my_tasker/features/sleep/domain/sleep_format.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/sleep/domain/sleep_tasks.dart';

/// «Сон» как источник контекста для чата ИИ (агент «Сон»): средний сон за 7
/// и 30 дней, ночи периода, связь сна с выполненными задачами, серии
/// ритуалов, утренние планы и вечерние чек-ины периода. Расчёты — те же
/// чистые функции, что в интерфейсе и на сервере (общие векторы).
///
/// Источник **не** помечен [sensitive]: контракт Этапа 8 не объявляет
/// инструменты «Сна» чувствительными (`sensitive_tools_consent` нужен только
/// «Финансам»), так что облачный чат с ним разрешён; пользователь может
/// сделать свой пресет «не в облако» сам.
///
/// Фильтр `period`: `week` — 7 дней, `month` — 30 дней.
class SleepContextSource extends ContextSource {
  const SleepContextSource();

  @override
  String get id => 'sleep';

  @override
  String get label => 'Сон';

  @override
  String get description =>
      'Ночи сна, средние, связь с задачами, утренние планы и вечерние чек-ины';

  @override
  List<ContextFilterField> get filters => const [
    ContextFilterField(
      key: 'period',
      label: 'Период записей',
      options: {'week': '7 дней', 'month': '30 дней'},
    ),
  ];

  @override
  Map<String, Object?> get defaultFilter => const {'period': 'week'};

  @override
  String summary(Map<String, Object?> filter) => switch (filter['period']) {
    'month' => 'сон и ритуалы за 30 дней',
    _ => 'сон и ритуалы за 7 дней',
  };

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async {
    final entries = [
      for (final r in await env.readRows('sleep_entries'))
        SleepEntry.fromRow(r),
    ];
    final plans = [
      for (final r in await env.readRows('daily_plans')) DailyPlan.fromRow(r),
    ];
    final checkins = [
      for (final r in await env.readRows('evening_checkins'))
        EveningCheckin.fromRow(r),
    ];
    if (entries.isEmpty && plans.isEmpty && checkins.isEmpty) return const [];
    final taskRows = await env.readRows('tasks');
    final titles = {
      for (final r in taskRows) r['id']! as String: '${r['title']}',
    };
    final through = formatDate(dateOnly(utcToWall(env.zone, env.now)));
    final days = filter['period'] == 'month' ? 30 : 7;
    final from = windowDates(through, days).first;
    final rows = [for (final e in entries) e.toRow()];
    final out = <String>[];

    // Средние и связь с задачами.
    for (final n in const [7, 30]) {
      final a = averageSleep(rows, through, n);
      final avg = a.averageMinutes;
      out.add(
        avg == null
            ? '- Средний сон за $n дн.: данных нет'
            : '- Средний сон за $n дн.: ${durationText(avg)} '
                  '(ночей с записью: ${a.daysWithData} из $n)',
      );
    }
    final link = sleepTaskLink(rows, [
      for (final r in taskRows) taskLinkRow(r),
    ], through);
    if (link.short.days + link.normal.days > 0) {
      String group(String name, LinkGroup g) => g.shareBp == null
          ? '$name: нет задач'
          : '$name: закрыто ${sharePercent(g.shareBp!)} задач '
                '(${g.done} из ${g.tasks}, дней ${g.days})';
      out.add(
        '- Сон и задачи за 7 дней (сравнение долей, не причина): '
        '${group('после короткого сна (< 6 ч)', link.short)}; '
        '${group('после нормального', link.normal)}'
        '${link.enoughData ? '' : ' · мало данных'}',
      );
    }

    // Серии ритуалов.
    final s = ritualStreaks(
      [for (final p in plans) p.date],
      [for (final c in checkins) c.date],
      through,
    );
    String streakText(String name, Streak v) =>
        '$name ${v.current} дн. подряд (лучшая ${v.best})';
    out.add(
      '- Серии ритуалов: ${streakText('утренний план', s.morning)}; '
      '${streakText('вечерний чек-ин', s.evening)}; '
      '${streakText('оба', s.both)}',
    );

    // Ночи периода (новые первыми).
    final nights = [
      for (final e in entries)
        if (e.view != null && e.date.compareTo(from) >= 0) e,
    ]..sort((a, b) => b.date.compareTo(a.date));
    for (final e in nights) {
      final v = e.view!;
      final note = (e.note ?? '').trim();
      out.add(
        '- Сон ${e.date}: ${v.bedLocal} → ${v.wakeLocal} · '
        '${durationText(v.minutes)}'
        '${e.quality == null ? '' : ' · самочувствие ${e.quality}/5'}'
        '${note.isEmpty ? '' : ' · заметка: ${_cut(note, 200)}'}',
      );
    }

    // Утренние планы и вечерние чек-ины периода.
    final dates =
        {for (final p in plans) p.date, for (final c in checkins) c.date}
            .where((d) => d.compareTo(from) >= 0 && d.compareTo(through) <= 0)
            .toList()
          ..sort((a, b) => b.compareTo(a));
    for (final date in dates) {
      final plan = plans.where((p) => p.date == date).firstOrNull;
      final checkin = checkins.where((c) => c.date == date).firstOrNull;
      if (plan != null) {
        final main = plan.mainTaskId == null
            ? null
            : (titles[plan.mainTaskId] ?? 'задача удалена');
        final note = (plan.note ?? '').trim();
        out.add(
          '- Утренний план $date: дел ${plan.taskIds.length}'
          '${main == null ? '' : ' · главное: «${_cut(main, 100)}»'}'
          '${note.isEmpty ? '' : ' · заметка: ${_cut(note, 200)}'}',
        );
      }
      if (checkin != null) {
        final note = (checkin.note ?? '').trim();
        out.add(
          '- Вечерний чек-ин $date: '
          '${checkin.rating == null ? 'без оценки' : 'оценка дня ${checkin.rating}/5'}'
          ' · сделано ${checkin.doneTaskIds.length}'
          ' · перенесено ${checkin.carryOver.length}'
          '${note.isEmpty ? '' : ' · заметка: ${_cut(note, 200)}'}',
        );
      }
    }
    return out;
  }

  static String _cut(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';
}
