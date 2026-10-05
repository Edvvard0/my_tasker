import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/sleep/application/sleep_providers.dart';
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart';
import 'package:my_tasker/features/sleep/domain/sleep_format.dart';

/// Назад из экрана «Сна»: на шаг назад, а при прямом входе — в «Сон».
void sleepBack(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/sleep');
  }
}

/// Содержимое экрана «Сна»: пока данные читаются — скелетон, при ошибке
/// чтения — красная карточка с «Повторить», иначе [builder].
class SleepBody extends ConsumerWidget {
  const SleepBody({required this.builder, super.key});

  final Widget Function(BuildContext context, SleepData data) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(sleepDataProvider)
        .when(
          loading: () => const ListSkeleton(rows: 4),
          error: (error, _) => NoticeCard(
            key: const Key('sleep-error'),
            label: 'Не загрузилось',
            tone: StatusTone.danger,
            text: 'Не удалось прочитать данные «Сна» на устройстве.',
            actions: [
              FilledButton(
                key: const Key('sleep-retry'),
                onPressed: () => retrySleepData(ref),
                child: const Text('Повторить'),
              ),
            ],
          ),
          data: (data) => builder(context, data),
        );
  }
}

/// Подпись-перечень для скринридера: «21 сентября: 7 ч 30 мин».
String _spoken(String date, int? minutes) =>
    '${dateLong(date)}: ${minutes == null ? 'нет записи' : durationText(minutes)}';

/// Пунктирный контур (скруглённый прямоугольник): «нет данных» в тепловой
/// карте и пустой столбик графика (02, 2.1.7).
class DashedBox extends StatelessWidget {
  const DashedBox({
    required this.color,
    this.radius = AppRadii.full,
    this.width = 1,
    super.key,
  });

  final Color color;
  final double radius;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashedPainter(color: color, radius: radius, width: width),
    child: const SizedBox.expand(),
  );
}

class _DashedPainter extends CustomPainter {
  _DashedPainter({
    required this.color,
    required this.radius,
    required this.width,
  });

  final Color color;
  final double radius;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(radius, math.min(size.width, size.height) / 2);
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        width / 2,
        width / 2,
        math.max(0, size.width - width),
        math.max(0, size.height - width),
      ),
      Radius.circular(r),
    );
    final path = Path()..addRRect(rect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 3), paint);
        d += 6;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) =>
      old.color != color || old.radius != radius || old.width != width;
}

/// Столбики сна по дням (свои, без библиотек графиков): белая заливка —
/// нормальная ночь, серая — короче 6 часов, пунктир — нет записи;
/// пунктирная линия — порог «короткого» сна; сегодняшний день подчёркнут
/// синим. Тап по столбику — [onSelect] с датой.
class SleepBars extends StatelessWidget {
  const SleepBars({
    required this.dates,
    required this.minutes,
    required this.today,
    this.onSelect,
    this.height = 120,
    super.key,
  });

  final List<String> dates;
  final Map<String, int> minutes;
  final String today;
  final ValueChanged<String>? onSelect;
  final double height;

  /// Шкала графика: не меньше 10 часов, выше — по максимуму.
  int get _scale => math.max(600, minutes.values.fold<int>(0, math.max));

  static const double _labelBand = 26;
  static const double _thresholdLabelWidth = 28;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final scale = _scale;
    final wide = dates.length <= 8;
    final summary = StringBuffer('Сон за ${dates.length} дн.: ');
    final slept = [
      for (final d in dates)
        if (minutes[d] != null) minutes[d]!,
    ];
    summary.write(
      slept.isEmpty
          ? 'записей нет'
          : 'записей ${slept.length}, максимум '
                '${durationText(slept.reduce(math.max))}',
    );
    return Semantics(
      container: true,
      label: summary.toString(),
      child: SizedBox(
        height: height + _labelBand,
        child: Stack(
          children: [
            // Порог «короткого» сна — 6 часов.
            Positioned(
              left: 0,
              right: 0,
              bottom: _labelBand + height * shortSleepMinutes / scale,
              child: Row(
                key: const Key('sleep-threshold'),
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 1,
                      child: DashedBox(color: c.borderStrong, radius: 0),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text('6 ч', style: t.caption.copyWith(color: c.textTertiary)),
                ],
              ),
            ),
            // Справа — поле под подпись порога, чтобы она не лежала на столбцах.
            Positioned.fill(
              right: _thresholdLabelWidth,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < dates.length; i++)
                    Expanded(
                      child: _column(context, dates[i], i, scale, wide: wide),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _column(
    BuildContext context,
    String date,
    int index,
    int scale, {
    required bool wide,
  }) {
    final c = context.colors;
    final t = context.text;
    final value = minutes[date];
    final isToday = date == today;
    final day = parseDate(date)!;
    final label = wide
        ? weekdayShortNames[weekdayIndex(day)]
        : (index % 5 == 0 || isToday ? '${day.day}' : '');
    final barWidth = wide ? 14.0 : 5.0;
    final Widget bar;
    if (value == null) {
      bar = SizedBox(
        width: barWidth,
        height: 6,
        child: DashedBox(color: c.borderStrong, radius: 2),
      );
    } else {
      final h = (height * value / scale).clamp(2.0, height);
      bar = Container(
        width: barWidth,
        height: h,
        decoration: BoxDecoration(
          color: value < shortSleepMinutes
              ? AppColors.chartSeries[3]
              : AppColors.chartSeries[1],
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
        ),
      );
    }
    return Semantics(
      button: onSelect != null,
      label: _spoken(date, value),
      child: InkWell(
        key: Key('sleep-bar-$date'),
        onTap: onSelect == null ? null : () => onSelect!(date),
        borderRadius: AppRadii.borderS,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SizedBox(
              height: height,
              child: Align(alignment: Alignment.bottomCenter, child: bar),
            ),
            const SizedBox(height: 4),
            Container(
              height: 18,
              padding: const EdgeInsets.symmetric(horizontal: 1),
              decoration: isToday
                  ? BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: c.accent, width: 2),
                      ),
                    )
                  : null,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: t.caption.copyWith(
                    color: isToday ? c.accent : c.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Тепловая карта «последние 30 дней» (02, 5.1.7): 3 строки по 10 пилюль,
/// серая шкала `heat/*` (максимум — почти белая заливка), пунктир — нет
/// записи, синяя обводка 2 px — сегодня. Тап — [onSelect] с датой.
class SleepHeatmap extends StatelessWidget {
  const SleepHeatmap({
    required this.dates,
    required this.minutes,
    required this.today,
    this.onSelect,
    super.key,
  });

  final List<String> dates;
  final Map<String, int> minutes;
  final String today;
  final ValueChanged<String>? onSelect;

  static const int perRow = 10;
  static const double gap = 6;
  static const double cellHeight = 18;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, box) {
        final cell = ((box.maxWidth - gap * (perRow - 1)) / perRow).clamp(
          16.0,
          44.0,
        );
        final rows = <Widget>[];
        for (var start = 0; start < dates.length; start += perRow) {
          final slice = dates.sublist(
            start,
            math.min(start + perRow, dates.length),
          );
          rows.add(
            Padding(
              padding: EdgeInsets.only(top: start == 0 ? 0 : gap),
              child: Row(
                children: [
                  for (var i = 0; i < slice.length; i++) ...[
                    if (i > 0) const SizedBox(width: gap),
                    _cell(c, slice[i], cell),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          key: const Key('sleep-heatmap'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        );
      },
    );
  }

  Widget _cell(AppColors c, String date, double width) {
    final value = minutes[date];
    final isToday = date == today;
    final Widget fill;
    if (value == null) {
      fill = DashedBox(color: c.borderStrong);
    } else {
      fill = DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.heat[heatLevel(value)],
          borderRadius: AppRadii.borderFull,
        ),
      );
    }
    return Semantics(
      button: onSelect != null,
      label: _spoken(date, value),
      child: GestureDetector(
        key: Key('heat-$date'),
        onTap: onSelect == null ? null : () => onSelect!(date),
        child: Container(
          width: width,
          height: cellHeight,
          decoration: isToday
              ? BoxDecoration(
                  borderRadius: AppRadii.borderFull,
                  border: Border.all(color: c.accent, width: 2),
                )
              : null,
          padding: isToday ? const EdgeInsets.all(2) : null,
          child: fill,
        ),
      ),
    );
  }
}

/// Строка серии: подпись и «N дн. подряд · лучшая M».
class StreakRow extends StatelessWidget {
  const StreakRow({required this.label, required this.streak, super.key});

  final String label;
  final Streak streak;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: t.body)),
          Text(
            '${streak.current}',
            style: t.numM.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 4),
          Text(
            'дн. · лучшая ${streak.best}',
            style: t.caption.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}
