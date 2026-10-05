import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/domain/study_validation.dart';
import 'package:my_tasker/features/study/presentation/slot_editor.dart'
    show bellNumbers;
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/study/presentation/study_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает редактор особого дня: [ruleId] — правка, иначе создание в
/// семестре [semesterId] (на день недели [weekday] или на дату [date]).
Future<String?> showRuleEditor(
  BuildContext context, {
  required String semesterId,
  String? ruleId,
  int? weekday,
  String? date,
}) => showEditorSheet<String>(
  context,
  builder: (_) => RuleEditor(
    semesterId: semesterId,
    ruleId: ruleId,
    weekday: weekday,
    date: date,
  ),
);

/// Редактор особого дня (spec 1.5): правило на день недели (на весь
/// семестр или только в нечётную/чётную неделю) или на конкретную дату;
/// «обычных пар нет» и свой набор занятий. Например, «по четвергам
/// обычных пар нет, 3 пары — подготовка к олимпиаде». Занятия особых дней
/// не отмечаются и в пропуски не идут.
class RuleEditor extends ConsumerStatefulWidget {
  const RuleEditor({
    required this.semesterId,
    this.ruleId,
    this.weekday,
    this.date,
    super.key,
  });

  final String semesterId;
  final String? ruleId;
  final int? weekday;
  final String? date;

  @override
  ConsumerState<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends ConsumerState<RuleEditor> {
  final _title = TextEditingController();
  bool _missing = false;
  DayRule? _original;
  bool _byDate = false;
  int _weekday = 4;
  int? _cycleWeek;
  DateTime? _date;
  bool _hide = true;
  final List<RuleItem> _items = [];
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.ruleId == null;

  @override
  void initState() {
    super.initState();
    if (widget.date != null) {
      _byDate = true;
      _date = parseDate(widget.date!);
    }
    _weekday = widget.weekday ?? 4;
    final id = widget.ruleId;
    if (id == null) return;
    final r = ref
        .read(studyDataProvider)
        .value
        ?.dayRules
        .where((x) => x.id == id)
        .firstOrNull;
    if (r == null) {
      _missing = true;
      return;
    }
    _original = r;
    _title.text = r.title;
    _byDate = r.onDate != null;
    _date = r.onDate == null ? null : parseDate(r.onDate!);
    _weekday = r.weekday ?? 4;
    _cycleWeek = r.cycleWeek;
    _hide = r.hideRegular;
    _items.addAll(r.items);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  String _nextKey() {
    for (var i = 1; i <= 99; i++) {
      final key = 'i$i';
      if (!_items.any((x) => x.key == key)) return key;
    }
    return 'i${_items.length + 1}';
  }

  Future<void> _editItem({RuleItem? item, int? index}) async {
    final semester = ref.read(studyDataProvider).value;
    final numbers = semester == null
        ? const [1, 2, 3, 4, 5, 6]
        : bellNumbers(semester, widget.semesterId);
    final result = await showDialog<RuleItem>(
      context: context,
      builder: (_) => _ItemDialog(
        initial: item,
        itemKey: _nextKey(),
        defaultTitle: _title.text,
        numbers: numbers,
        defaultNumber: _items.length + 1,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _items.add(result);
      } else {
        _items[index] = result;
      }
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
      final rule = DayRule(
        id: _original?.id ?? '',
        semesterId: widget.semesterId,
        weekday: _byDate ? null : _weekday,
        onDate: _byDate ? (_date == null ? null : formatDate(_date!)) : null,
        cycleWeek: _byDate ? null : _cycleWeek,
        title: _title.text,
        hideRegular: _hide,
        items: List.of(_items),
      );
      if (_byDate && rule.onDate == null) {
        throw const ValidationError('Выберите дату');
      }
      final id = await repo.saveDayRule(widget.semesterId, rule);
      if (!mounted) return;
      Navigator.of(context).pop(id);
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    final r = _original;
    if (r == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить «${r.title}»?',
      message:
          'Обычные пары этого дня вернутся в расписание. 30 дней можно '
          'отменить в корзине.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await ref.read(studyRepositoryProvider).deleteDayRule(r.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final data = ref.watch(studyDataProvider).value;
    if (data == null) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final semester = data.semesterById[widget.semesterId];
    if (_missing || semester == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Особый день'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Правило не найдено: возможно, его удалили на другом устройстве.',
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
          SheetHeader(title: _isNew ? 'Новый особый день' : 'Особый день'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('rule-title'),
                      controller: _title,
                      autofocus: _isNew,
                      decoration: const InputDecoration(
                        hintText: 'Например, Подготовка к олимпиаде',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Когда',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_isNew)
                          ChipRow(
                            children: [
                              FilterPill(
                                key: const Key('rule-scope-weekday'),
                                label: 'По дням недели',
                                selected: !_byDate,
                                onTap: () => setState(() => _byDate = false),
                              ),
                              FilterPill(
                                key: const Key('rule-scope-date'),
                                label: 'На дату',
                                selected: _byDate,
                                onTap: () => setState(() => _byDate = true),
                              ),
                            ],
                          ),
                        const SizedBox(height: AppSpacing.s2),
                        if (!_byDate) ...[
                          if (_isNew)
                            WeekdayChips(
                              keyPrefix: 'rule-weekday',
                              value: _weekday,
                              onChanged: (d) => setState(() => _weekday = d),
                            )
                          else
                            Text(
                              'Каждый ${weekdayName(_weekday).toLowerCase()}',
                              key: const Key('rule-scope-text'),
                              style: t.body,
                            ),
                          if (semester.cycleLength > 1) ...[
                            const SizedBox(height: AppSpacing.s2),
                            if (_isNew)
                              CycleWeekChips(
                                keyPrefix: 'rule-cycle',
                                semester: semester,
                                value: _cycleWeek,
                                onChanged: (w) =>
                                    setState(() => _cycleWeek = w),
                              )
                            else
                              Text(
                                cycleWeekLabel(semester, _cycleWeek),
                                style: t.bodyS.copyWith(color: c.textSecondary),
                              ),
                          ],
                        ] else if (_isNew)
                          DateChoiceRow(
                            keyPrefix: 'rule-date',
                            today: today,
                            value: _date,
                            onChanged: (d) => setState(() => _date = d),
                          )
                        else
                          Text(
                            _date == null ? '' : dateLong(formatDate(_date!)),
                            key: const Key('rule-scope-text'),
                            style: t.body,
                          ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    key: const Key('rule-hide-regular'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Обычных пар нет'),
                    subtitle: const Text(
                      'В этот день пары по расписанию скрыты.',
                    ),
                    value: _hide,
                    onChanged: (v) => setState(() => _hide = v),
                  ),
                  FormBlock(label: 'Занятия', child: _itemsField(context)),
                  if (_error != null)
                    FormError(_error!, key: const Key('rule-error')),
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
                    key: const Key('rule-delete'),
                    onPressed: _delete,
                    child: Text('Удалить', style: TextStyle(color: c.danger)),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('rule-save'),
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

  Widget _itemsField(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_items.isNotEmpty)
          ListCard(
            child: Column(
              children: [
                for (var i = 0; i < _items.length; i++)
                  ListTile(
                    key: Key('rule-item-$i'),
                    onTap: () => _editItem(item: _items[i], index: i),
                    title: Text(_items[i].title),
                    subtitle: Text(
                      [
                        if (_items[i].number != null)
                          '${_items[i].number} пара'
                        else
                          lessonTime(_items[i].startTime, _items[i].endTime),
                        _items[i].kind.label,
                        if (_items[i].building != null ||
                            _items[i].room != null)
                          formatRoom(_items[i].building, _items[i].room),
                      ].join(' · '),
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                    trailing: IconButton(
                      key: Key('rule-item-remove-$i'),
                      tooltip: 'Убрать занятие',
                      onPressed: () => setState(() => _items.removeAt(i)),
                      icon: const Icon(LucideIcons.x, size: 18),
                    ),
                  ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('rule-item-add'),
            onPressed: _items.length >= maxRuleItems ? null : _editItem,
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Добавить занятие'),
          ),
        ),
      ],
    );
  }
}

/// Диалог занятия особого дня: название, тип, номер пары или своё время,
/// аудитория, неделя цикла.
class _ItemDialog extends StatefulWidget {
  const _ItemDialog({
    required this.itemKey,
    required this.defaultTitle,
    required this.numbers,
    required this.defaultNumber,
    this.initial,
  });

  final String itemKey;
  final String defaultTitle;
  final RuleItem? initial;
  final List<int> numbers;
  final int defaultNumber;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  final _title = TextEditingController();
  final _room = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  LessonKind _kind = LessonKind.other;
  int? _number;
  bool _ownTime = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i == null) {
      _title.text = widget.defaultTitle.trim();
      _number = widget.numbers.contains(widget.defaultNumber)
          ? widget.defaultNumber
          : widget.numbers.first;
    } else {
      _title.text = i.title;
      _kind = i.kind;
      _number = i.number;
      _ownTime = i.startTime != null;
      _start.text = i.startTime ?? '';
      _end.text = i.endTime ?? '';
      _room.text = formatRoom(i.building, i.room);
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

  void _ok() {
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
    final item = RuleItem(
      key: widget.initial?.key ?? widget.itemKey,
      title: _title.text.trim(),
      kind: _kind,
      number: _ownTime ? null : _number,
      startTime: start,
      endTime: end,
      building: room.building,
      room: room.room,
      cycleWeek: widget.initial?.cycleWeek,
    );
    final problem = _problem(item);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(item);
  }

  String? _problem(RuleItem item) {
    if (item.title.isEmpty) return 'Название не может быть пустым';
    if (item.startTime != null &&
        item.endTime != null &&
        item.endTime!.compareTo(item.startTime!) <= 0) {
      return 'Конец должен быть позже начала';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('rule-item-dialog'),
      title: Text('Занятие', style: context.text.h3),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormBlock(
              label: 'Название',
              child: FormTextField(
                key: const Key('rule-item-title'),
                controller: _title,
                autofocus: true,
              ),
            ),
            FormBlock(
              label: 'Тип',
              child: LessonKindChips(
                keyPrefix: 'rule-item-kind',
                value: _kind,
                onChanged: (k) => setState(() => _kind = k ?? LessonKind.other),
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
                        key: const Key('rule-item-time-bell'),
                        label: 'По звонку',
                        selected: !_ownTime,
                        onTap: () => setState(() => _ownTime = false),
                      ),
                      FilterPill(
                        key: const Key('rule-item-time-own'),
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
                            key: const Key('rule-item-start'),
                            child: TimeTextField(controller: _start),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('—'),
                        ),
                        Expanded(
                          child: KeyedSubtree(
                            key: const Key('rule-item-end'),
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
                        for (final n in widget.numbers)
                          FilterPill(
                            key: Key('rule-item-number-$n'),
                            label: '$n пара',
                            selected: _number == n,
                            onTap: () => setState(() => _number = n),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            FormBlock(
              label: 'Аудитория',
              child: KeyedSubtree(
                key: const Key('rule-item-room'),
                child: RoomTextField(controller: _room),
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                key: const Key('rule-item-error'),
                style: context.text.bodyS.copyWith(
                  color: context.colors.danger,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('rule-item-ok'),
          onPressed: _ok,
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
