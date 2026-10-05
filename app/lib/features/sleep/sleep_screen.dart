import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/format/ru_format.dart' show pluralRu;
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/shell/sections_screen.dart';
import 'package:my_tasker/features/sleep/application/sleep_providers.dart';
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';
import 'package:my_tasker/features/sleep/domain/sleep_format.dart';
import 'package:my_tasker/features/sleep/domain/sleep_habits.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_entry_sheet.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_settings_sheet.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show KpiRow, KpiTile, WorkSectionHeader;

/// Меньше стольких ночей с записью среднее показывается с пометкой «мало
/// данных» (порог интерфейса).
const int fewNights = 3;

/// «Сон»: сегодняшняя ночь, средние за 7 и 30 дней, столбики по дням,
/// тепловая карта 30 дней, связь сна с задачами, серии ритуалов и история
/// (docs/02, 6.10; docs/briefs/stage-8.md). Запись — «лёг / встал» в два
/// касания; утренний план и вечерний чек-ин открываются отсюда.
class SleepScreen extends ConsumerWidget {
  const SleepScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('sleep-overview'),
      title: 'Сон',
      onBack: backToSections(context),
      actions: [
        IconButton(
          key: const Key('sleep-open-settings'),
          tooltip: 'Напоминания',
          onPressed: () => unawaited(showSleepSettingsSheet(context)),
          icon: const Icon(LucideIcons.bell, size: 22),
        ),
        IconButton(
          key: const Key('sleep-add'),
          tooltip: 'Записать сон',
          onPressed: () => unawaited(showSleepEntrySheet(context)),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: SleepBody(builder: (context, data) => _SleepOverview(data: data)),
    );
  }
}

/// Открывает запись сна за [date]: есть — правка, нет — новая за этот день.
Future<void> openSleepDay(
  BuildContext context,
  SleepData data,
  String date,
) async {
  if (data.entryByDate.containsKey(date)) {
    await showSleepEntrySheet(context, date: date);
  } else {
    await showSleepEntrySheet(context, forDate: date);
  }
}

class _SleepOverview extends StatelessWidget {
  const _SleepOverview({required this.data});

  final SleepData data;

  @override
  Widget build(BuildContext context) {
    final compact = context.windowClass.isCompact;
    final left = <Widget>[
      _Hero(data: data),
      const SizedBox(height: AppSpacing.s3),
      _Kpis(data: data),
      if (data.history.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.s3),
        _ChartCard(data: data),
        const SizedBox(height: AppSpacing.s3),
        _HeatmapCard(data: data),
      ],
    ];
    final right = <Widget>[
      if (data.history.isNotEmpty) ...[
        _LinkCard(data: data),
        const SizedBox(height: AppSpacing.s3),
      ],
      _RitualsCard(data: data),
      if (data.history.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.s3),
        _History(data: data),
      ],
    ];
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...left,
          const SizedBox(height: AppSpacing.s3),
          ...right,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: left,
          ),
        ),
        const SizedBox(width: AppSpacing.s6),
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: right,
          ),
        ),
      ],
    );
  }
}

/// «Этой ночью»: длительность крупно, отбой и подъём; нет записи — «Как
/// спалось?» и кнопка «Записать сон».
class _Hero extends StatelessWidget {
  const _Hero({required this.data});

  final SleepData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final entry = data.lastNight;
    final view = entry?.view;
    if (entry == null || view == null) {
      return AppCard(
        key: const Key('sleep-hero-empty'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'КАК СПАЛОСЬ?',
              style: t.overline.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              data.history.isEmpty
                  ? 'Отмечайте время сна — через пару недель покажем, как сон '
                        'связан с выполненными задачами.'
                  : 'Этой ночью записи ещё нет. Это пара касаний: «Записать '
                        'сон», «Сохранить».',
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s4),
            FilledButton.icon(
              key: const Key('sleep-record'),
              onPressed: () => unawaited(showSleepEntrySheet(context)),
              icon: const Icon(LucideIcons.moon, size: 18),
              label: const Text('Записать сон'),
            ),
          ],
        ),
      );
    }
    final short = view.minutes < shortSleepMinutes;
    return AppCard(
      key: const Key('sleep-hero'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ЭТОЙ НОЧЬЮ',
            style: t.overline.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            durationText(view.minutes),
            key: const Key('sleep-hero-duration'),
            style: t.display,
          ),
          const SizedBox(height: AppSpacing.s1),
          Row(
            children: [
              Text(
                '${view.bedLocal} → ${view.wakeLocal}',
                style: t.numM.copyWith(color: c.textSecondary),
              ),
              if (entry.quality != null) ...[
                const SizedBox(width: AppSpacing.s3),
                Text(
                  'самочувствие ${entry.quality}/5',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ],
              const Spacer(),
              if (view.minutes >= sleepGoalMinutes)
                Text(
                  'цель ${sleepGoalMinutes ~/ 60} ч ✓',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                )
              else if (short)
                Text(
                  'меньше 6 ч',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          OutlinedButton(
            key: const Key('sleep-edit'),
            onPressed: () =>
                unawaited(showSleepEntrySheet(context, date: entry.date)),
            child: const Text('Изменить'),
          ),
        ],
      ),
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.data});

  final SleepData data;

  @override
  Widget build(BuildContext context) {
    String avg(SleepAverage a) =>
        a.averageMinutes == null ? '—' : durationShort(a.averageMinutes!);
    String caption(SleepAverage a) => a.daysWithData == 0
        ? 'нет данных'
        : (a.daysWithData < fewNights
              ? 'мало данных'
              : '${a.daysWithData} из ${a.days}');
    final spread = bedSpread(data.history.take(usualNights).toList());
    return KpiRow(
      tiles: [
        KpiTile(
          key: const Key('sleep-kpi-7'),
          label: '7 дней',
          value: avg(data.average7),
          caption: caption(data.average7),
        ),
        KpiTile(
          key: const Key('sleep-kpi-30'),
          label: '30 дней',
          value: avg(data.average30),
          caption: caption(data.average30),
        ),
        KpiTile(
          key: const Key('sleep-kpi-bed'),
          label: 'Отбой',
          value: data.history.isEmpty ? '—' : clockOfMinutes(data.usual.bed),
          caption: spread == null ? 'обычно' : '±$spread мин',
        ),
      ],
    );
  }
}

class _ChartCard extends StatefulWidget {
  const _ChartCard({required this.data});

  final SleepData data;

  @override
  State<_ChartCard> createState() => _ChartCardState();
}

class _ChartCardState extends State<_ChartCard> {
  int _days = 7;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final data = widget.data;
    return AppCard(
      key: const Key('sleep-chart-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'СОН ПО ДНЯМ',
                  style: t.overline.copyWith(color: c.textSecondary),
                ),
              ),
              FilterPill(
                key: const Key('sleep-chart-week'),
                label: 'Неделя',
                selected: _days == 7,
                onTap: () => setState(() => _days = 7),
              ),
              const SizedBox(width: AppSpacing.s2),
              FilterPill(
                key: const Key('sleep-chart-month'),
                label: 'Месяц',
                selected: _days == 30,
                onTap: () => setState(() => _days = 30),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          SleepBars(
            dates: windowDates(data.today, _days),
            minutes: data.minutesByDay,
            today: data.today,
            onSelect: (d) => unawaited(openSleepDay(context, data, d)),
          ),
        ],
      ),
    );
  }
}

class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard({required this.data});

  final SleepData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final dates = windowDates(data.today, 30);
    final recorded = dates.where(data.minutesByDay.containsKey).length;
    return AppCard(
      key: const Key('sleep-heatmap-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'ПОСЛЕДНИЕ 30 ДНЕЙ',
                  style: t.overline.copyWith(color: c.textSecondary),
                ),
              ),
              Text(
                '$recorded из 30 · цель ${sleepGoalMinutes ~/ 60} ч',
                key: const Key('sleep-heatmap-caption'),
                style: t.caption.copyWith(color: c.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          SleepHeatmap(
            dates: dates,
            minutes: data.minutesByDay,
            today: data.today,
            onSelect: (d) => unawaited(openSleepDay(context, data, d)),
          ),
        ],
      ),
    );
  }
}

/// «Сон и задачи»: сравнение двух долей за неделю — не статистика и не
/// причинность (spec 3.3).
class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.data});

  final SleepData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final link = data.link;
    final none = link.short.tasks == 0 && link.normal.tasks == 0;
    return AppCard(
      key: const Key('sleep-link-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'СОН И ЗАДАЧИ · 7 ДНЕЙ',
                  style: t.overline.copyWith(color: c.textSecondary),
                ),
              ),
              if (!none && !link.enoughData)
                const StatusPill(
                  label: 'Мало данных',
                  tone: StatusTone.warning,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          if (none)
            Text(
              'За последнюю неделю нет задач со сроком в дни с записью сна — '
              'сравнивать пока нечего.',
              key: const Key('sleep-link-empty'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: _LinkTile(
                    key: const Key('sleep-link-short'),
                    label: 'После короткого сна',
                    group: link.short,
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: _LinkTile(
                    key: const Key('sleep-link-normal'),
                    label: 'После нормального',
                    group: link.normal,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(
              _sentence(link),
              key: const Key('sleep-link-text'),
              style: t.bodyS,
            ),
          ],
          const SizedBox(height: AppSpacing.s2),
          Text(
            'Короткий сон — меньше 6 часов. Это сравнение двух долей за '
            'неделю, а не причина и следствие.'
            '${link.daysWithoutSleep > 0 ? ' Дней с задачами, но без записи '
                      'сна: ${link.daysWithoutSleep}.' : ''}',
            key: const Key('sleep-link-note'),
            style: t.caption.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }

  String _sentence(SleepTaskLink link) {
    final short = link.short.shareBp;
    final normal = link.normal.shareBp;
    final parts = <String>[
      if (short != null)
        'В дни после короткого сна вы закрывали ${sharePercent(short)} задач',
      if (normal != null && short != null)
        'после нормального — ${sharePercent(normal)}',
      if (normal != null && short == null)
        'В дни после нормального сна вы закрывали ${sharePercent(normal)} задач',
    ];
    final diff = link.differenceBp;
    // «п. п.» уже заканчивается точкой.
    return '${parts.join(', ')}.'
        '${diff == null ? '' : ' Разница: ${differencePoints(diff)}'}';
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.label, required this.group, super.key});

  final String label;
  final LinkGroup group;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final share = group.shareBp;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: AppRadii.borderM,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: t.caption.copyWith(color: c.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(share == null ? '—' : sharePercent(share), style: t.kpi),
          Text(
            share == null
                ? 'нет задач'
                : '${group.done} из ${group.tasks} · '
                      '${group.days} ${pluralRu(group.days, 'день', 'дня', 'дней')}',
            style: t.caption.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _RitualsCard extends StatelessWidget {
  const _RitualsCard({required this.data});

  final SleepData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final s = data.streaks;
    return AppCard(
      key: const Key('sleep-rituals-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'РИТУАЛЫ · СЕРИИ',
            style: t.overline.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s2),
          StreakRow(label: 'Утренний план', streak: s.morning),
          StreakRow(label: 'Вечерний чек-ин', streak: s.evening),
          StreakRow(label: 'Оба в один день', streak: s.both),
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              OutlinedButton.icon(
                key: const Key('sleep-open-morning'),
                onPressed: () => context.push('/sleep/morning'),
                icon: Icon(
                  data.morningDone ? LucideIcons.check : LucideIcons.sunrise,
                  size: 18,
                ),
                label: Text(data.morningDone ? 'План сделан' : 'Утренний план'),
              ),
              OutlinedButton.icon(
                key: const Key('sleep-open-evening'),
                onPressed: () => context.push('/sleep/evening'),
                icon: Icon(
                  data.eveningDone ? LucideIcons.check : LucideIcons.sunset,
                  size: 18,
                ),
                label: Text(
                  data.eveningDone ? 'Чек-ин сделан' : 'Вечерний чек-ин',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _History extends StatefulWidget {
  const _History({required this.data});

  final SleepData data;

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  static const int _shown = 14;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final items = _all ? data.history : data.history.take(_shown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const WorkSectionHeader(title: 'История'),
        AppCard(
          key: const Key('sleep-history'),
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final e in items) _row(context, e),
              if (data.history.length > _shown)
                TextButton(
                  key: const Key('sleep-history-more'),
                  onPressed: () => setState(() => _all = !_all),
                  child: Text(
                    _all ? 'Свернуть' : 'Показать все · ${data.history.length}',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, SleepEntry e) {
    final view = e.view!;
    return InkWell(
      key: Key('sleep-history-${e.date}'),
      borderRadius: AppRadii.borderL,
      onTap: () => unawaited(showSleepEntrySheet(context, date: e.date)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dateShort(e.date), style: context.text.body),
                  Text(
                    '${view.bedLocal} → ${view.wakeLocal}'
                    '${e.quality == null ? '' : ' · самочувствие ${e.quality}/5'}',
                    style: context.text.caption.copyWith(
                      color: context.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              durationText(view.minutes),
              style: context.text.numM.copyWith(
                color: view.minutes < shortSleepMinutes
                    ? context.colors.textSecondary
                    : context.colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
