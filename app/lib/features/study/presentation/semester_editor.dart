import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/recurrence/week_cycle.dart';
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
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает редактор семестра: [semesterId] — правка, иначе создание.
Future<String?> showSemesterEditor(
  BuildContext context, {
  String? semesterId,
}) => showEditorSheet<String>(
  context,
  builder: (_) => SemesterEditor(semesterId: semesterId),
);

/// Редактор семестра: название, даты, чередование недель (опорная неделя
/// №1 и сдвиги чётности), архив и удаление (spec 1.1).
class SemesterEditor extends ConsumerStatefulWidget {
  const SemesterEditor({this.semesterId, super.key});

  final String? semesterId;

  @override
  ConsumerState<SemesterEditor> createState() => _SemesterEditorState();
}

class _SemesterEditorState extends ConsumerState<SemesterEditor> {
  final _name = TextEditingController();
  bool _loading = true;
  bool _missing = false;
  Semester? _original;
  DateTime? _start;
  DateTime? _end;
  DateTime? _week1;
  int _cycle = 2;
  final List<WeekShift> _shifts = [];
  bool _defaultBells = true;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.semesterId == null;

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
    super.dispose();
  }

  Future<void> _load() async {
    final s = await ref
        .read(studyRepositoryProvider)
        .getSemester(widget.semesterId!);
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
      _start = parseDate(s.startDate);
      _end = parseDate(s.endDate);
      _week1 = parseDate(s.week1Start);
      _cycle = s.cycleLength;
      _shifts.addAll(s.weekShifts);
      _loading = false;
    });
  }

  Future<void> _addShift() async {
    final today = ref.read(todayProvider);
    final picked = await showDatePicker(
      context: context,
      initialDate: _start ?? today,
      firstDate: DateTime(minYear),
      lastDate: DateTime(maxYear),
      locale: const Locale('ru'),
      helpText: 'С какой недели сдвинуть чётность',
    );
    if (picked == null || !mounted) return;
    setState(
      () => _shifts.add(
        WeekShift(from: civil(picked.year, picked.month, picked.day), weeks: 1),
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final today = ref.read(todayProvider);
    final start = _start ?? today;
    final end = _end ?? addDays(start, 120);
    final repo = ref.read(studyRepositoryProvider);
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final draft = Semester(
        id: _original?.id ?? repo.newId(),
        name: _name.text,
        startDate: formatDate(start),
        endDate: formatDate(end),
        week1Start: formatDate(_week1 ?? mondayOf(start)),
        cycleLength: _cycle,
        weekShifts: _cycle > 1 ? _shifts : const [],
        archived: _original?.archived ?? false,
      );
      if (_isNew) {
        await repo.createSemester(draft);
        if (_defaultBells) {
          final grid = generateBells(
            defaultFirstBell,
            defaultBellDuration,
            defaultBellBreak,
            defaultBellCount,
          );
          await repo.replaceBells(semesterId: draft.id, grid: grid!);
        }
      } else {
        await repo.updateSemester(draft);
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
      title: 'Удалить «${s.name}»?',
      message:
          'Предметы, пары, звонки, долги и отметки семестра уйдут в корзину '
          'на 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await ref.read(studyRepositoryProvider).deleteSemester(s.id);
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
          const SheetHeader(title: 'Семестр'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Семестр не найден: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = ref.watch(todayProvider);
    final start = _start ?? today;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый семестр' : 'Семестр'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('semester-name'),
                      controller: _name,
                      autofocus: _isNew,
                      decoration: const InputDecoration(
                        hintText: 'Например, Осень 2026',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Начало семестра',
                    child: DateChoiceRow(
                      keyPrefix: 'semester-start',
                      today: today,
                      value: start,
                      onChanged: (d) => setState(() => _start = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Конец семестра',
                    child: DateChoiceRow(
                      keyPrefix: 'semester-end',
                      today: today,
                      value: _end ?? addDays(start, 120),
                      onChanged: (d) => setState(() => _end = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Чередование недель',
                    child: ChipRow(
                      children: [
                        FilterPill(
                          key: const Key('semester-cycle-1'),
                          label: 'Нет',
                          selected: _cycle == 1,
                          onTap: () => setState(() => _cycle = 1),
                        ),
                        FilterPill(
                          key: const Key('semester-cycle-2'),
                          label: 'Чёт / нечёт',
                          selected: _cycle == 2,
                          onTap: () => setState(() => _cycle = 2),
                        ),
                        FilterPill(
                          key: const Key('semester-cycle-3'),
                          label: '3 недели',
                          selected: _cycle == 3,
                          onTap: () => setState(() => _cycle = 3),
                        ),
                        FilterPill(
                          key: const Key('semester-cycle-4'),
                          label: '4 недели',
                          selected: _cycle == 4,
                          onTap: () => setState(() => _cycle = 4),
                        ),
                      ],
                    ),
                  ),
                  if (_cycle > 1) ...[
                    FormBlock(
                      label: _cycle == 2
                          ? 'Первая (нечётная) неделя начинается'
                          : 'Первая неделя цикла начинается',
                      child: DateChoiceRow(
                        keyPrefix: 'semester-week1',
                        today: today,
                        value: _week1 ?? mondayOf(start),
                        onChanged: (d) => setState(() => _week1 = d),
                      ),
                    ),
                    FormBlock(label: 'Сдвиги чётности', child: _shiftsField()),
                  ],
                  if (_isNew)
                    SwitchListTile(
                      key: const Key('semester-default-bells'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Заполнить звонки'),
                      subtitle: const Text(
                        'С 08:30, пара 90 минут, перемена 10 минут, 6 пар. '
                        'Потом можно поправить.',
                      ),
                      value: _defaultBells,
                      onChanged: (v) => setState(() => _defaultBells = v),
                    ),
                  if (_error != null)
                    FormError(_error!, key: const Key('semester-error')),
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
                    key: const Key('semester-delete'),
                    onPressed: _delete,
                    child: Text('Удалить', style: TextStyle(color: c.danger)),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('semester-save'),
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

  Widget _shiftsField() {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _shifts.length; i++)
          Row(
            key: Key('semester-shift-$i'),
            children: [
              Icon(
                LucideIcons.arrowLeftRight,
                size: 16,
                color: c.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  'С недели ${dateLong(formatDate(_shifts[i].from))}: '
                  '${_shifts[i].weeks > 0 ? '+' : ''}${_shifts[i].weeks} нед.',
                ),
              ),
              IconButton(
                key: Key('semester-shift-flip-$i'),
                tooltip: 'Сменить направление',
                onPressed: () => setState(
                  () => _shifts[i] = WeekShift(
                    from: _shifts[i].from,
                    weeks: -_shifts[i].weeks,
                  ),
                ),
                icon: const Icon(LucideIcons.arrowUpDown, size: 18),
              ),
              IconButton(
                tooltip: 'Убрать сдвиг',
                onPressed: () => setState(() => _shifts.removeAt(i)),
                icon: const Icon(LucideIcons.x, size: 18),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('semester-shift-add'),
            onPressed: _addShift,
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Сдвинуть чётность'),
          ),
        ),
      ],
    );
  }
}
