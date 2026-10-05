import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает редактор долга: [debtId] — правка, иначе создание в предмете
/// [subjectId]. Возвращает `id` долга.
Future<String?> showDebtEditor(
  BuildContext context, {
  String? debtId,
  String? subjectId,
}) => showEditorSheet<String>(
  context,
  builder: (_) => DebtEditor(debtId: debtId, subjectId: subjectId),
);

String _titleHint(DebtKind kind) => switch (kind) {
  DebtKind.lab => 'Например, ЛР 3',
  DebtKind.practice => 'Например, Практическая 5',
  DebtKind.rgr => 'Например, РГР 1',
  DebtKind.coursework => 'Например, Курсовая работа',
  DebtKind.credit => 'Например, Зачёт',
  DebtKind.exam => 'Например, Экзамен',
  DebtKind.other => 'Название',
};

/// Редактор долга: вид, номер или название («ЛР 3»), статус, срок, заметка
/// (spec 1.8). Вложения и «создать задачу» — на карточке долга.
class DebtEditor extends ConsumerStatefulWidget {
  const DebtEditor({this.debtId, this.subjectId, super.key})
    : assert(debtId != null || subjectId != null, 'Нужен долг или предмет');

  final String? debtId;
  final String? subjectId;

  @override
  ConsumerState<DebtEditor> createState() => _DebtEditorState();
}

class _DebtEditorState extends ConsumerState<DebtEditor> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  bool _loading = true;
  bool _missing = false;
  StudyDebt? _original;
  DebtKind _kind = DebtKind.lab;
  DebtStatus _status = DebtStatus.open;
  DateTime? _due;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.debtId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await ref.read(studyRepositoryProvider).getDebt(widget.debtId!);
    if (!mounted) return;
    if (d == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _original = d;
      _title.text = d.title;
      _note.text = d.note ?? '';
      _kind = d.kind;
      _status = d.status;
      _due = d.dueDate == null ? null : parseDate(d.dueDate!);
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final repo = ref.read(studyRepositoryProvider);
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final today = formatDate(ref.read(todayProvider));
      final base =
          _original ??
          StudyDebt(id: repo.newId(), subjectId: widget.subjectId!, title: '');
      final draft = base.copyWith(
        kind: _kind,
        title: _title.text,
        status: _status,
        dueDate: _due == null ? null : formatDate(_due!),
        doneDate: _status == DebtStatus.open ? null : (base.doneDate ?? today),
        note: _note.text,
      );
      if (_isNew) {
        await repo.createDebt(draft);
      } else {
        await repo.updateDebt(draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop(draft.id);
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    final d = _original;
    if (d == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить «${d.title}»?',
      message: 'Долг и его вложения уйдут в корзину на 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await ref.read(studyRepositoryProvider).deleteDebt(d.id);
    if (mounted) Navigator.of(context).pop('deleted');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_missing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Долг'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Долг не найден: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = ref.watch(todayProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый долг' : 'Долг'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Вид',
                    child: ChipRow(
                      children: [
                        for (final k in DebtKind.values)
                          FilterPill(
                            key: Key('debt-kind-${k.wire}'),
                            label: k.label,
                            selected: _kind == k,
                            onTap: () => setState(() => _kind = k),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Номер или название',
                    child: FormTextField(
                      key: const Key('debt-title'),
                      controller: _title,
                      autofocus: _isNew,
                      decoration: InputDecoration(hintText: _titleHint(_kind)),
                    ),
                  ),
                  FormBlock(
                    label: 'Статус',
                    child: ChipRow(
                      children: [
                        for (final s in DebtStatus.values)
                          FilterPill(
                            key: Key('debt-status-${s.wire}'),
                            label: s.label,
                            selected: _status == s,
                            onTap: () => setState(() => _status = s),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Срок сдачи',
                    child: DateChoiceRow(
                      keyPrefix: 'debt-due',
                      today: today,
                      value: _due,
                      allowNone: true,
                      noneLabel: 'Без срока',
                      onChanged: (d) => setState(() => _due = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Заметка',
                    child: FormTextField(
                      key: const Key('debt-note'),
                      controller: _note,
                      minLines: 2,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        hintText: 'Что нужно сделать, требования, ссылки',
                      ),
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('debt-error')),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s6,
              AppSpacing.s2,
              AppSpacing.s6,
              AppSpacing.s4,
            ),
            child: Row(
              children: [
                if (!_isNew)
                  TextButton(
                    key: const Key('debt-delete'),
                    onPressed: _delete,
                    child: Text('Удалить', style: TextStyle(color: c.danger)),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('debt-save'),
                  onPressed: _saving ? null : _save,
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
