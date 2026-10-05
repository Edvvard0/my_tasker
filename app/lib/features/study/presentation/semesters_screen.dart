import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/presentation/semester_editor.dart';
import 'package:my_tasker/features/study/presentation/study_body.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show WorkSectionHeader;

/// «Семестры»: идущие и архив. Архивный семестр в расписание, пропуски и
/// напоминания не входит; из архива его можно вернуть.
class SemestersScreen extends ConsumerWidget {
  const SemestersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('semesters-screen'),
      title: 'Семестры',
      parentLabel: 'Учёба',
      onBack: () => studyBack(context),
      actions: [
        IconButton(
          key: const Key('semesters-add'),
          tooltip: 'Новый семестр',
          onPressed: () => showSemesterEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: StudyBody(
        builder: (context, data) {
          if (data.semesters.isEmpty) {
            return EmptyState(
              key: const Key('semesters-empty'),
              icon: LucideIcons.graduationCap,
              title: 'Семестров пока нет',
              message: 'Добавьте первый семестр.',
              action: FilledButton(
                onPressed: () => showSemesterEditor(context),
                child: const Text('Добавить семестр'),
              ),
            );
          }
          final live = data.liveSemesters;
          final archived = [
            for (final s in data.semesters)
              if (s.archived) s,
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (live.isNotEmpty)
                for (final s in live) _SemesterCard(semester: s, data: data),
              if (archived.isNotEmpty) ...[
                const WorkSectionHeader(title: 'Архив'),
                for (final s in archived)
                  _SemesterCard(semester: s, data: data),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SemesterCard extends ConsumerWidget {
  const _SemesterCard({required this.semester, required this.data});

  final Semester semester;
  final StudyData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final subjects = data.subjectsOf(semester.id).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: AppCard(
        key: Key('semester-card-${semester.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(semester.name, style: t.h3),
            const SizedBox(height: 2),
            Text(
              '${dateLong(semester.startDate)} – ${dateLong(semester.endDate)} · '
              'предметов: $subjects',
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: AppSpacing.s2,
              children: [
                TextButton(
                  key: Key('semester-edit-${semester.id}'),
                  onPressed: () =>
                      showSemesterEditor(context, semesterId: semester.id),
                  child: const Text('Изменить'),
                ),
                TextButton(
                  key: Key('semester-archive-${semester.id}'),
                  onPressed: () => ref
                      .read(studyRepositoryProvider)
                      .setSemesterArchived(
                        semester.id,
                        archived: !semester.archived,
                      ),
                  child: Text(
                    semester.archived ? 'Вернуть из архива' : 'В архив',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
