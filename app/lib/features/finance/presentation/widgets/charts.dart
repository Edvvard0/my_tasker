import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/domain/analytics_views.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';

/// Графики Финансов (02, 2.1.7 и 5.3): серые тона с одним синим акцентом,
/// рисуются собственными `CustomPainter` (графической библиотеки в проекте
/// нет). Цвета — токены темы и ряды `AppColors.chartSeries`; сетка только
/// горизонтальная, ось Y без линии, подписи — сокращённые суммы (`12,5к`).

/// Цвет дохода на столбиках: светлый (`chart/2`).
const Color incomeBarColor = Color(0xFFE6E6E6);

/// Цвет расхода на столбиках: средне-серый (`chart/4`).
final Color expenseBarColor = AppColors.chartSeries[3];

/// «Красивый» верх шкалы не меньше [value] копеек: 1, 2 или 5 × 10^k.
int niceCeiling(int value) {
  if (value <= 0) return 100000;
  var step = 1;
  while (step * 10 < value) {
    step *= 10;
  }
  for (final k in const [1, 2, 5, 10]) {
    if (step * k >= value) return step * k;
  }
  return step * 10;
}

TextPainter _label(String text, TextStyle style) => TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: TextDirection.ltr,
  maxLines: 1,
)..layout();

void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
  const dash = 4.0;
  const gap = 4.0;
  final total = (b - a).distance;
  if (total == 0) return;
  final dir = (b - a) / total;
  for (var d = 0.0; d < total; d += dash + gap) {
    canvas.drawLine(a + dir * d, a + dir * math.min(d + dash, total), paint);
  }
}

/// Пустой график: серая пунктирная ось и текст по центру (02, 5.3.1).
class EmptyChart extends StatelessWidget {
  const EmptyChart({
    this.text = 'Нет операций за этот период',
    this.height = 160,
    super.key,
  });

  final String text;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _DashedAxisPainter(c.borderStrong)),
          ),
          Text(
            text,
            textAlign: TextAlign.center,
            style: context.text.bodyS.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _DashedAxisPainter extends CustomPainter {
  _DashedAxisPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height - 12;
    _dashedLine(
      canvas,
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = color
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_DashedAxisPainter old) => old.color != color;
}

/// Высота графика по классу ширины (02, 5: 160–200 / 240–320).
double chartHeight(BuildContext context) =>
    context.windowClass.isCompact ? 180 : 240;

/// Доход и расход по месяцам: сгруппированные столбики (02, 5.3.2); текущий
/// месяц обведён и подписан синим.
class MonthBarsChart extends StatelessWidget {
  const MonthBarsChart({
    required this.months,
    required this.currentMonth,
    super.key,
  });

  final List<MonthTotals> months;

  /// `YYYY-MM` текущего месяца.
  final String currentMonth;

  String get _summary {
    if (months.isEmpty) return 'Нет данных по месяцам';
    final best = months.reduce((a, b) => a.income >= b.income ? a : b);
    return 'Доходы и расходы за ${months.length} мес.: '
        'максимум дохода в ${axisMonthText(best.month)} '
        '${moneyText(best.income)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final compact = context.windowClass.isCompact;
    return Semantics(
      label: _summary,
      image: true,
      child: SizedBox(
        key: const Key('chart-months'),
        height: chartHeight(context),
        width: double.infinity,
        child: CustomPaint(
          painter: _MonthBarsPainter(
            months: months,
            currentMonth: currentMonth,
            colors: c,
            labelStyle: context.text.caption.copyWith(color: c.textTertiary),
            accentStyle: context.text.caption.copyWith(color: c.accent),
            radius: compact ? 3 : 4,
          ),
        ),
      ),
    );
  }
}

class _MonthBarsPainter extends CustomPainter {
  _MonthBarsPainter({
    required this.months,
    required this.currentMonth,
    required this.colors,
    required this.labelStyle,
    required this.accentStyle,
    required this.radius,
  });

  final List<MonthTotals> months;
  final String currentMonth;
  final AppColors colors;
  final TextStyle labelStyle;
  final TextStyle accentStyle;
  final double radius;

  static const double _axisWidth = 40;
  static const double _bottom = 24;

  @override
  void paint(Canvas canvas, Size size) {
    if (months.isEmpty) return;
    final plot = Rect.fromLTRB(
      _axisWidth,
      8,
      size.width,
      size.height - _bottom,
    );
    var maxValue = 0;
    for (final m in months) {
      maxValue = math.max(maxValue, math.max(m.income, m.expense));
    }
    final top = niceCeiling(maxValue);
    final grid = Paint()
      ..color = colors.borderSubtle
      ..strokeWidth = 1;
    final base = Paint()
      ..color = colors.borderDefault
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = plot.bottom - plot.height * i / 2;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        i == 0 ? base : grid,
      );
      final label = _label(axisAmountText(top * i ~/ 2), labelStyle);
      label.paint(
        canvas,
        Offset(_axisWidth - 8 - label.width, y - label.height / 2),
      );
    }
    final slot = plot.width / months.length;
    final group = slot * 0.6;
    final gap = math.min(2, group * 0.05);
    final barWidth = (group - gap) / 2;
    final every = months.length > 12
        ? 3
        : months.length > 8
        ? 2
        : 1;
    for (var i = 0; i < months.length; i++) {
      final m = months[i];
      final left = plot.left + slot * i + (slot - group) / 2;
      void bar(int value, double x, Color color) {
        if (value <= 0) return;
        final height = math.max<double>(2, plot.height * value / top);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, plot.bottom - height, barWidth, height),
            topLeft: Radius.circular(radius),
            topRight: Radius.circular(radius),
          ),
          Paint()..color = color,
        );
      }

      bar(m.income, left, incomeBarColor);
      bar(m.expense, left + barWidth + gap, expenseBarColor);
      final current = m.month == currentMonth;
      if (current) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              plot.left + slot * i + 1,
              plot.top,
              plot.left + slot * (i + 1) - 1,
              plot.bottom + 4,
            ),
            Radius.circular(radius + 2),
          ),
          Paint()
            ..color = colors.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (current || i % every == 0 || i == months.length - 1 && every == 1) {
        final text = _label(
          axisMonthText(m.month),
          current ? accentStyle : labelStyle,
        );
        text.paint(
          canvas,
          Offset(
            plot.left + slot * i + (slot - text.width) / 2,
            plot.bottom + 8,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MonthBarsPainter old) =>
      old.months != months ||
      old.currentMonth != currentMonth ||
      old.colors != colors;
}

/// Динамика общего баланса: линия и серая area, последняя точка («сегодня»)
/// — синяя (02, 5.3.2). Шкала плавающая, с подписями минимума и максимума.
class BalanceLineChart extends StatelessWidget {
  const BalanceLineChart({required this.points, super.key});

  final List<BalancePoint> points;

  String get _summary => points.isEmpty
      ? 'Нет данных о балансе'
      : 'Общий баланс: сейчас ${moneyText(points.last.total)}, '
            'в начале периода ${moneyText(points.first.total)}';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: _summary,
      image: true,
      child: SizedBox(
        key: const Key('chart-balance'),
        height: chartHeight(context),
        width: double.infinity,
        child: CustomPaint(
          painter: _LinePainter(
            points: points,
            colors: c,
            labelStyle: context.text.caption.copyWith(color: c.textTertiary),
          ),
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.points,
    required this.colors,
    required this.labelStyle,
  });

  final List<BalancePoint> points;
  final AppColors colors;
  final TextStyle labelStyle;

  static const double _axisWidth = 44;
  static const double _bottom = 24;

  String _xLabel(int i) {
    if (i == points.length - 1) return 'сегодня';
    return axisMonthText(points[i].date.substring(0, 7));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final plot = Rect.fromLTRB(
      _axisWidth,
      10,
      size.width - 10,
      size.height - _bottom,
    );
    var lo = points.map((p) => p.total).reduce(math.min);
    var hi = points.map((p) => p.total).reduce(math.max);
    if (lo == hi) {
      final pad = math.max(hi.abs() ~/ 10, 100000);
      lo -= pad;
      hi += pad;
    } else {
      final pad = (hi - lo) ~/ 10;
      lo -= pad;
      hi += pad;
    }
    final span = hi - lo;
    double yOf(int v) => plot.bottom - plot.height * (v - lo) / span;
    final grid = Paint()
      ..color = colors.borderSubtle
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = plot.bottom - plot.height * i / 2;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        i == 0
            ? (Paint()
                ..color = colors.borderDefault
                ..strokeWidth = 1)
            : grid,
      );
      final label = _label(axisAmountText(lo + span * i ~/ 2), labelStyle);
      label.paint(
        canvas,
        Offset(_axisWidth - 8 - label.width, y - label.height / 2),
      );
    }
    if (lo < 0 && hi > 0) {
      _dashedLine(
        canvas,
        Offset(plot.left, yOf(0)),
        Offset(plot.right, yOf(0)),
        Paint()
          ..color = colors.borderStrong
          ..strokeWidth = 1,
      );
    }
    final n = points.length;
    double xOf(int i) =>
        n == 1 ? plot.center.dx : plot.left + plot.width * i / (n - 1);
    final line = Path();
    for (var i = 0; i < n; i++) {
      final p = Offset(xOf(i), yOf(points[i].total));
      if (i == 0) {
        line.moveTo(p.dx, p.dy);
      } else {
        line.lineTo(p.dx, p.dy);
      }
    }
    if (n > 1) {
      final area = Path.from(line)
        ..lineTo(xOf(n - 1), plot.bottom)
        ..lineTo(xOf(0), plot.bottom)
        ..close();
      canvas
        ..drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.chartSeries[3].withValues(alpha: 0.4),
                AppColors.chartSeries[3].withValues(alpha: 0),
              ],
            ).createShader(plot),
        )
        ..drawPath(
          line,
          Paint()
            ..color = incomeBarColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round,
        );
    }
    // Подписи по X: первая, последняя и несколько между (не гуще чем раз в 56 px).
    var lastRight = -1000.0;
    for (var i = 0; i < n; i++) {
      final step = math.max(1, (n / (plot.width / 56)).ceil());
      if (i % step != 0 && i != n - 1) continue;
      final text = _label(_xLabel(i), labelStyle);
      final x = (xOf(i) - text.width / 2).clamp(0.0, size.width - text.width);
      if (x < lastRight + 6) continue;
      text.paint(canvas, Offset(x, plot.bottom + 8));
      lastRight = x + text.width;
    }
    final end = Offset(xOf(n - 1), yOf(points.last.total));
    canvas
      ..drawCircle(end, 6, Paint()..color = colors.surface1)
      ..drawCircle(end, 4, Paint()..color = colors.accent);
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.points != points || old.colors != colors;
}

/// Горизонтальная полоса доли (категории, мерчанты, остатки): один серый
/// тон, главная строка — светлее; [fraction] 0…1.
class ShareBar extends StatelessWidget {
  const ShareBar({
    required this.fraction,
    this.highlight = false,
    this.height = 8,
    super.key,
  });

  final double fraction;
  final bool highlight;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ClipRRect(
      borderRadius: AppRadii.borderFull,
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: c.surface3)),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0),
              child: ColoredBox(
                color: highlight
                    ? AppColors.chartSeries[1]
                    : AppColors.chartSeries[2],
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
