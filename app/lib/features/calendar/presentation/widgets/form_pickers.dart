import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';

/// Выбор даты рядом с чипами (02, 4.4): «Сегодня · Завтра · Пн · Выбрать».
/// Выбранная другая дата показывается отдельным выбранным чипом.
class DateChoiceRow extends StatelessWidget {
  const DateChoiceRow({
    required this.today,
    required this.value,
    required this.onChanged,
    this.allowNone = false,
    this.noneLabel = 'Нет',
    this.keyPrefix = 'date',
    super.key,
  });

  final DateTime today;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool allowNone;
  final String noneLabel;

  /// Префикс ключей чипов (`date-today`, `date-pick`…).
  final String keyPrefix;

  DateTime get _nextMonday {
    final monday = mondayOf(today);
    return addDays(monday, 7);
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: value ?? today,
      firstDate: DateTime(minYear),
      lastDate: DateTime(maxYear),
      locale: const Locale('ru'),
    );
    if (picked != null) onChanged(civil(picked.year, picked.month, picked.day));
  }

  @override
  Widget build(BuildContext context) {
    final tomorrow = addDays(today, 1);
    final monday = _nextMonday;
    final quick = <DateTime>{today, tomorrow, monday};
    final v = value == null ? null : dateOnly(value!);
    return ChipRow(
      children: [
        if (allowNone)
          FilterPill(
            key: Key('$keyPrefix-none'),
            label: noneLabel,
            selected: v == null,
            onTap: () => onChanged(null),
          ),
        FilterPill(
          key: Key('$keyPrefix-today'),
          label: 'Сегодня',
          selected: v == today,
          onTap: () => onChanged(today),
        ),
        FilterPill(
          key: Key('$keyPrefix-tomorrow'),
          label: 'Завтра',
          selected: v == tomorrow,
          onTap: () => onChanged(tomorrow),
        ),
        FilterPill(
          key: Key('$keyPrefix-monday'),
          label: 'Пн, ${monday.day} ${monthShortNames[monday.month - 1]}',
          selected: v == monday,
          onTap: () => onChanged(monday),
        ),
        FilterPill(
          key: Key('$keyPrefix-pick'),
          label: v != null && !quick.contains(v) ? dayTitleShort(v) : 'Выбрать',
          selected: v != null && !quick.contains(v),
          icon: LucideIcons.calendar,
          onTap: () => _pick(context),
        ),
      ],
    );
  }
}

/// Выбор времени: «Без времени · 09:00 · 12:00 · 15:00 · 18:00 · Другое».
class TimeChoiceRow extends StatelessWidget {
  const TimeChoiceRow({
    required this.value,
    required this.onChanged,
    this.allowNone = true,
    this.keyPrefix = 'time',
    super.key,
  });

  final TimeOfDay? value;
  final ValueChanged<TimeOfDay?> onChanged;
  final bool allowNone;
  final String keyPrefix;

  static const List<(int, int)> quick = [(9, 0), (12, 0), (15, 0), (18, 0)];

  Future<void> _pick(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: value ?? const TimeOfDay(hour: 9, minute: 0),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final v = value;
    final isQuick = v != null && quick.contains((v.hour, v.minute));
    return ChipRow(
      children: [
        if (allowNone)
          FilterPill(
            key: Key('$keyPrefix-none'),
            label: 'Без времени',
            selected: v == null,
            onTap: () => onChanged(null),
          ),
        for (final (h, m) in quick)
          FilterPill(
            key: Key('$keyPrefix-${clockText(h, m).replaceAll(':', '')}'),
            label: clockText(h, m),
            selected: v != null && v.hour == h && v.minute == m,
            onTap: () => onChanged(TimeOfDay(hour: h, minute: m)),
          ),
        FilterPill(
          key: Key('$keyPrefix-pick'),
          label: v != null && !isQuick ? clockText(v.hour, v.minute) : 'Другое',
          selected: v != null && !isQuick,
          icon: LucideIcons.clock,
          onTap: () => _pick(context),
        ),
      ],
    );
  }
}

/// Напоминания: чипы «в момент / за 10 минут / за сутки» (spec 2.4). Не
/// больше пяти; нетиповые значения показываются выбранными чипами.
class RemindersField extends StatelessWidget {
  const RemindersField({
    required this.value,
    required this.allDay,
    required this.onChanged,
    super.key,
  });

  final List<int> value;

  /// Для «весь день»/срока без времени опорный момент — 9:00 этого дня.
  final bool allDay;
  final ValueChanged<List<int>> onChanged;

  static const List<(int, String)> timedOptions = [
    (0, 'В момент'),
    (5, 'За 5 мин'),
    (10, 'За 10 мин'),
    (30, 'За 30 мин'),
    (60, 'За 1 час'),
    (1440, 'За 1 день'),
  ];

  static const List<(int, String)> allDayOptions = [
    (0, 'В 9:00 в этот день'),
    (900, 'Накануне в 18:00'),
    (1440, 'Накануне в 9:00'),
    (2880, 'За 2 дня в 9:00'),
  ];

  /// Подпись значения «минут до».
  static String label(int minutes, {required bool allDay}) {
    final options = allDay ? allDayOptions : timedOptions;
    for (final (m, text) in options) {
      if (m == minutes) return text;
    }
    if (minutes % 1440 == 0) return 'За ${minutes ~/ 1440} дн.';
    if (minutes % 60 == 0) return 'За ${minutes ~/ 60} ч';
    return 'За $minutes мин';
  }

  @override
  Widget build(BuildContext context) {
    final options = allDay ? allDayOptions : timedOptions;
    final known = {for (final (m, _) in options) m};
    void toggle(int minutes) {
      final next = [...value];
      if (!next.remove(minutes)) {
        if (next.length >= 5) return;
        next.add(minutes);
      }
      next.sort();
      onChanged(next);
    }

    return Wrap(
      spacing: AppSpacing.s2,
      runSpacing: AppSpacing.s2,
      children: [
        for (final (m, text) in options)
          FilterPill(
            key: Key('reminder-$m'),
            label: text,
            selected: value.contains(m),
            check: true,
            onTap: () => toggle(m),
          ),
        for (final m in value.where((m) => !known.contains(m)))
          FilterPill(
            key: Key('reminder-$m'),
            label: label(m, allDay: allDay),
            selected: true,
            check: true,
            onTap: () => toggle(m),
          ),
      ],
    );
  }
}

/// Строка «поле-кнопка»: иконка, значение и шеврон (выбор из списка).
class PickerTile extends StatelessWidget {
  const PickerTile({
    required this.icon,
    required this.text,
    required this.onTap,
    this.hint = false,
    super.key,
  });

  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  /// Текст-подсказка (значение не выбрано).
  final bool hint;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: c.textSecondary),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.body.copyWith(
                  color: hint ? c.textTertiary : c.textPrimary,
                ),
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Степпер числа: «− 2 +».
class NumberStepper extends StatelessWidget {
  const NumberStepper({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.keyPrefix = 'stepper',
    super.key,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('$keyPrefix-minus'),
            tooltip: 'Меньше',
            onPressed: value > min ? () => onChanged(value - 1) : null,
            icon: const Icon(LucideIcons.minus, size: 18),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              key: Key('$keyPrefix-value'),
              style: context.text.numL,
            ),
          ),
          IconButton(
            key: Key('$keyPrefix-plus'),
            tooltip: 'Больше',
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(LucideIcons.plus, size: 18),
          ),
        ],
      ),
    );
  }
}
