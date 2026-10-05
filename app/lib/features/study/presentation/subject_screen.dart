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
import 'package:my_tasker/features/study/presentation/attachment_widgets.dart';
import 'package:my_tasker/features/study/presentation/debt_editor.dart';
import 'package:my_tasker/features/study/presentation/study_body.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/study/presentation/study_widgets.dart';
import 'package:my_tasker/features/study/presentation/subject_editor.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show WorkSectionHeader;

/// Экран предмета: шапка (преподаватель, аудитория «к1 28», пропуски и
/// лимит), долги — **каждая** лабораторная и практическая отдельной
/// карточкой — и документы предмета.
class SubjectScreen extends ConsumerWidget {
  const SubjectScreen({required this.subjectId, super.key});

  final String subjectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subject = ref.watch(studyDataProvider).value?.subjectById[subjectId];
    return ScreenScaffold(
      key: const Key('subject-screen'),
      title: subject?.name ?? 'Предмет',
      parentLabel: 'Предметы',
      onBack: () => studyBack(context),
      actions: [
        if (subject != null)
          IconButton(
            key: const Key('subject-edit'),
            tooltip: 'Изменить предмет',
            onPressed: () => showSubjectEditor(context, subjectId: subjectId),
            icon: const Icon(LucideIcons.pencil, size: 22),
          ),
      ],
      child: StudyBody(
        builder: (context, data) {
          final s = data.subjectById[subjectId];
          if (s == null) {
            return const EmptyState(
              key: Key('subject-missing'),
              icon: LucideIcons.bookOpen,
              title: 'Предмет не найден',
              message: 'Возможно, его удалили на другом устройстве.',
            );
          }
          return _SubjectBody(subject: s, data: data);
        },
      ),
    );
  }
}

class _SubjectBody extends StatelessWidget {
  const _SubjectBody({required this.subject, required this.data});

  final Subject subject;
  final StudyData data;

  @override
  Widget build(BuildContext context) {
    final debts = data.debtsOf(subject.id);
    final open = [
      for (final d in debts)
        if (d.isOpen) d,
    ];
    final closed = [
      for (final d in debts)
        if (!d.isOpen) d,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SubjectHeader(subject: subject, data: data),
        WorkSectionHeader(
          title: 'Долги',
          trailing: TextButton.icon(
            key: const Key('subject-add-debt'),
            onPressed: () => showDebtEditor(context, subjectId: subject.id),
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Добавить'),
          ),
        ),
        if (debts.isEmpty)
          AppCard(
            child: Text(
              'Лабораторных, практических и других долгов нет. Добавьте '
              'долг — у каждой работы будет своя карточка с заметкой, фото '
              'заданий и документами.',
              key: const Key('subject-no-debts'),
              style: context.text.bodyS.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          )
        else ...[
          for (final d in [...open, ...closed]) ...[
            DebtCard(debt: d, data: data),
            const SizedBox(height: AppSpacing.s2),
          ],
        ],
        const WorkSectionHeader(title: 'Документы предмета'),
        AttachmentSection(subjectId: subject.id),
        if ((subject.note ?? '').isNotEmpty) ...[
          const WorkSectionHeader(title: 'Заметка'),
          AppCard(
            child: Text(
              subject.note!,
              key: const Key('subject-note-text'),
              style: context.text.body,
            ),
          ),
        ],
      ],
    );
  }
}

/// Шапка предмета: преподаватель, аудитория, пропуски и лимит.
class SubjectHeader extends StatelessWidget {
  const SubjectHeader({required this.subject, required this.data, super.key});

  final Subject subject;
  final StudyData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final a = data.attendance[subject.id];
    final teacher = (subject.teacher ?? '').isEmpty
        ? 'Преподаватель не указан'
        : subject.teacher!;
    return AppCard(
      key: const Key('subject-header'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.user, size: 18, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  teacher,
                  key: const Key('subject-teacher-text'),
                  style: (subject.teacher ?? '').isEmpty
                      ? t.body.copyWith(color: c.textTertiary)
                      : t.body,
                ),
              ),
              RoomChip(building: subject.building, room: subject.room),
            ],
          ),
          if (a != null) ...[
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                StatusPill(
                  key: const Key('subject-limit-pill'),
                  label: absencesLimitText(a),
                  tone: limitTone(a.state),
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(
                    limitStateText(a),
                    key: const Key('subject-limit-text'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              'Был ${a.present} · пропустил ${a.absent} · отменено '
              '${a.cancelled} · не отмечено ${a.unmarked}',
              key: const Key('subject-counts'),
              style: t.caption.copyWith(color: c.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Тон пилюли статуса долга: монохром, красный — только просрочка.
StatusTone debtTone(StudyDebt debt, String today) {
  if (debt.isOverdue(today)) return StatusTone.danger;
  return switch (debt.status) {
    DebtStatus.open => StatusTone.warning,
    DebtStatus.submitted => StatusTone.success,
    DebtStatus.credited => StatusTone.success,
  };
}

/// Карточка долга на экране предмета: вид и название, статус, срок,
/// вложения. Нажатие открывает карточку долга (заметка, фото, документы).
class DebtCard extends StatelessWidget {
  const DebtCard({required this.debt, required this.data, super.key});

  final StudyDebt debt;
  final StudyData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final files = data.attachmentsOfDebt(debt.id).length;
    final due = dueText(debt, data.today);
    final done = !debt.isOpen;
    return InkWell(
      key: Key('debt-card-${debt.id}'),
      borderRadius: AppRadii.borderL,
      onTap: () => context.push('/study/debts/${debt.id}'),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    debt.kind.label.toUpperCase(),
                    style: t.overline.copyWith(color: c.textSecondary),
                  ),
                ),
                StatusPill(
                  label: debt.isOverdue(data.today)
                      ? 'Просрочена'
                      : debt.status.label,
                  tone: debtTone(debt, data.today),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              debt.title,
              style: t.h3.copyWith(
                color: done ? c.textSecondary : c.textPrimary,
                decoration: done ? TextDecoration.lineThrough : null,
              ),
            ),
            if ((debt.note ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  debt.note!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ),
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: AppSpacing.s3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (due.isNotEmpty)
                  MetaInline(
                    icon: LucideIcons.calendar,
                    text: due,
                    strong: debt.isOverdue(data.today),
                  ),
                if (debt.doneDate != null && done)
                  MetaInline(
                    icon: LucideIcons.check,
                    text: 'Сдана ${dateLabel(debt.doneDate!)}',
                  ),
                if (files > 0)
                  MetaInline(icon: LucideIcons.paperclip, text: '$files'),
                if (debt.taskId != null)
                  const MetaInline(
                    icon: LucideIcons.listTodo,
                    text: 'есть задача',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
