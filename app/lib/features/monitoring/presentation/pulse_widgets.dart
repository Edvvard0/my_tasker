import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_format.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_stats.dart';

/// Тон пилюли статуса (02, 2.1.5): монохром; красный — только «лежит».
StatusTone pulseTone(PulseStatus status) => switch (status) {
  PulseStatus.up => StatusTone.success,
  PulseStatus.down => StatusTone.danger,
  PulseStatus.unknown => StatusTone.neutral,
};

/// Мини-график отклика (02, 5.8 «Аптайм серверов»): светлая линия 1,5 px с
/// серой заливкой под ней, без осей, последняя точка — кружок. Неудачи
/// (`-1`) — красные засечки внизу: сервер недоступен — разрешённое
/// исключение. Меньше двух точек — подпись «данных пока нет».
class Sparkline extends StatelessWidget {
  const Sparkline({required this.points, this.height = 32, super.key});

  /// Миллисекунды или `-1` для неудачи, от старых к новым.
  final List<int> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (points.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'Данных пока нет',
            key: const Key('spark-empty'),
            style: context.text.caption.copyWith(color: c.textTertiary),
          ),
        ),
      );
    }
    return Semantics(
      label: 'График отклика',
      excludeSemantics: true,
      child: SizedBox(
        key: const Key('spark'),
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SparkPainter(
            points: points,
            line: const Color(0xFFE6E6E6),
            area: c.surface3,
            fail: c.danger,
          ),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.points,
    required this.line,
    required this.area,
    required this.fail,
  });

  final List<int> points;
  final Color line;
  final Color area;
  final Color fail;

  @override
  void paint(Canvas canvas, Size size) {
    final ok = [
      for (final p in points)
        if (p >= 0) p,
    ];
    final top = ok.isEmpty ? 1 : ok.reduce(math.max);
    final stepX = size.width / (points.length - 1);
    double y(int ms) =>
        size.height - 4 - (size.height - 8) * ms / math.max(top, 1);
    final stroke = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = area;
    final failPaint = Paint()
      ..color = fail
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    // Непрерывные отрезки между неудачами.
    var run = <Offset>[];
    void flush() {
      if (run.length >= 2) {
        final path = Path()..moveTo(run.first.dx, run.first.dy);
        for (final o in run.skip(1)) {
          path.lineTo(o.dx, o.dy);
        }
        final areaPath = Path.from(path)
          ..lineTo(run.last.dx, size.height)
          ..lineTo(run.first.dx, size.height)
          ..close();
        canvas
          ..drawPath(areaPath, fill)
          ..drawPath(path, stroke);
      }
      run = <Offset>[];
    }

    Offset? last;
    for (var i = 0; i < points.length; i++) {
      final x = stepX * i;
      if (points[i] < 0) {
        flush();
        canvas.drawLine(
          Offset(x, size.height - 8),
          Offset(x, size.height),
          failPaint,
        );
      } else {
        final o = Offset(x, y(points[i]));
        run.add(o);
        last = o;
      }
    }
    flush();
    if (points.last >= 0 && last != null) {
      canvas.drawCircle(last, 3, Paint()..color = line);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.points != points ||
      old.line != line ||
      old.area != area ||
      old.fail != fail;
}

/// Чип проверки (02, 4.5): `● HTTP`, 24 px, `surface/3`, точка статуса слева.
/// Проверка, которая не запускается, — полая точка.
class CheckChip extends StatelessWidget {
  const CheckChip({required this.check, super.key});

  final PulseCheck check;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hollow = check.problem != null;
    final BoxDecoration dot;
    if (hollow) {
      dot = BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: c.textPrimary, width: 1.5),
      );
    } else {
      dot = BoxDecoration(
        shape: BoxShape.circle,
        color: switch (check.status) {
          PulseStatus.up => c.textPrimary,
          PulseStatus.down => c.danger,
          PulseStatus.unknown => c.textTertiary,
        },
      );
    }
    return Semantics(
      label:
          '${check.kind.label} ${check.name}: ${statusLabel(check.status)}'
          '${hollow ? ', не запускается' : ''}',
      excludeSemantics: true,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: AppRadii.borderFull,
          border: Border.all(color: c.borderDefault),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, decoration: dot),
            const SizedBox(width: 6),
            Text(
              check.kind.label,
              style: context.text.overline.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Метрика карточки: подпись UPPERCASE и крупное значение. Значение за
/// порогом не перекрашивается: оно белое жирное с иконкой предупреждения
/// (02, 5.5).
class PulseMetric extends StatelessWidget {
  const PulseMetric({
    required this.label,
    required this.value,
    this.warn = false,
    super.key,
  });

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: t.overline.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (warn) ...[
              Icon(LucideIcons.triangleAlert, size: 16, color: c.textPrimary),
              const SizedBox(width: 4),
            ],
            Text(
              value,
              style: t.numM.copyWith(
                color: value == '—' ? c.textTertiary : c.textPrimary,
                fontWeight: warn ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Карточка сервиса «Пульса» (02, 5.5): сервер, статус, название, мини-график,
/// чипы проверок, причины (`problem`), доступность и отклик. Упавший сервис —
/// красная обводка и подложка (единственное красное в разделе).
class PulseServiceCard extends StatelessWidget {
  const PulseServiceCard({
    required this.service,
    required this.now,
    required this.onTap,
    super.key,
  });

  final PulseService service;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final down = service.status == PulseStatus.down;
    final since = parseMoment(service.downSince);
    final problems = service.problems;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('pulse-card-${service.id}'),
        borderRadius: AppRadii.borderL,
        onTap: onTap,
        child: AppCard(
          emphasis: down,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'СЕРВЕР ${service.server}'.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.overline.copyWith(color: c.textTertiary),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  StatusPill(
                    label: statusLabel(service.status),
                    tone: pulseTone(service.status),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s1),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      service.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.h3,
                    ),
                  ),
                  if (down && since != null)
                    Text(
                      durationShort(
                        now.difference(since).inSeconds.clamp(0, 1 << 31),
                      ),
                      key: Key('pulse-down-${service.id}'),
                      style: t.numS.copyWith(color: c.danger),
                    ),
                ],
              ),
              if (service.critical)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: MetaCritical(),
                  ),
                ),
              const SizedBox(height: AppSpacing.s2),
              Sparkline(points: service.spark),
              const SizedBox(height: AppSpacing.s2),
              Wrap(
                spacing: AppSpacing.s1,
                runSpacing: AppSpacing.s1,
                children: [
                  for (final check in service.checks) CheckChip(check: check),
                ],
              ),
              for (final check in problems)
                Padding(
                  key: Key('pulse-problem-${check.id}'),
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        LucideIcons.triangleAlert,
                        size: 14,
                        color: c.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${check.name}: ${problemText(check.problem!)}',
                          style: t.caption.copyWith(color: c.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: AppSpacing.s3),
              Row(
                children: [
                  Expanded(
                    child: PulseMetric(
                      label: 'Доступность',
                      value: formatAvailability(service.availability.h24),
                      warn: availabilityWarns(service.availability.h24),
                    ),
                  ),
                  Expanded(
                    child: PulseMetric(
                      label: 'Отклик',
                      value: formatResponse(service.responseMs),
                      warn: responseWarns(service.responseMs),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Пометка «критичный» (звонит и в тихие часы).
class MetaCritical extends StatelessWidget {
  const MetaCritical({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.bellRing, size: 12, color: c.textSecondary),
        const SizedBox(width: 4),
        Text(
          'критичный',
          style: context.text.caption.copyWith(color: c.textSecondary),
        ),
      ],
    );
  }
}

/// Сетка карточек: минимальная ширина 280, на телефоне — одна колонка
/// (02, 3.2).
class CardGrid extends StatelessWidget {
  const CardGrid({required this.children, this.minWidth = 280, super.key});

  final List<Widget> children;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        const gap = AppSpacing.s3;
        final columns = math.max(
          1,
          ((box.maxWidth + gap) / (minWidth + gap)).floor(),
        );
        final width = (box.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

/// Строка-пометка вверху экрана: иконка, текст, при необходимости действие.
class PulseBanner extends StatelessWidget {
  const PulseBanner({
    required this.icon,
    required this.text,
    this.danger = false,
    super.key,
  });

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: danger ? c.dangerMuted : c.surface3,
        borderRadius: AppRadii.borderM,
        border: danger ? Border.all(color: c.danger) : null,
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: danger ? c.danger : c.textSecondary),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              text,
              style: context.text.bodyS.copyWith(
                color: danger ? c.danger : c.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
