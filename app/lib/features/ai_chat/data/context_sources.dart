import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/finance/data/finance_context_source.dart';
import 'package:my_tasker/features/study/data/study_context_source.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/work/data/work_context_source.dart';
import 'package:timezone/timezone.dart' as tz;

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime wall) => '${_two(wall.hour)}:${_two(wall.minute)}';

/// Задачи (Этап 2) как источник контекста.
///
/// Фильтр `range`: `week` — открытые задачи со сроком до +7 дней и
/// просроченные; `month` — то же на 30 дней; `open` — все открытые;
/// `no_date` — открытые без срока.
class TasksContextSource extends ContextSource {
  const TasksContextSource();

  @override
  String get id => 'tasks';

  @override
  String get label => 'Задачи';

  @override
  String get description => 'Открытые задачи: срок, приоритет, проект';

  @override
  List<ContextFilterField> get filters => const [
    ContextFilterField(
      key: 'range',
      label: 'Какие задачи',
      options: {
        'week': 'На 7 дней и просроченные',
        'month': 'На 30 дней и просроченные',
        'open': 'Все открытые',
        'no_date': 'Без срока',
      },
    ),
  ];

  @override
  Map<String, Object?> get defaultFilter => const {'range': 'week'};

  @override
  String summary(Map<String, Object?> filter) => switch (filter['range']) {
    'month' => 'на 30 дней и просроченные',
    'open' => 'все открытые',
    'no_date' => 'без срока',
    _ => 'на 7 дней и просроченные',
  };

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async {
    final today = dateOnly(utcToWall(env.zone, env.now));
    final range = '${filter['range'] ?? 'week'}';
    final horizon = switch (range) {
      'month' => addDays(today, 30),
      'week' => addDays(today, 7),
      _ => null,
    };
    final projects = {
      for (final p in await env.readRows('projects'))
        p['id']! as String: Project.fromRow(p).title,
    };
    final tasks =
        [for (final row in await env.readRows('tasks')) TaskEntity.fromRow(row)]
            .where((t) => t.isOpen && t.archivedAt == null)
            .where((t) {
              final due = t.due.localDate;
              return switch (range) {
                'no_date' => due == null,
                'open' => true,
                _ => due != null && due.isBefore(horizon!),
              };
            })
            .toList()
          ..sort((a, b) {
            final da = a.due.localDate;
            final db = b.due.localDate;
            if (da != db) {
              if (da == null) return 1;
              if (db == null) return -1;
              return da.compareTo(db);
            }
            final pa = a.priority ?? 6;
            final pb = b.priority ?? 6;
            return pa != pb ? pa.compareTo(pb) : a.title.compareTo(b.title);
          });

    return [
      for (final t in tasks) _line(t, today, env.zone, projects[t.projectId]),
    ];
  }

  String _line(
    TaskEntity t,
    DateTime today,
    tz.Location zone,
    String? project,
  ) {
    final parts = <String>[t.title];
    final date = t.due.localDate;
    if (date != null) {
      var due = 'срок ${formatDate(date)}';
      if (t.due.hasTime) {
        due += ' ${_clock(utcToWall(zone, t.due.at!))}';
      }
      if (date.isBefore(today)) due += ' (просрочено)';
      parts.add(due);
    }
    if (t.priority != null) parts.add('P${t.priority}');
    parts.add(t.status.label.toLowerCase());
    if (project != null) parts.add('проект «$project»');
    if (t.isRecurring) parts.add('повторяется');
    return '- ${parts.join(' · ')}';
  }
}

/// События календаря (Этап 2): расписание на ближайшие дни с учётом
/// повторений, отмен и переопределений.
///
/// Фильтр `days`: 1, 7, 14 или 30 дней вперёд, считая с сегодняшнего.
class EventsContextSource extends ContextSource {
  const EventsContextSource();

  @override
  String get id => 'events';

  @override
  String get label => 'Расписание';

  @override
  String get description => 'События календаря на ближайшие дни';

  @override
  List<ContextFilterField> get filters => const [
    ContextFilterField(
      key: 'days',
      label: 'Период',
      options: {
        '1': 'Сегодня',
        '7': '7 дней',
        '14': '14 дней',
        '30': '30 дней',
      },
    ),
  ];

  @override
  Map<String, Object?> get defaultFilter => const {'days': '7'};

  @override
  String summary(Map<String, Object?> filter) {
    final days = _days(filter);
    return days == 1 ? 'сегодня' : 'на $days дн.';
  }

  int _days(Map<String, Object?> filter) {
    final days = int.tryParse('${filter['days']}') ?? 7;
    return days.clamp(1, 62);
  }

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async {
    final today = dateOnly(utcToWall(env.zone, env.now));
    final data = CalendarData(
      layers: [
        for (final r in await env.readRows('calendars'))
          CalendarLayer.fromRow(r),
      ],
      events: [
        for (final r in await env.readRows('events')) EventEntity.fromRow(r),
      ],
      overrides: [
        for (final r in await env.readRows('event_overrides'))
          EventOverride.fromRow(r),
      ],
    );
    final items = buildCalendarItems(
      data,
      fromDate: today,
      toDate: addDays(today, _days(filter)),
      zone: env.zone,
    ).whereType<EventItem>();
    return [
      for (final e in items)
        if (e.allDay)
          '- ${formatDate(e.start)} весь день · ${e.title}${_where(e)}'
        else
          _timedLine(e),
    ];
  }

  String _timedLine(EventItem e) {
    final time = '${_clock(e.start)}–${_clock(e.end)}';
    return '- ${formatDate(e.start)} $time · ${e.title}${_where(e)}';
  }

  String _where(EventItem e) {
    final parts = [
      if (e.layerName != null) e.layerName!,
      if (e.location != null && e.location!.isNotEmpty) e.location!,
    ];
    return parts.isEmpty ? '' : ' (${parts.join(', ')})';
  }
}

/// Реестр источников контекста. Этапы 4–8 дописывают свои источники сюда
/// (Работа — Этап 4, финансы — Этап 5; учёба, сон — позже) — чат, конструктор и превью работают с
/// ними без изменений.
final contextSourcesProvider = Provider<List<ContextSource>>(
  (ref) => const [
    TasksContextSource(),
    EventsContextSource(),
    WorkContextSource(),
    FinanceContextSource(),
    StudyContextSource(),
  ],
);

/// Окружение сборки контекста на текущий момент (каждый вызов — свежее).
final contextEnvProvider = Provider<ContextEnv Function()>((ref) {
  final store = ref.watch(syncStoreProvider);
  return () => ContextEnv(
    now: ref.read(clockProvider)().toUtc(),
    zone: ref.read(deviceTimeZoneProvider),
    readRows: store.visibleRows,
  );
});

final contextBuilderProvider = Provider<ContextBuilder>(
  (ref) => ContextBuilder(ref.watch(contextSourcesProvider)),
);
