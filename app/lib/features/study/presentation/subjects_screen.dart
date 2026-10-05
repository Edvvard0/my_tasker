import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/presentation/semester_editor.dart';
import 'package:my_tasker/features/study/presentation/study_body.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/study/presentation/study_widgets.dart';
import 'package:my_tasker/features/study/presentation/subject_editor.dart';

/// «Предметы»: список предметов текущего семестра — преподаватель,
/// аудитория, пропуски/лимит и число долгов; по нажатию — экран предмета.
class SubjectsScreen extends ConsumerStatefulWidget {
  const SubjectsScreen({super.key});

  @override
  ConsumerState<SubjectsScreen> createState() => _SubjectsScreenState();
}

class _SubjectsScreenState extends ConsumerState<SubjectsScreen> {
  bool _archive = false;

  @override
  Widget build(BuildContext context) {
    final semester = ref.watch(studyDataProvider).value?.currentSemester;
    return ScreenScaffold(
      key: const Key('subjects-screen'),
      title: 'Предметы',
      parentLabel: 'Учёба',
      onBack: () => studyBack(context),
      actions: [
        if (semester != null)
          IconButton(
            key: const Key('subjects-add'),
            tooltip: 'Новый предмет',
            onPressed: () =>
                showSubjectEditor(context, semesterId: semester.id),
            icon: const Icon(LucideIcons.squarePen, size: 22),
          ),
      ],
      child: StudyBody(
        builder: (context, data) {
          final current = data.currentSemester;
          if (current == null) {
            return EmptyState(
              key: const Key('subjects-no-semester'),
              icon: LucideIcons.graduationCap,
              title: 'Сначала семестр',
              message: 'Предметы относятся к семестру.',
              action: FilledButton(
                onPressed: () => showSemesterEditor(context),
                child: const Text('Добавить семестр'),
              ),
            );
          }
          final subjects = data.subjectsOf(current.id, archived: _archive);
          final hasArchived = data.subjectsOf(current.id, archived: true);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current.name,
                style: context.text.caption.copyWith(
                  color: context.colors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.s2),
              ChipRow(
                children: [
                  FilterPill(
                    key: const Key('subjects-filter-active'),
                    label: 'Предметы',
                    selected: !_archive,
                    onTap: () => setState(() => _archive = false),
                  ),
                  FilterPill(
                    key: const Key('subjects-filter-archive'),
                    label:
                        'Архив${hasArchived.isEmpty ? '' : ' (${hasArchived.length})'}',
                    selected: _archive,
                    onTap: () => setState(() => _archive = true),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              if (subjects.isEmpty)
                EmptyState(
                  key: const Key('subjects-empty'),
                  icon: LucideIcons.bookOpen,
                  title: _archive ? 'Архив пуст' : 'Предметов пока нет',
                  message: _archive
                      ? 'Сюда попадают предметы, отправленные в архив.'
                      : 'Добавьте предметы семестра: преподаватель, '
                            'аудитория, лимит пропусков и долги.',
                  action: _archive
                      ? null
                      : FilledButton(
                          key: const Key('subjects-empty-add'),
                          onPressed: () => showSubjectEditor(
                            context,
                            semesterId: current.id,
                          ),
                          child: const Text('Добавить предмет'),
                        ),
                )
              else
                for (final s in subjects) ...[
                  SubjectCard(subject: s, data: data),
                  const SizedBox(height: AppSpacing.s2),
                ],
            ],
          );
        },
      ),
    );
  }
}

/// Карточка предмета в списке.
class SubjectCard extends StatelessWidget {
  const SubjectCard({required this.subject, required this.data, super.key});

  final Subject subject;
  final StudyData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final attendance = data.attendance[subject.id];
    final debts = data.debtsOf(subject.id);
    final open = debts.where((d) => d.isOpen).length;
    final overdue = debts.where((d) => d.isOverdue(data.today)).length;
    return InkWell(
      key: Key('subject-card-${subject.id}'),
      borderRadius: AppRadii.borderL,
      onTap: () => context.push('/study/subjects/${subject.id}'),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    subject.name,
                    style: t.h3,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                RoomChip(building: subject.building, room: subject.room),
              ],
            ),
            if ((subject.teacher ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  subject.teacher!,
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ),
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (attendance != null)
                  StatusPill(
                    label: absencesLimitText(attendance),
                    tone: limitTone(attendance.state),
                  ),
                MetaInline(
                  icon: LucideIcons.listChecks,
                  text: open == 0
                      ? 'нет долгов'
                      : debtsCountText(open) +
                            (overdue == 0 ? '' : ', просрочено $overdue'),
                  strong: overdue > 0,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
