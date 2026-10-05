import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/presentation/study_body.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';

/// «Пропуски»: счётчики по предметам текущего семестра (был, пропустил,
/// отменено, не отмечено), лимит и предупреждение о его приближении.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('stats-screen'),
      title: 'Пропуски',
      parentLabel: 'Учёба',
      onBack: () => studyBack(context),
      child: StudyBody(
        builder: (context, data) {
          final semester = data.currentSemester;
          final subjects = semester == null
              ? const <Subject>[]
              : data.subjectsOf(semester.id);
          if (subjects.isEmpty) {
            return const EmptyState(
              key: Key('stats-empty'),
              icon: LucideIcons.chartColumn,
              title: 'Считать пока нечего',
              message:
                  'Добавьте предметы и пары: пропуски считаются по '
                  'отметкам «Был / Пропустил / Отменена».',
            );
          }
          final rows = [
            for (final s in subjects)
              if (data.attendance[s.id] != null) (s, data.attendance[s.id]!),
          ]..sort((a, b) => b.$2.absent.compareTo(a.$2.absent));
          final total = rows.fold<int>(0, (n, r) => n + r.$2.absent);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${semester!.name}: всего ${absencesText(total)}',
                key: const Key('stats-total'),
                style: context.text.bodyS.copyWith(
                  color: context.colors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              for (final (subject, a) in rows) ...[
                InkWell(
                  key: Key('stats-row-${subject.id}'),
                  borderRadius: AppRadii.borderL,
                  onTap: () => context.push('/study/subjects/${subject.id}'),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(subject.name, style: context.text.h3),
                            ),
                            StatusPill(
                              label: absencesLimitText(a),
                              tone: limitTone(a.state),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.s1),
                        Text(
                          limitStateText(a),
                          style: context.text.bodyS.copyWith(
                            color: a.state == AttendanceState.over
                                ? context.colors.danger
                                : context.colors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s1),
                        Text(
                          'Был ${a.present} · пропустил ${a.absent} · '
                          'отменено ${a.cancelled} · не отмечено ${a.unmarked}',
                          style: context.text.caption.copyWith(
                            color: context.colors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
              ],
            ],
          );
        },
      ),
    );
  }
}
