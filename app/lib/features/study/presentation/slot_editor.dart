import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает редактор пары: [slotId] — правка (для всех таких пар), иначе
/// создание в семестре [semesterId] в день недели [weekday].
Future<String?> showSlotEditor(
  BuildContext context, {
  String? slotId,
  String? semesterId,
  int? weekday,
}) => showEditorSheet<String>(
  context,
  builder: (_) =>
      SlotEditor(slotId: slotId, semesterId: semesterId, weekday: weekday),
);

/// Номера пар из сетки звонков семестра; без сетки — 1…6.
List<int> bellNumbers(StudyData data, String semesterId) {
  final numbers = {for (final b in data.bellsOf(semesterId)) b.number};
  return numbers.isEmpty ? [1, 2, 3, 4, 5, 6] : (numbers.toList()..sort());
}

/// Редактор пары расписания (spec 1.4): предмет или своё название, тип,
/// день недели, неделя цикла, номер пары по сетке или своё время,
/// аудитория. Правка действует на **все** такие пары; на одну дату — через
/// «Изменить только на эту дату».
class SlotEditor extends ConsumerStatefulWidget {
  const SlotEditor({this.slotId, this.semesterId, this.weekday, super.key})
    : assert(slotId != null || semesterId != null, 'Нужна пара или семестр');

  final String? slotId;
  final String? semesterId;
  final int? weekday;

  @override
  ConsumerState<SlotEditor> createState() => _SlotEditorState();
}

class _SlotEditorState extends ConsumerState<SlotEditor> {
  final _title = TextEditingController();
  final _room = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  bool _loading = true;
  bool _missing = false;
  ClassSlot? _original;
  String? _subjectId;
  LessonKind _kind = LessonKind.lecture;
  int _weekday = 1;
  int? _cycleWeek;
  int? _number = 1;
  bool _ownTime = false;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.slotId == null;

  @override
  void initState() {
    super.initState();
    _weekday = widget.weekday ?? 1;
    if (_isNew) {
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _room.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await ref.read(studyRepositoryProvider).getSlot(widget.slotId!);
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
      _subjectId = s.subjectId;
      _title.text = s.title ?? '';
      _kind = s.kind;
      _weekday = s.weekday;
      _cycleWeek = s.cycleWeek;
      _number = s.number;
      _ownTime = s.startTime != null;
      _start.text = s.startTime ?? '';
      _end.text = s.endTime ?? '';
      _room.text = formatRoom(s.building, s.room);
      _loading = false;
    });
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
    if (_ownTime) {
      start = normalizeTime(_start.text);
      end = normalizeTime(_end.text);
      if (start == null || end == null) {
        setState(() => _error = 'Время — в формате ЧЧ:ММ, например 08:30');
        return;
      }
    }
    final room = RoomTextField.value(_room);
    final repo = ref.read(studyRepositoryProvider);
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final draft = ClassSlot(
        id: _original?.id ?? repo.newId(),
        semesterId: _original?.semesterId ?? widget.semesterId!,
        subjectId: _subjectId,
        title: _title.text,
        weekday: _weekday,
        number: _ownTime ? null : _number,
        startTime: start,
        endTime: end,
        kind: _kind,
        building: room.building,
        room: room.room,
        cycleWeek: _cycleWeek,
      );
      if (_isNew) {
        await repo.createSlot(draft);
      } else {
        await repo.updateSlot(draft);
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
    final s = _original;
    if (s == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить пару?',
      message:
          'Вместе с парой удалятся её изменения на даты и отметки '
          'посещаемости — счётчики пропусков пересчитаются. 30 дней это '
          'можно отменить в корзине.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await ref.read(studyRepositoryProvider).deleteSlot(s.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final data = ref.watch(studyDataProvider).value;
    if (_loading || data == null) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final semesterId = _original?.semesterId ?? widget.semesterId!;
    final semester = data.semesterById[semesterId];
    if (_missing || semester == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Пара'),
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
    final subjects = data.subjectsOf(semesterId);
    final bells = {for (final b in data.bellsOf(semesterId)) b.number: b};
    final numbers = bellNumbers(data, semesterId);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новая пара' : 'Пара'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Предмет',
                    child: ChipRow(
                      children: [
                        FilterPill(
                          key: const Key('slot-subject-none'),
                          label: 'Своё название',
                          selected: _subjectId == null,
                          onTap: () => setState(() => _subjectId = null),
                        ),
                        for (final s in subjects)
                          FilterPill(
                            key: Key('slot-subject-${s.id}'),
                            label: s.name,
                            selected: _subjectId == s.id,
                            onTap: () => setState(() => _subjectId = s.id),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: _subjectId == null
                        ? 'Название'
                        : 'Название (если отличается от предмета)',
                    child: FormTextField(
                      key: const Key('slot-title'),
                      controller: _title,
                      decoration: const InputDecoration(
                        hintText: 'Например, Подготовка к олимпиаде',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Тип',
                    child: LessonKindChips(
                      keyPrefix: 'slot-kind',
                      value: _kind,
                      onChanged: (k) =>
                          setState(() => _kind = k ?? LessonKind.other),
                    ),
                  ),
                  FormBlock(
                    label: 'День недели',
                    child: WeekdayChips(
                      keyPrefix: 'slot-weekday',
                      value: _weekday,
                      onChanged: (d) => setState(() => _weekday = d),
                    ),
                  ),
                  if (semester.cycleLength > 1)
                    FormBlock(
                      label: 'Неделя',
                      child: CycleWeekChips(
                        keyPrefix: 'slot-cycle',
                        semester: semester,
                        value: _cycleWeek,
                        onChanged: (w) => setState(() => _cycleWeek = w),
                      ),
                    ),
                  FormBlock(
                    label: 'Время',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ChipRow(
                          children: [
                            FilterPill(
                              key: const Key('slot-time-bell'),
                              label: 'По звонку',
                              selected: !_ownTime,
                              onTap: () => setState(() => _ownTime = false),
                            ),
                            FilterPill(
                              key: const Key('slot-time-own'),
                              label: 'Своё время',
                              selected: _ownTime,
                              onTap: () => setState(() => _ownTime = true),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        if (_ownTime)
                          Row(
                            children: [
                              Expanded(
                                child: KeyedSubtree(
                                  key: const Key('slot-start'),
                                  child: TimeTextField(controller: _start),
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Text('—'),
                              ),
                              Expanded(
                                child: KeyedSubtree(
                                  key: const Key('slot-end'),
                                  child: TimeTextField(
                                    controller: _end,
                                    hint: '10:00',
                                  ),
                                ),
                              ),
                            ],
                          )
                        else
                          ChipRow(
                            children: [
                              for (final n in numbers)
                                FilterPill(
                                  key: Key('slot-number-$n'),
                                  label: bells[n] == null
                                      ? '$n пара'
                                      : '$n · ${bells[n]!.startTime}',
                                  selected: _number == n,
                                  onTap: () => setState(() => _number = n),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Аудитория (пусто — как у предмета)',
                    child: KeyedSubtree(
                      key: const Key('slot-room'),
                      child: RoomTextField(controller: _room),
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('slot-error')),
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
                    key: const Key('slot-delete'),
                    onPressed: _delete,
                    child: Text('Удалить', style: TextStyle(color: c.danger)),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('slot-save'),
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
