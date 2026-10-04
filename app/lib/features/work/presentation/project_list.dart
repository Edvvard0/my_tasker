import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/core/format/ru_format.dart' as ru;
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/work/application/timer_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

void openProject(BuildContext context, String projectId) =>
    context.push('/work/projects/$projectId');

/// Имя заказчика проекта: «заказчик не указан», если его нет или он удалён
/// (spec 2: ссылка не чистится).
String clientName(WorkData data, WorkProject project) {
  final id = project.clientId;
  if (id == null) return 'заказчик не указан';
  return data.personById[id]?.name ?? 'заказчик не указан';
}

String _doneCount(int n) =>
    '$n ${pluralWord(n, 'доработка', 'доработки', 'доработок')}';

/// Форма слова по числу (1 доработка, 2 доработки, 5 доработок).
String pluralWord(int n, String one, String few, String many) =>
    ru.pluralRu(n, one, few, many);

/// Мобильные карточки проектов (02, 6.6).
class ProjectCards extends ConsumerWidget {
  const ProjectCards({required this.data, required this.projects, super.key});

  final WorkData data;
  final List<WorkProject> projects;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = {
      for (final t in ref.watch(runningTimersProvider)) t.entry.projectId,
    };
    return Column(
      children: [
        for (final p in projects) ...[
          _ProjectCard(
            data: data,
            project: p,
            timerRunning: running.contains(p.id),
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
      ],
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.data,
    required this.project,
    required this.timerRunning,
  });

  final WorkData data;
  final WorkProject project;
  final bool timerRunning;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final s = data.summaryOf(project.id);
    final crCount = [
      for (final cr in data.changeRequestsOf(project.id))
        if (cr.status != ChangeRequestStatus.cancelled) cr,
    ].length;
    final meta = [
      clientName(data, project),
      if (crCount > 0) _doneCount(crCount),
      if (project.deadlineDate != null)
        'срок ${formatDateText(project.deadlineDate, data.now)}',
    ].join(' · ');
    return InkWell(
      key: Key('project-${project.id}'),
      borderRadius: AppRadii.borderL,
      onTap: () => openProject(context, project.id),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (timerRunning) ...[
                  Container(
                    key: Key('project-timer-dot-${project.id}'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: c.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                ],
                Expanded(
                  child: Text(
                    project.title,
                    style: t.h3,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                StatusPill(
                  label: project.effectiveStatus.label,
                  tone: projectTone(project.effectiveStatus),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              meta,
              style: t.bodyS.copyWith(color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                Text(formatAmountShort(s.total), style: t.numL),
                const SizedBox(width: AppSpacing.s3),
                Expanded(child: PaidBar(basisPoints: s.paidBp)),
                const SizedBox(width: AppSpacing.s2),
                Text(
                  formatPercentWhole(s.paidBp),
                  style: t.numS.copyWith(color: c.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s1),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                s.remaining < 0
                    ? 'переплата ${formatAmount(-s.remaining)}'
                    : 'ост. ${formatAmount(s.remaining)}',
                key: Key('project-remaining-${project.id}'),
                style: t.numM.copyWith(
                  color: s.remaining > 0 ? c.textPrimary : c.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Десктопная таблица проектов (02, 5.4.1): проект, заказчик, сумма,
/// оплачено (бар и доля), остаток, статус, срок; внизу итог по списку.
class ProjectTable extends ConsumerWidget {
  const ProjectTable({required this.data, required this.projects, super.key});

  final WorkData data;
  final List<WorkProject> projects;

  static const _flex = [30, 18, 14, 22, 14, 16, 10];

  Widget _cell(int i, Widget child, {bool right = false}) => Expanded(
    flex: _flex[i],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
      child: Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final running = {
      for (final r in ref.watch(runningTimersProvider)) r.entry.projectId,
    };
    var total = 0;
    var received = 0;
    for (final p in projects) {
      final s = data.summaryOf(p.id);
      total += s.total;
      received += s.received;
    }
    final header = t.overline.copyWith(color: c.textSecondary);
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
      child: Column(
        key: const Key('project-table'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s4,
              vertical: AppSpacing.s2,
            ),
            child: Row(
              children: [
                _cell(0, Text('ПРОЕКТ', style: header)),
                _cell(1, Text('ЗАКАЗЧИК', style: header)),
                _cell(2, Text('СУММА', style: header), right: true),
                _cell(3, Text('ОПЛАЧЕНО', style: header)),
                _cell(4, Text('ОСТАТОК', style: header), right: true),
                _cell(5, Text('СТАТУС', style: header)),
                _cell(6, Text('СРОК', style: header)),
              ],
            ),
          ),
          Divider(height: 1, color: c.borderSubtle),
          for (final p in projects) _row(context, p, running.contains(p.id)),
          Divider(height: 1, color: c.borderDefault),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s4,
              vertical: AppSpacing.s3,
            ),
            child: Row(
              children: [
                _cell(0, Text('ИТОГО', style: header)),
                _cell(1, const SizedBox.shrink()),
                _cell(2, Text(formatAmount(total), style: t.numM), right: true),
                _cell(
                  3,
                  Text(
                    formatPercentBp(paidBasisPoints(received, total)),
                    style: t.numM,
                  ),
                ),
                _cell(
                  4,
                  Text(formatAmount(total - received), style: t.numM),
                  right: true,
                ),
                _cell(5, const SizedBox.shrink()),
                _cell(6, const SizedBox.shrink()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, WorkProject p, bool timerRunning) {
    final c = context.colors;
    final t = context.text;
    final s = data.summaryOf(p.id);
    return InkWell(
      key: Key('project-${p.id}'),
      onTap: () => openProject(context, p.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            _cell(
              0,
              Row(
                children: [
                  if (timerRunning) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                  ],
                  Flexible(
                    child: Text(
                      p.title,
                      style: t.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            _cell(
              1,
              Text(
                data.clientOf(p)?.name ?? '—',
                style: t.body.copyWith(color: c.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _cell(2, Text(formatAmount(s.total), style: t.numM), right: true),
            _cell(
              3,
              Row(
                children: [
                  Expanded(child: PaidBar(basisPoints: s.paidBp)),
                  const SizedBox(width: AppSpacing.s2),
                  SizedBox(
                    width: 52,
                    child: Text(
                      formatPercentWhole(s.paidBp),
                      style: t.numS.copyWith(color: c.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            _cell(
              4,
              Text(
                formatAmount(s.remaining),
                key: Key('project-remaining-${p.id}'),
                style: t.numM,
              ),
              right: true,
            ),
            _cell(
              5,
              StatusPill(
                label: p.effectiveStatus.label,
                tone: projectTone(p.effectiveStatus),
              ),
            ),
            _cell(
              6,
              Text(
                formatDateText(p.deadlineDate, data.now),
                style: t.caption.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
