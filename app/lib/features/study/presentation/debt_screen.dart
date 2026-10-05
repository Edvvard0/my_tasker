import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/presentation/attachment_widgets.dart';
import 'package:my_tasker/features/study/presentation/debt_editor.dart';
import 'package:my_tasker/features/study/presentation/study_body.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/study/presentation/study_widgets.dart';
import 'package:my_tasker/features/study/presentation/subject_screen.dart'
    show debtTone;
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show WorkSectionHeader;

/// Карточка долга: вид, название, статус, срок, заметка, «создать
/// задачу» (задача Этапа 2; ссылка хранится на стороне долга) и вложения —
/// фото заданий и документы.
class DebtScreen extends ConsumerWidget {
  const DebtScreen({required this.debtId, super.key});

  final String debtId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(studyDataProvider).value;
    final debt = data?.debtById[debtId];
    final subject = debt == null ? null : data?.subjectById[debt.subjectId];
    return ScreenScaffold(
      key: const Key('debt-screen'),
      title: debt?.title ?? 'Долг',
      parentLabel: subject?.name ?? 'Предмет',
      onBack: () => studyBack(context),
      actions: [
        if (debt != null)
          IconButton(
            key: const Key('debt-edit'),
            tooltip: 'Изменить долг',
            onPressed: () async {
              final result = await showDebtEditor(context, debtId: debtId);
              if (result == 'deleted' && context.mounted) studyBack(context);
            },
            icon: const Icon(LucideIcons.pencil, size: 22),
          ),
      ],
      child: StudyBody(
        builder: (context, data) {
          final d = data.debtById[debtId];
          if (d == null) {
            return const EmptyState(
              key: Key('debt-missing'),
              icon: LucideIcons.listChecks,
              title: 'Долг не найден',
              message: 'Возможно, его удалили на другом устройстве.',
            );
          }
          return _DebtBody(debt: d, data: data);
        },
      ),
    );
  }
}

class _DebtBody extends ConsumerStatefulWidget {
  const _DebtBody({required this.debt, required this.data});

  final StudyDebt debt;
  final StudyData data;

  @override
  ConsumerState<_DebtBody> createState() => _DebtBodyState();
}

class _DebtBodyState extends ConsumerState<_DebtBody> {
  late final TextEditingController _note = TextEditingController(
    text: widget.debt.note ?? '',
  );
  bool _dirty = false;
  bool _creatingTask = false;

  @override
  void didUpdateWidget(covariant _DebtBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Заметка пришла с другого устройства, пока поле не тронуто.
    if (!_dirty && widget.debt.note != oldWidget.debt.note) {
      _note.text = widget.debt.note ?? '';
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _saveNote() async {
    final repo = ref.read(studyRepositoryProvider);
    try {
      await repo.updateDebt(widget.debt.copyWith(note: _note.text));
      if (mounted) setState(() => _dirty = false);
    } on ValidationError catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _createTask() async {
    if (_creatingTask) return;
    setState(() => _creatingTask = true);
    try {
      final subject = widget.data.subjectById[widget.debt.subjectId];
      final id = await ref
          .read(studyRepositoryProvider)
          .createTaskForDebt(
            widget.debt.id,
            subjectName: subject?.name ?? 'предмет',
          );
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('Задача создана')));
      unawaited(showTaskEditor(context, taskId: id));
    } finally {
      if (mounted) setState(() => _creatingTask = false);
    }
  }

  Future<void> _openTask(String taskId) async {
    final alive = await ref.read(studyRepositoryProvider).hasLiveTask(taskId);
    if (!mounted) return;
    if (!alive) {
      // Задачу удалили: ссылка осталась «висеть» — предлагаем создать заново.
      await ref
          .read(studyRepositoryProvider)
          .updateDebt(widget.debt.copyWith(taskId: null));
      return;
    }
    await showTaskEditor(context, taskId: taskId);
  }

  @override
  Widget build(BuildContext context) {
    final debt = widget.debt;
    final data = widget.data;
    final c = context.colors;
    final t = context.text;
    final repo = ref.read(studyRepositoryProvider);
    final due = dueText(debt, data.today);
    final linkedTask = debt.taskId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          key: const Key('debt-header'),
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
              const SizedBox(height: AppSpacing.s2),
              ChipRow(
                children: [
                  for (final s in DebtStatus.values)
                    FilterPill(
                      key: Key('debt-set-${s.wire}'),
                      label: s.label,
                      selected: debt.status == s,
                      onTap: () =>
                          repo.setDebtStatus(debt.id, s, today: data.today),
                    ),
                ],
              ),
              if (due.isNotEmpty || debt.doneDate != null) ...[
                const SizedBox(height: AppSpacing.s3),
                Wrap(
                  spacing: AppSpacing.s3,
                  children: [
                    if (due.isNotEmpty)
                      MetaInline(
                        key: const Key('debt-due-text'),
                        icon: LucideIcons.calendar,
                        text: due,
                        strong: debt.isOverdue(data.today),
                      ),
                    if (debt.doneDate != null && !debt.isOpen)
                      MetaInline(
                        icon: LucideIcons.check,
                        text: 'Сдана ${dateLabel(debt.doneDate!)}',
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const WorkSectionHeader(title: 'Заметка'),
        FormTextField(
          key: const Key('debt-note-field'),
          controller: _note,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          onChanged: (_) => setState(() => _dirty = true),
          decoration: const InputDecoration(
            hintText: 'Что нужно сделать, требования, ссылки',
          ),
        ),
        if (_dirty)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s2),
              child: FilledButton(
                key: const Key('debt-note-save'),
                onPressed: _saveNote,
                child: const Text('Сохранить заметку'),
              ),
            ),
          ),
        const WorkSectionHeader(title: 'Задача'),
        if (linkedTask != null)
          ListCard(
            child: ListTile(
              key: const Key('debt-open-task'),
              leading: Icon(LucideIcons.listTodo, color: c.textSecondary),
              title: const Text('Задача создана'),
              subtitle: const Text('Открыть задачу'),
              trailing: Icon(
                LucideIcons.chevronRight,
                size: 18,
                color: c.textTertiary,
              ),
              onTap: () => _openTask(linkedTask),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              key: const Key('debt-create-task'),
              onPressed: _creatingTask ? null : _createTask,
              icon: const Icon(LucideIcons.listPlus, size: 18),
              label: const Text('Создать задачу'),
            ),
          ),
        const WorkSectionHeader(title: 'Фото заданий и документы'),
        AttachmentSection(debtId: debt.id),
        const SizedBox(height: AppSpacing.s4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('debt-open-subject'),
            onPressed: () => context.push('/study/subjects/${debt.subjectId}'),
            child: const Text('К предмету'),
          ),
        ),
      ],
    );
  }
}
