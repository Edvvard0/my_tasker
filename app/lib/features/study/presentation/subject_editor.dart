import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает редактор предмета: [subjectId] — правка, иначе создание в
/// семестре [semesterId].
Future<String?> showSubjectEditor(
  BuildContext context, {
  String? subjectId,
  String? semesterId,
}) => showEditorSheet<String>(
  context,
  builder: (_) => SubjectEditor(subjectId: subjectId, semesterId: semesterId),
);

/// Редактор предмета: название, ФИО преподавателя, аудитория «к1 28»,
/// лимит пропусков, заметка; архив и удаление (spec 1.2).
class SubjectEditor extends ConsumerStatefulWidget {
  const SubjectEditor({this.subjectId, this.semesterId, super.key})
    : assert(
        subjectId != null || semesterId != null,
        'Нужен предмет или семестр',
      );

  final String? subjectId;
  final String? semesterId;

  @override
  ConsumerState<SubjectEditor> createState() => _SubjectEditorState();
}

class _SubjectEditorState extends ConsumerState<SubjectEditor> {
  final _name = TextEditingController();
  final _teacher = TextEditingController();
  final _room = TextEditingController();
  final _limit = TextEditingController();
  final _note = TextEditingController();
  bool _loading = true;
  bool _missing = false;
  Subject? _original;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.subjectId == null;

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
    _name.dispose();
    _teacher.dispose();
    _room.dispose();
    _limit.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await ref
        .read(studyRepositoryProvider)
        .getSubject(widget.subjectId!);
    if (!mounted) return;
    if (s == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _original = s;
      _name.text = s.name;
      _teacher.text = s.teacher ?? '';
      _room.text = formatRoom(s.building, s.room);
      _limit.text = s.absenceLimit?.toString() ?? '';
      _note.text = s.note ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final roomProblem = RoomTextField.roomFieldProblem(_room);
    final limitText = _limit.text.trim();
    final limit = limitText.isEmpty ? null : int.tryParse(limitText);
    final problem =
        roomProblem ??
        (limitText.isNotEmpty && limit == null
            ? 'Лимит пропусков — целое число'
            : null);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final room = RoomTextField.value(_room);
    final repo = ref.read(studyRepositoryProvider);
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final draft = Subject(
        id: _original?.id ?? repo.newId(),
        semesterId: _original?.semesterId ?? widget.semesterId!,
        name: _name.text,
        teacher: _teacher.text,
        building: room.building,
        room: room.room,
        absenceLimit: limit,
        note: _note.text,
        archived: _original?.archived ?? false,
      );
      if (_isNew) {
        await repo.createSubject(draft);
      } else {
        await repo.updateSubject(draft);
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

  Future<void> _archive() async {
    final s = _original;
    if (s == null) return;
    await ref
        .read(studyRepositoryProvider)
        .setSubjectArchived(s.id, archived: !s.archived);
    if (mounted) Navigator.of(context).pop(s.id);
  }

  Future<void> _delete() async {
    final s = _original;
    if (s == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить «${s.name}»?',
      message:
          'Пары предмета (с их отметками посещаемости), долги и документы '
          'уйдут в корзину на 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await ref.read(studyRepositoryProvider).deleteSubject(s.id);
    if (mounted) Navigator.of(context).pop();
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
          const SheetHeader(title: 'Предмет'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Предмет не найден: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый предмет' : 'Предмет'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('subject-name'),
                      controller: _name,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Например, Математический анализ',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Преподаватель',
                    child: FormTextField(
                      key: const Key('subject-teacher'),
                      controller: _teacher,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'ФИО преподавателя',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Аудитория (корпус и кабинет)',
                    child: KeyedSubtree(
                      key: const Key('subject-room'),
                      child: RoomTextField(controller: _room),
                    ),
                  ),
                  FormBlock(
                    label: 'Лимит пропусков',
                    child: FormTextField(
                      key: const Key('subject-limit'),
                      controller: _limit,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        hintText: 'Не считать лимит',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Заметка',
                    child: FormTextField(
                      key: const Key('subject-note'),
                      controller: _note,
                      minLines: 2,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        hintText: 'Что важно помнить о предмете',
                      ),
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('subject-error')),
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
                if (!_isNew) ...[
                  TextButton(
                    key: const Key('subject-archive'),
                    onPressed: _archive,
                    child: Text(
                      (_original?.archived ?? false) ? 'Вернуть' : 'В архив',
                    ),
                  ),
                  TextButton(
                    key: const Key('subject-delete'),
                    onPressed: _delete,
                    child: Text('Удалить', style: TextStyle(color: c.danger)),
                  ),
                ],
                const Spacer(),
                FilledButton(
                  key: const Key('subject-save'),
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
