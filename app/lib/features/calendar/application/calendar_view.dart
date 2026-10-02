import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderFamily;
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';

/// Вид календаря (02, 5.1.2).
enum CalendarViewMode {
  schedule('Расписание'),
  day('День'),
  threeDays('3 дня'),
  week('Неделя'),
  month('Месяц');

  const CalendarViewMode(this.label);

  final String label;

  /// Сетка времени (День, 3 дня, Неделя).
  bool get isGrid => this == day || this == threeDays || this == week;

  /// Сколько суток охватывает вид сетки.
  int get days => switch (this) {
    day => 1,
    threeDays => 3,
    week => 7,
    _ => 1,
  };
}

/// Ключ локальной настройки: последний выбранный вид.
const String calendarViewSettingKey = 'calendar.view_mode';

/// Выбранный вид и день, вокруг которого он открыт.
@immutable
class CalendarViewState {
  const CalendarViewState({required this.focus, this.mode});

  /// `null` — вид по умолчанию: «Расписание» на телефоне, «Неделя» на
  /// десктопе (docs/04, 1.5).
  final CalendarViewMode? mode;
  final DateTime focus;

  CalendarViewState copyWith({CalendarViewMode? mode, DateTime? focus}) =>
      CalendarViewState(mode: mode ?? this.mode, focus: focus ?? this.focus);
}

/// Управляет видом календаря: переключение вида, «Сегодня», шаг вперёд и
/// назад. Последний вид запоминается на устройстве.
class CalendarViewNotifier extends Notifier<CalendarViewState> {
  @override
  CalendarViewState build() {
    unawaited(_restore());
    return CalendarViewState(focus: ref.read(todayProvider));
  }

  Future<void> _restore() async {
    try {
      final saved = await ref
          .read(localSettingsRepositoryProvider)
          .read(calendarViewSettingKey);
      if (!ref.mounted || saved == null) return;
      for (final m in CalendarViewMode.values) {
        if (m.name == saved && state.mode == null) {
          state = state.copyWith(mode: m);
        }
      }
    } on Object {
      // Настройка вида — удобство: без неё остаётся вид по умолчанию.
    }
  }

  Future<void> setMode(CalendarViewMode mode) async {
    state = state.copyWith(mode: mode);
    try {
      await ref
          .read(localSettingsRepositoryProvider)
          .write(calendarViewSettingKey, mode.name);
    } on Object {
      // Не удалось запомнить — вид всё равно переключён.
    }
  }

  void goToday() => state = state.copyWith(focus: ref.read(todayProvider));

  void goTo(DateTime date) => state = state.copyWith(focus: dateOnly(date));

  /// Шаг вида: [direction] = +1 вперёд, -1 назад.
  void step(int direction, CalendarViewMode effective) {
    final f = state.focus;
    final next = switch (effective) {
      CalendarViewMode.month => addMonthsClamped(
        DateTime.utc(f.year, f.month),
        direction,
      ),
      CalendarViewMode.schedule => addDays(f, 7 * direction),
      _ => addDays(f, effective.days * direction),
    };
    state = state.copyWith(focus: next);
  }
}

final NotifierProvider<CalendarViewNotifier, CalendarViewState>
calendarViewProvider =
    NotifierProvider<CalendarViewNotifier, CalendarViewState>(
      CalendarViewNotifier.new,
    );

/// Даты, для которых строятся элементы: `[from, to)`.
@immutable
class DateSpan {
  const DateSpan(this.from, this.to);

  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) =>
      other is DateSpan && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// Дни, видимые в виде [mode] при фокусе [focus].
DateSpan spanOf(CalendarViewMode mode, DateTime focus) {
  switch (mode) {
    case CalendarViewMode.schedule:
      return DateSpan(focus, addDays(focus, 60));
    case CalendarViewMode.day:
      return DateSpan(focus, addDays(focus, 1));
    case CalendarViewMode.threeDays:
      return DateSpan(focus, addDays(focus, 3));
    case CalendarViewMode.week:
      final monday = mondayOf(focus);
      return DateSpan(monday, addDays(monday, 7));
    case CalendarViewMode.month:
      final first = mondayOf(DateTime.utc(focus.year, focus.month));
      return DateSpan(first, addDays(first, 42));
  }
}

/// Данные календаря (слои, события, переопределения, задачи, отметки).
final Provider<AsyncValue<CalendarData>> calendarDataProvider =
    Provider<AsyncValue<CalendarData>>((ref) {
      final layers = ref.watch(calendarLayersProvider);
      final events = ref.watch(eventsProvider);
      final overrides = ref.watch(eventOverridesProvider);
      final tasks = ref.watch(tasksProvider);
      final completions = ref.watch(taskCompletionsProvider);
      final all = <AsyncValue<Object?>>[
        layers,
        events,
        overrides,
        tasks,
        completions,
      ];
      for (final v in all) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (all.any((v) => !v.hasValue)) return const AsyncValue.loading();
      return AsyncValue.data(
        CalendarData(
          layers: layers.requireValue,
          events: events.requireValue,
          overrides: overrides.requireValue,
          tasks: tasks.requireValue,
          completions: completions.requireValue,
        ),
      );
    });

/// Элементы календаря на отрезке `span` в поясе устройства.
final ProviderFamily<AsyncValue<List<CalendarItem>>, DateSpan>
calendarItemsProvider =
    Provider.family<AsyncValue<List<CalendarItem>>, DateSpan>((ref, span) {
      final data = ref.watch(calendarDataProvider);
      final zone = ref.watch(deviceTimeZoneProvider);
      return data.whenData(
        (d) => buildCalendarItems(
          d,
          fromDate: span.from,
          toDate: span.to,
          zone: zone,
        ),
      );
    });
