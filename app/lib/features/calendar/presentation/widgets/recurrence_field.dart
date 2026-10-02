import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/features/calendar/domain/recurrence_draft.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';

/// Редактор повторения (spec 5.1, 6): частота, интервал, дни недели,
/// «чёт/нечёт» по настройке цикла недель, способ выбора дня в месяце и
/// окончание. Меняет только черновик; правило и начало серии строит
/// вызывающий (`RecurrenceDraft.toRule`, `firstMatchingDate`).
class RecurrenceField extends StatelessWidget {
  const RecurrenceField({
    required this.draft,
    required this.start,
    required this.onChanged,
    this.cycle,
    this.onOpenCycleSettings,
    super.key,
  });

  final RecurrenceDraft draft;

  /// Дата первого экземпляра (для дней недели и числа по умолчанию).
  final DateTime start;
  final WeekCycle? cycle;
  final ValueChanged<RecurrenceDraft> onChanged;

  /// «Настроить цикл недель» (если цикл выключен).
  final VoidCallback? onOpenCycleSettings;

  void _setFreq(RepeatFreq freq) {
    if (freq == draft.freq) return;
    onChanged(
      draft.copyWith(
        freq: freq,
        interval: 1,
        weekdays: freq == RepeatFreq.weekly ? {weekdayIndex(start)} : const {},
        cycleWeek: null,
        end: freq == RepeatFreq.none ? RepeatEnd.never : draft.end,
      ),
    );
  }

  String get _unit => switch (draft.freq) {
    RepeatFreq.daily => 'дн.',
    RepeatFreq.weekly => 'нед.',
    RepeatFreq.monthly => 'мес.',
    _ => 'г.',
  };

  Future<void> _pickUntil(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: draft.untilDate ?? start,
      firstDate: DateTime(minYear),
      lastDate: DateTime(maxYear),
      locale: const Locale('ru'),
    );
    if (picked != null) {
      onChanged(
        draft.copyWith(untilDate: civil(picked.year, picked.month, picked.day)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final cycle = this.cycle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChipRow(
          children: [
            for (final f in RepeatFreq.values)
              FilterPill(
                key: Key('repeat-freq-${f.name}'),
                label: f.label,
                selected: draft.freq == f,
                onTap: () => _setFreq(f),
              ),
          ],
        ),
        if (!draft.isNone) ...[
          if (draft.freq == RepeatFreq.weekly) ...[
            const SizedBox(height: AppSpacing.s3),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: [
                for (var d = 0; d < 7; d++)
                  FilterPill(
                    key: Key('repeat-day-$d'),
                    label: weekdayShortNames[d],
                    selected: draft.weekdays.contains(d),
                    onTap: () {
                      final next = {...draft.weekdays};
                      if (!next.remove(d)) next.add(d);
                      if (next.isEmpty) return;
                      onChanged(draft.copyWith(weekdays: next));
                    },
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            _cycleChoice(context, cycle),
          ],
          if (draft.cycleWeek == null) ...[
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                Text('Каждые', style: t.body.copyWith(color: c.textSecondary)),
                const SizedBox(width: AppSpacing.s3),
                NumberStepper(
                  keyPrefix: 'repeat-interval',
                  value: draft.interval,
                  min: 1,
                  max: 999,
                  onChanged: (v) => onChanged(draft.copyWith(interval: v)),
                ),
                const SizedBox(width: AppSpacing.s3),
                Text(_unit, style: t.body.copyWith(color: c.textSecondary)),
              ],
            ),
          ],
          if (draft.freq == RepeatFreq.monthly) ...[
            const SizedBox(height: AppSpacing.s3),
            ChipRow(
              children: [
                for (final m in MonthMode.values)
                  FilterPill(
                    key: Key('repeat-month-${m.name}'),
                    label: m.label,
                    selected: draft.monthMode == m,
                    onTap: () => onChanged(draft.copyWith(monthMode: m)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.s4),
          const FieldLabel('Окончание'),
          ChipRow(
            children: [
              for (final e in RepeatEnd.values)
                FilterPill(
                  key: Key('repeat-end-${e.name}'),
                  label: e.label,
                  selected: draft.end == e,
                  onTap: () => onChanged(
                    draft.copyWith(
                      end: e,
                      untilDate: e == RepeatEnd.until
                          ? (draft.untilDate ?? addDays(start, 30))
                          : draft.untilDate,
                    ),
                  ),
                ),
            ],
          ),
          if (draft.end == RepeatEnd.count) ...[
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                NumberStepper(
                  keyPrefix: 'repeat-count',
                  value: draft.count,
                  min: 1,
                  max: 1000,
                  onChanged: (v) => onChanged(draft.copyWith(count: v)),
                ),
                const SizedBox(width: AppSpacing.s3),
                Text('раз', style: t.body.copyWith(color: c.textSecondary)),
              ],
            ),
          ],
          if (draft.end == RepeatEnd.until) ...[
            const SizedBox(height: AppSpacing.s3),
            Align(
              alignment: Alignment.centerLeft,
              child: FilterPill(
                key: const Key('repeat-until-pick'),
                label: draft.untilDate == null
                    ? 'Выбрать дату'
                    : dayTitleShort(draft.untilDate!),
                selected: true,
                icon: LucideIcons.calendar,
                onTap: () => _pickUntil(context),
              ),
            ),
          ],
        ],
      ],
    );
  }

  /// «Каждую · Нечётная · Чётная» — чередование по циклу недель (spec 6).
  Widget _cycleChoice(BuildContext context, WeekCycle? cycle) {
    final c = context.colors;
    if (cycle == null || !cycle.isEnabled) {
      return Row(
        children: [
          Expanded(
            child: Text(
              'Чёт/нечёт: сначала настройте цикл недель.',
              style: context.text.bodyS.copyWith(color: c.textTertiary),
            ),
          ),
          if (onOpenCycleSettings != null)
            TextButton(
              key: const Key('repeat-open-cycle'),
              onPressed: onOpenCycleSettings,
              child: const Text('Настроить'),
            ),
        ],
      );
    }
    return ChipRow(
      children: [
        FilterPill(
          key: const Key('repeat-cycle-every'),
          label: 'Каждую',
          selected: draft.cycleWeek == null,
          onTap: () => onChanged(draft.copyWith(cycleWeek: null, interval: 1)),
        ),
        for (var week = 1; week <= cycle.length; week++)
          FilterPill(
            key: Key('repeat-cycle-$week'),
            label: cycle.labelOf(week),
            selected: draft.cycleWeek == week,
            icon: LucideIcons.repeat2,
            onTap: () => onChanged(
              draft.copyWith(cycleWeek: week, interval: cycle.length),
            ),
          ),
      ],
    );
  }
}
