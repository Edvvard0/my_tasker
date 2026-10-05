import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_format.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

/// Строка ленты инцидентов (02, 5.5): `● Лежит · Сервис · 30 сент., 14:20 →
/// сейчас (12 мин) · причина`; закрытые — серые с длительностью.
class IncidentTile extends StatelessWidget {
  const IncidentTile({
    required this.incident,
    required this.now,
    this.showService = true,
    super.key,
  });

  final Incident incident;
  final DateTime now;

  /// В карточке одного сервиса его название не повторяется.
  final bool showService;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final started = parseMoment(incident.startedAt);
    final ended = parseMoment(incident.endedAt);
    final seconds =
        incident.durationSeconds ??
        (started == null ? null : now.difference(started).inSeconds);
    final span = StringBuffer()
      ..write(incidentMoment(incident.startedAt, now))
      ..write(' → ')
      ..write(
        incident.isOpen
            ? 'сейчас'
            : ended == null
            ? '—'
            : formatLocalClock(ended),
      );
    if (seconds != null) {
      span.write(' (${durationShort(seconds < 0 ? 0 : seconds)})');
    }
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: StatusPill(
              label: incident.isOpen ? 'Лежит' : 'Закрыт',
              tone: incident.isOpen ? StatusTone.danger : StatusTone.neutral,
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showService)
                  Text(
                    incident.serviceName ?? 'Сервис удалён',
                    style: t.bodyStrong.copyWith(
                      color: incident.serviceName == null
                          ? c.textTertiary
                          : c.textPrimary,
                    ),
                  ),
                Text(
                  span.toString(),
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        LucideIcons.circleAlert,
                        size: 13,
                        color: c.textTertiary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          incidentReason(incident.reason),
                          style: t.caption.copyWith(color: c.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
