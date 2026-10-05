import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/features/sleep/application/sleep_providers.dart';
import 'package:my_tasker/features/sleep/domain/sleep_format.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_entry_sheet.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_widgets.dart';

/// Утром (до полудня), пока сон не записан, блок «Сон» идёт первым после
/// тревог (docs/02, 3.6); дальше — в конце дня.
bool sleepPromptFirst(SleepData data, DateTime nowWall) =>
    nowWall.hour < 12 && data.lastNight == null;

/// Вечерний чек-ин предлагается после 18:00.
const int eveningFromHour = 18;

/// Блок «Сон и ритуалы» на «Сегодня»: «Как спал?» — запись двумя касаниями,
/// либо «23:40 → 07:10 · 7 ч 30 мин» и тепловая карта 30 дней; кнопки
/// утреннего плана и вечернего чек-ина и серия ритуалов.
class SleepRitualsBlock extends ConsumerWidget {
  const SleepRitualsBlock({required this.nowWall, super.key});

  /// «Настенное» время устройства сейчас.
  final DateTime nowWall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(sleepDataProvider).value;
    if (data == null) return const SizedBox.shrink();
    final c = context.colors;
    final t = context.text;
    final view = data.lastNight?.view;
    final showEvening = !data.eveningDone && nowWall.hour >= eveningFromHour;
    final streak = data.streaks.both.current > 0
        ? data.streaks.both.current
        : (data.streaks.morning.current > data.streaks.evening.current
              ? data.streaks.morning.current
              : data.streaks.evening.current);
    return AppCard(
      key: const Key('today-sleep-block'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('today-sleep-open'),
            borderRadius: AppRadii.borderM,
            onTap: () => context.go('/sleep'),
            child: Row(
              children: [
                Icon(LucideIcons.moon, size: 20, color: c.textSecondary),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: view == null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'СОН',
                              style: t.overline.copyWith(
                                color: c.textSecondary,
                              ),
                            ),
                            Text('Как спал?', style: t.h3),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'СОН',
                              style: t.overline.copyWith(
                                color: c.textSecondary,
                              ),
                            ),
                            Text(
                              '${view.bedLocal} → ${view.wakeLocal} · '
                              '${durationText(view.minutes)}',
                              key: const Key('today-sleep-summary'),
                              style: t.numM,
                            ),
                          ],
                        ),
                ),
                if (view == null)
                  FilledButton(
                    key: const Key('today-sleep-record'),
                    onPressed: () => unawaited(showSleepEntrySheet(context)),
                    child: const Text('Записать'),
                  )
                else
                  Icon(
                    LucideIcons.chevronRight,
                    size: 16,
                    color: c.textTertiary,
                  ),
              ],
            ),
          ),
          if (data.history.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s3),
            SleepHeatmap(
              dates: windowDates(data.today, 30),
              minutes: data.minutesByDay,
              today: data.today,
            ),
          ],
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!data.morningDone)
                OutlinedButton.icon(
                  key: const Key('today-open-morning'),
                  onPressed: () => context.push('/sleep/morning'),
                  icon: const Icon(LucideIcons.sunrise, size: 18),
                  label: const Text('Утренний план'),
                ),
              if (showEvening)
                OutlinedButton.icon(
                  key: const Key('today-open-evening'),
                  onPressed: () => context.push('/sleep/evening'),
                  icon: const Icon(LucideIcons.sunset, size: 18),
                  label: const Text('Вечерний чек-ин'),
                ),
              if (streak > 0)
                Text(
                  'Серия ритуалов: $streak дн.',
                  key: const Key('today-streak'),
                  style: t.caption.copyWith(color: c.textSecondary),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
