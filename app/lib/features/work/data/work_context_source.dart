import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

/// «Работа» как источник контекста для чата ИИ (агент «Работа»): кто
/// сколько должен, проекты со статусами и остатками, часы и доход в час за
/// период. Расчёты — те же чистые функции, что в интерфейсе и на сервере
/// (общие векторы), никаких округлений денег.
///
/// Фильтр `period` относится к часам и доходу: `month` — текущий месяц по
/// Москве, `week` — текущая неделя, `all` — всё время.
class WorkContextSource extends ContextSource {
  const WorkContextSource();

  @override
  String get id => 'work';

  @override
  String get label => 'Работа';

  @override
  String get description =>
      'Проекты и остатки, кто сколько должен, часы и доход в час';

  @override
  List<ContextFilterField> get filters => const [
    ContextFilterField(
      key: 'period',
      label: 'Период для часов и дохода',
      options: {
        'month': 'Текущий месяц',
        'week': 'Текущая неделя',
        'all': 'Всё время',
      },
    ),
  ];

  @override
  Map<String, Object?> get defaultFilter => const {'period': 'month'};

  @override
  String summary(Map<String, Object?> filter) => switch (filter['period']) {
    'week' => 'часы за неделю',
    'all' => 'часы за всё время',
    _ => 'часы за месяц',
  };

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async {
    final projects = [
      for (final r in await env.readRows('projects')) WorkProject.fromRow(r),
    ];
    final people = {
      for (final r in await env.readRows('people'))
        r['id']! as String: WorkPerson.fromRow(r).name,
    };
    final crs = [
      for (final r in await env.readRows('change_requests'))
        ChangeRequest.fromRow(r),
    ];
    final payments = [
      for (final r in await env.readRows('payments')) Payment.fromRow(r),
    ];
    final allocations = [
      for (final r in await env.readRows('payment_allocations'))
        Allocation.fromRow(r),
    ];
    final entries = [
      for (final r in await env.readRows('time_entries')) TimeEntry.fromRow(r),
    ];
    if (projects.isEmpty) return const [];

    final owed = receivables(projects, crs, allocations);
    final out = <String>[];

    String clientOf(WorkProject p) =>
        people[p.clientId] ?? 'заказчик не указан';

    out.add('- Мне должны всего: ${formatAmount(owed.total)}');
    for (final g in owed.clients) {
      final name = people[g.clientId] ?? 'заказчик не указан';
      final parts = [
        for (final p in g.projects)
          '${projects.firstWhere((x) => x.id == p.id).title} ${formatAmount(p.remaining)}',
      ];
      out.add(
        '- Долг · $name: ${formatAmount(g.remaining)} (${parts.join(', ')})',
      );
    }

    final today = parseDate(moscowDate(env.now))!;
    final (period, caption) = switch (filter['period']) {
      'all' => (null, 'за всё время'),
      'week' => (
        DatePeriod(
          from: formatDate(mondayOf(today)),
          to: formatDate(addDays(mondayOf(today), 6)),
        ),
        'за неделю',
      ),
      _ => (monthPeriod(moscowMonth(env.now)), 'за месяц'),
    };
    final report = income(
      projects: projects,
      changeRequests: crs,
      payments: payments,
      allocations: allocations,
      timeEntries: entries,
      period: period,
    );
    out.add(
      '- Часы $caption: ${formatHours(report.seconds)} · получено '
      '${formatAmount(report.received)} · доход в час по факту '
      '${formatPerHour(report.perHourFact)}, по начисленному '
      '${formatPerHour(report.perHourAccrued)}',
    );

    final visible = [
      for (final p in projects)
        if (!p.archived) p,
    ];
    final sorted = [...visible]
      ..sort((a, b) {
        final ra = projectSummary(a, crs, allocations).remaining;
        final rb = projectSummary(b, crs, allocations).remaining;
        final c = (rb > 0 ? rb : 0).compareTo(ra > 0 ? ra : 0);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    for (final p in sorted) {
      final s = projectSummary(p, crs, allocations);
      final parts = [
        'проект «${p.title}»',
        p.effectiveStatus.label.toLowerCase(),
        clientOf(p),
        'сумма ${formatAmount(s.total)}',
        'получено ${formatAmount(s.received)} (${formatPercentBp(s.paidBp)})',
        if (s.remaining < 0)
          'переплата ${formatAmount(-s.remaining)}'
        else
          'остаток ${formatAmount(s.remaining)}',
        if (p.deadlineDate != null) 'срок ${p.deadlineDate}',
      ];
      out.add('- ${parts.join(' · ')}');
    }
    return out;
  }
}
