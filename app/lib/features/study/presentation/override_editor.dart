import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает изменение пары [slotId] на дату по расписанию [date].
Future<void> showOverrideEditor(
  BuildContext context, {
  required String slotId,
  required String date,
}) => showEditorSheet<void>(
  context,
  builder: (_) => OverrideEditor(slotId: slotId, date: date),
);

/// Изменение пары **только на эту дату** (spec 1.6): отмена, изменение
/// (время, аудитория, предмет, название, тип) или перенос на другую
/// дату. Отменённая пара в пропуски не идёт. Чтобы изменить все такие
/// пары, правят саму пару.
class OverrideEditor extends ConsumerStatefulWidget {
  const OverrideEditor({required this.slotId, required this.date, super.key});

  final String slotId;
  final String date;

  @override
  ConsumerState<OverrideEditor> createState() => _OverrideEditorState();
}

class _OverrideEditorState extends ConsumerState<OverrideEditor> {
  final _title = TextEditingController();
  final _room = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  OverrideAction _action = OverrideAction.cancel;
  String? _subjectId;
  LessonKind? _kind;
  DateTime? _newDate;
  ClassOverride? _existing;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final o = ref
        .read(studyDataProvider)
        .value
        ?.overrides
        .where((x) => x.slotId == widget.slotId && x.date == widget.date)
        .firstOrNull;
    if (o == null) return;
    _existing = o;
    _action = o.action;
    _title.text = o.title ?? '';
    _room.text = formatRoom(o.building, o.room);
    _start.text = o.startTime ?? '';
    _end.text = o.endTime ?? '';
    _subjectId = o.subjectId;
    _kind = o.lessonKind;
    _newDate = o.newDate == null ? null : parseDate(o.newDate!);
  }

  @override
  void dispose() {
    _title.dispose();
    _room.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final roomProblem = RoomTextField.roomFieldProblem(_room);
    if (roomProblem != null) {
      setState(() => _error = roomProblem);
      return;
    }
    String? start;
    String? end;
    if (_action != OverrideAction.cancel &&
        (_start.text.trim().isNotEmpty || _end.text.trim().isNotEmpty)) {
      start = normalizeTime(_start.text);
      end = normalizeTime(_end.text);
      if (start == null || end == null) {
        setState(
          () => _error = 'Время — в формате ЧЧ:ММ; нужны и начало, и конец',
        );
        return;
      }
    }
    if (_action == OverrideAction.move && _newDate == null) {
      setState(() => _error = 'Выберите дату, на которую переносим');
      return;
    }
    if (_action == OverrideAction.move) {
      final slot = ref.read(studyDataProvider).value?.slotById[widget.slotId];
      final semester = slot == null
          ? null
          : ref.read(studyDataProvider).value?.semesterById[slot.semesterId];
      final target = formatDate(_newDate!);
      if (semester != null &&
          (target.compareTo(semester.startDate) < 0 ||
              target.compareTo(semester.endDate) > 0)) {
        setState(
          () => _error =
              'Дата вне семестра «${semester.name}» (с '
              '${dateLabel(semester.startDate)} по '
              '${dateLabel(semester.endDate)}): пара в этот день не будет '
              'показана',
        );
        return;
      }
    }
    final room = RoomTextField.value(_room);
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await ref
          .read(studyRepositoryProvider)
          .saveOverride(
            ClassOverride(
              slotId: widget.slotId,
              date: widget.date,
              action: _action,
              newDate: _newDate == null ? null : formatDate(_newDate!),
              startTime: start,
              endTime: end,
              building: room.building,
              room: room.room,
              subjectId: _subjectId,
              title: _title.text,
              lessonKind: _kind,
            ),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _clear() async {
    await ref
        .read(studyRepositoryProvider)
        .clearOverride(widget.slotId, widget.date);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final today = ref.watch(todayProvider);
    final data = ref.watch(studyDataProvider).value;
    final slot = data?.slotById[widget.slotId];
    if (data == null || slot == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Изменение пары'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Пара не найдена: возможно, её удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final subjects = data.subjectsOf(slot.semesterId);
    final semester = data.semesterById[slot.semesterId];
    final changing = _action != OverrideAction.cancel;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: data.slotTitle(slot)),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormHint(
                    'Только на ${dateLabel(widget.date)}. Чтобы изменить все '
                    'такие пары, правьте саму пару в редакторе расписания.',
                  ),
                  FormBlock(
                    label: 'Что сделать',
                    child: ChipRow(
                      children: [
                        FilterPill(
                          key: const Key('override-action-cancel'),
                          label: 'Отменить пару',
                          selected: _action == OverrideAction.cancel,
                          onTap: () =>
                              setState(() => _action = OverrideAction.cancel),
                        ),
                        FilterPill(
                          key: const Key('override-action-change'),
                          label: 'Изменить',
                          selected: _action == OverrideAction.change,
                          onTap: () =>
                              setState(() => _action = OverrideAction.change),
                        ),
                        FilterPill(
                          key: const Key('override-action-move'),
                          label: 'Перенести',
                          selected: _action == OverrideAction.move,
                          onTap: () =>
                              setState(() => _action = OverrideAction.move),
                        ),
                      ],
                    ),
                  ),
                  if (_action == OverrideAction.cancel)
                    const FormHint(
                      'Отменённая пара остаётся в расписании зачёркнутой и в '
                      'пропуски не идёт.',
                    ),
                  if (_action == OverrideAction.move)
                    FormBlock(
                      label: 'Перенести на дату',
                      child: DateChoiceRow(
                        keyPrefix: 'override-date',
                        today: today,
                        value: _newDate,
                        firstDate: semester == null
                            ? null
                            : parseDate(semester.startDate),
                        lastDate: semester == null
                            ? null
                            : parseDate(semester.endDate),
                        onChanged: (d) => setState(() => _newDate = d),
                      ),
                    ),
                  if (changing) ...[
                    FormBlock(
                      label: 'Новое время (пусто — как по звонку)',
                      child: Row(
                        children: [
                          Expanded(
                            child: KeyedSubtree(
                              key: const Key('override-start'),
                              child: TimeTextField(controller: _start),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('—'),
                          ),
                          Expanded(
                            child: KeyedSubtree(
                              key: const Key('override-end'),
                              child: TimeTextField(
                                controller: _end,
                                hint: '10:00',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    FormBlock(
                      label: 'Аудитория (пусто — как было)',
                      child: KeyedSubtree(
                        key: const Key('override-room'),
                        child: RoomTextField(controller: _room),
                      ),
                    ),
                    FormBlock(
                      label: 'Предмет',
                      child: ChipRow(
                        children: [
                          FilterPill(
                            key: const Key('override-subject-none'),
                            label: 'Как было',
                            selected: _subjectId == null,
                            onTap: () => setState(() => _subjectId = null),
                          ),
                          for (final s in subjects)
                            FilterPill(
                              key: Key('override-subject-${s.id}'),
                              label: s.name,
                              selected: _subjectId == s.id,
                              onTap: () => setState(() => _subjectId = s.id),
                            ),
                        ],
                      ),
                    ),
                    FormBlock(
                      label: 'Название (пусто — как было)',
                      child: FormTextField(
                        key: const Key('override-title'),
                        controller: _title,
                      ),
                    ),
                    FormBlock(
                      label: 'Тип',
                      child: LessonKindChips(
                        keyPrefix: 'override-kind',
                        value: _kind,
                        allowNone: true,
                        onChanged: (k) => setState(() => _kind = k),
                      ),
                    ),
                  ],
                  if (_error != null)
                    FormError(_error!, key: const Key('override-error')),
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
                if (_existing != null)
                  TextButton(
                    key: const Key('override-clear'),
                    onPressed: _clear,
                    child: Text(
                      'Вернуть по расписанию',
                      style: TextStyle(color: c.textSecondary),
                    ),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('override-save'),
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
