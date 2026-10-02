import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart' show FieldLabel;
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/data/calendar_settings.dart';
import 'package:my_tasker/features/calendar/data/week_cycle_actions.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_models.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';

/// «Настройки календаря»: цикл недель (чёт/нечёт, spec 6), «Пропустить
/// неделю», «Сдвинуть чётность», время напоминаний «весь день» и
/// разрешения на уведомления.
class CalendarSettingsScreen extends ConsumerWidget {
  const CalendarSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(calendarBootstrapProvider);
    return ScreenScaffold(
      title: 'Настройки календаря',
      parentLabel: 'Календарь',
      onBack: () => context.go('/calendar'),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _LayersLink(),
              SizedBox(height: AppSpacing.s3),
              _CycleCard(),
              SizedBox(height: AppSpacing.s3),
              _RemindersCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _LayersLink extends StatelessWidget {
  const _LayersLink();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        key: const Key('settings-layers'),
        borderRadius: BorderRadius.circular(24),
        onTap: () => context.go('/calendar/layers'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: Row(
            children: [
              Icon(LucideIcons.layers, size: 20, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Календари и слои', style: context.text.body),
                    Text(
                      'Видимость, порядок, свои календари',
                      style: context.text.bodyS.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _CycleCard extends ConsumerWidget {
  const _CycleCard();

  Future<void> _write(WidgetRef ref, WeekCycle? cycle) =>
      ref.read(calendarSettingsRepositoryProvider).writeWeekCycle(cycle);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final cycle = ref.watch(weekCycleProvider).value;
    final today = ref.watch(todayProvider);
    final enabled = cycle != null && cycle.isEnabled;
    return AppCard(
      key: const Key('cycle-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.repeat2, size: 20, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s3),
              Expanded(child: Text('Чередование недель', style: t.h3)),
              Switch(
                key: const Key('cycle-switch'),
                value: enabled,
                onChanged: (on) => _write(
                  ref,
                  on ? WeekCycle(length: 2, week1Start: mondayOf(today)) : null,
                ),
              ),
            ],
          ),
          Text(
            enabled
                ? 'Сейчас: ${cycle.labelForDate(today).toLowerCase()} неделя'
                : 'Выключено: каждая неделя одинаковая.',
            key: const Key('cycle-status'),
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          if (enabled) ...[
            const SizedBox(height: AppSpacing.s4),
            const FieldLabel('Длина цикла'),
            ChipRow(
              children: [
                for (var n = 2; n <= 4; n++)
                  FilterPill(
                    key: Key('cycle-length-$n'),
                    label: n == 2 ? '2 недели (чёт/нечёт)' : '$n недели',
                    selected: cycle.length == n,
                    onTap: () => _write(
                      ref,
                      WeekCycle(
                        length: n,
                        week1Start: cycle.week1Start,
                        shifts: cycle.shifts,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            const FieldLabel('Сейчас идёт неделя'),
            ChipRow(
              children: [
                for (var w = 1; w <= cycle.length; w++)
                  FilterPill(
                    key: Key('cycle-now-$w'),
                    label: cycle.labelOf(w),
                    selected: cycle.weekNumber(today) == w,
                    onTap: () {
                      // Опора цикла — так, чтобы текущая неделя была №w
                      // (сдвиги учитываются).
                      final current = cycle.weekNumber(today);
                      final delta = (w - current) % cycle.length;
                      unawaited(
                        _write(
                          ref,
                          WeekCycle(
                            length: cycle.length,
                            week1Start: addDays(cycle.week1Start, -7 * delta),
                            shifts: cycle.shifts,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              'Неделя 1 начинается: '
              '${dayMonth(mondayOf(cycle.week1Start), now: today)} '
              '(понедельник)',
              key: const Key('cycle-week1'),
              style: t.bodyS.copyWith(color: c.textTertiary),
            ),
            const SizedBox(height: AppSpacing.s4),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: [
                ElevatedButton.icon(
                  key: const Key('cycle-skip'),
                  onPressed: () => _skipWeek(context, ref),
                  icon: const Icon(LucideIcons.calendarX, size: 18),
                  label: const Text('Пропустить неделю'),
                ),
                ElevatedButton.icon(
                  key: const Key('cycle-shift'),
                  onPressed: () => _shift(context, ref),
                  icon: const Icon(LucideIcons.arrowRightLeft, size: 18),
                  label: const Text('Сдвинуть чётность'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _skipWeek(BuildContext context, WidgetRef ref) async {
    final today = ref.read(todayProvider);
    final monday = mondayOf(today);
    final choice = await showDialog<DateTime>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Пропустить неделю', style: context.text.h3),
        children: [
          SimpleDialogOption(
            key: const Key('skip-this'),
            onPressed: () => Navigator.of(context).pop(monday),
            child: Text('Эту (${weekRange(monday)})'),
          ),
          SimpleDialogOption(
            key: const Key('skip-next'),
            onPressed: () => Navigator.of(context).pop(addDays(monday, 7)),
            child: Text('Следующую (${weekRange(addDays(monday, 7))})'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    final actions = ref.read(weekCycleActionsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final skipped = await actions.skipWeek(
      choice,
      ref.read(deviceTimeZoneProvider),
    );
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            skipped.isEmpty
                ? 'На этой неделе нет повторяющихся событий'
                : 'Пропущено занятий: ${skipped.length}',
          ),
          duration: const Duration(seconds: 5),
          action: skipped.isEmpty
              ? null
              : SnackBarAction(
                  label: 'Отменить',
                  onPressed: () => actions.undoSkipWeek(skipped),
                ),
        ),
      );
  }

  Future<void> _shift(BuildContext context, WidgetRef ref) async {
    final today = ref.read(todayProvider);
    final monday = addDays(mondayOf(today), 7);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('shift-dialog'),
        title: Text('Сдвинуть чётность', style: context.text.h3),
        content: Text(
          'С ${dayMonth(monday, now: today)} чётная и нечётная недели '
          'поменяются местами: прошлые недели останутся как есть, а '
          'повторяющиеся занятия сдвинутся на неделю.',
          style: context.text.body.copyWith(
            color: context.colors.textSecondary,
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('shift-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Сдвинуть'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final count = await ref.read(weekCycleActionsProvider).shiftParity(monday);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('Сдвинуто серий: $count')));
  }
}

class _RemindersCard extends ConsumerWidget {
  const _RemindersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final time =
        ref.watch(allDayReminderTimeProvider).value ??
        defaultAllDayReminderTime;
    final minutes = parseClockMinutes(time) ?? 540;
    final permission = ref.watch(reminderPermissionProvider).value;
    final (text, needsAction) = switch (permission) {
      ReminderPermission.granted => ('Уведомления разрешены.', false),
      ReminderPermission.notificationsDenied => (
        'Уведомления запрещены: напоминания не придут.',
        true,
      ),
      ReminderPermission.exactAlarmsDenied => (
        'Нет доступа к точным будильникам: напоминания могут опаздывать.',
        true,
      ),
      _ => ('Разрешения не требуются.', false),
    };
    return AppCard(
      key: const Key('reminders-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.bell, size: 20, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s3),
              Text('Напоминания', style: t.h3),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          const FieldLabel('Для событий и задач без времени — в'),
          TimeChoiceRow(
            keyPrefix: 'allday-reminder',
            allowNone: false,
            value: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
            onChanged: (v) {
              if (v == null) return;
              unawaited(
                ref
                    .read(calendarSettingsRepositoryProvider)
                    .writeAllDayReminderTime(clockText(v.hour, v.minute)),
              );
            },
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            text,
            key: const Key('permission-text'),
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          if (needsAction) ...[
            const SizedBox(height: AppSpacing.s2),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                key: const Key('permission-request'),
                onPressed: () async {
                  await ref.read(reminderSchedulerProvider).requestPermission();
                  ref.invalidate(reminderPermissionProvider);
                },
                child: const Text('Разрешить'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
