import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/shell/sections_screen.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/presentation/lesson_sheet.dart';
import 'package:my_tasker/features/study/presentation/semester_editor.dart';
import 'package:my_tasker/features/study/presentation/study_body.dart';
import 'package:my_tasker/features/study/presentation/study_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show KpiRow, KpiTile, WorkLinkRow, WorkSectionHeader;

/// «Учёба»: сегодняшние занятия, пропуски и долги плитками, переходы в
/// «Предметы», «Расписание», «Редактор расписания», «Пропуски» и
/// «Семестры» (docs/briefs/stage-7.md).
class StudyScreen extends ConsumerWidget {
  const StudyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('study-overview'),
      title: 'Учёба',
      onBack: backToSections(context),
      actions: [
        IconButton(
          key: const Key('study-add-semester'),
          tooltip: 'Новый семестр',
          onPressed: () => showSemesterEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: StudyBody(builder: (context, data) => _StudyOverview(data: data)),
    );
  }
}

class _StudyOverview extends ConsumerWidget {
  const _StudyOverview({required this.data});

  final StudyData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semester = data.currentSemester;
    if (semester == null) {
      return EmptyState(
        key: const Key('study-empty'),
        icon: LucideIcons.graduationCap,
        title: 'Семестра пока нет',
        message:
            'Заведите семестр: предметы, расписание, пропуски и долги будут '
            'в одном месте.',
        action: FilledButton(
          key: const Key('study-empty-add'),
          onPressed: () => showSemesterEditor(context),
          child: const Text('Добавить семестр'),
        ),
      );
    }
    final today = data.dayOf(data.today);
    final subjects = data.subjectsOf(semester.id);
    var absent = 0;
    var near = 0;
    for (final s in subjects) {
      final a = data.attendance[s.id];
      if (a == null) continue;
      absent += a.absent;
      if (a.state == AttendanceState.near ||
          a.state == AttendanceState.reached ||
          a.state == AttendanceState.over) {
        near++;
      }
    }
    final openDebts = [
      for (final d in data.openDebts)
        if (data.subjectById[d.subjectId]?.semesterId == semester.id) d,
    ];
    final overdue = openDebts.where((d) => d.isOverdue(data.today)).length;
    final week = today.cycleWeek == null
        ? null
        : semester.weekLabel(today.cycleWeek!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KpiRow(
          tiles: [
            KpiTile(
              key: const Key('kpi-absences'),
              label: 'Пропуски',
              value: '$absent',
              caption: near == 0
                  ? 'лимиты в порядке'
                  : 'близко к лимиту: $near',
              onTap: () => context.push('/study/stats'),
            ),
            KpiTile(
              key: const Key('kpi-debts'),
              label: 'Долги',
              value: '${openDebts.length}',
              caption: overdue == 0 ? 'просрочек нет' : 'просрочено $overdue',
              onTap: () => context.push('/study/subjects'),
            ),
            KpiTile(
              key: const Key('kpi-week'),
              label: 'Неделя',
              value: week ?? '—',
              caption: semester.name,
              onTap: () => context.push('/study/schedule'),
            ),
          ],
        ),
        WorkSectionHeader(
          title: 'Сегодня',
          trailing: TextButton(
            key: const Key('study-open-schedule'),
            onPressed: () => context.push('/study/schedule'),
            child: const Text('Расписание'),
          ),
        ),
        DayHeader(day: today, weekLabel: week),
        DayNote(day: today),
        AppCard(
          padding: EdgeInsets.zero,
          child: today.lessons.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  child: Text(
                    switch (today.kind) {
                      DayKind.holiday => 'Праздник: занятий нет.',
                      DayKind.noSemester => 'Сегодня вне семестра.',
                      _ => 'Занятий сегодня нет.',
                    },
                    key: const Key('study-today-empty'),
                    style: context.text.bodyS.copyWith(
                      color: context.colors.textSecondary,
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (final l in today.lessons)
                      LessonTile(
                        key: Key('today-${l.key}'),
                        lesson: l,
                        mark: markOf(data, l),
                        onTap: () => showLessonSheet(
                          context,
                          date: data.today,
                          lessonKey: l.key,
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.s3),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              WorkLinkRow(
                key: const Key('study-subjects-link'),
                icon: LucideIcons.bookOpen,
                label: 'Предметы и долги',
                trailingText: subjects.isEmpty ? null : '${subjects.length}',
                onTap: () => context.push('/study/subjects'),
              ),
              WorkLinkRow(
                key: const Key('study-schedule-link'),
                icon: LucideIcons.calendarDays,
                label: 'Расписание',
                onTap: () => context.push('/study/schedule'),
              ),
              WorkLinkRow(
                key: const Key('study-editor-link'),
                icon: LucideIcons.slidersHorizontal,
                label: 'Редактор расписания',
                onTap: () => context.push('/study/schedule/edit'),
              ),
              WorkLinkRow(
                key: const Key('study-stats-link'),
                icon: LucideIcons.chartColumn,
                label: 'Пропуски',
                trailingText: absent == 0 ? null : '$absent',
                onTap: () => context.push('/study/stats'),
              ),
              WorkLinkRow(
                key: const Key('study-semesters-link'),
                icon: LucideIcons.archive,
                label: 'Семестры и архив',
                onTap: () => context.push('/study/semesters'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
