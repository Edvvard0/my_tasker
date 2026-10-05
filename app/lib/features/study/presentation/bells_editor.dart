import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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
import 'package:my_tasker/features/study/domain/study_validation.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает редактор звонков семестра [semesterId]; [onDate] — сразу
/// «только на эту дату».
Future<void> showBellsEditor(
  BuildContext context, {
  required String semesterId,
  String? onDate,
}) => showEditorSheet<void>(
  context,
  builder: (_) => BellsEditor(semesterId: semesterId, onDate: onDate),
);

class _Row {
  _Row(this.number, String start, String end)
    : start = TextEditingController(text: start),
      end = TextEditingController(text: end);

  int number;
  final TextEditingController start;
  final TextEditingController end;

  void dispose() {
    start.dispose();
    end.dispose();
  }
}

/// Редактор сетки звонков (spec 1.3): начало первой пары, длительность и
/// перемены задают сетку генератором, время каждой пары правится вручную.
/// Изменение — «для всех дней» (обычная сетка семестра) или «только на
/// дату» (звонки этого дня заменяют обычные по каждому номеру).
class BellsEditor extends ConsumerStatefulWidget {
  const BellsEditor({required this.semesterId, this.onDate, super.key});

  final String semesterId;
  final String? onDate;

  @override
  ConsumerState<BellsEditor> createState() => _BellsEditorState();
}

class _BellsEditorState extends ConsumerState<BellsEditor> {
  final _genStart = TextEditingController(text: defaultFirstBell);
  final _genDuration = TextEditingController(text: '$defaultBellDuration');
  final _genBreaks = TextEditingController(text: '$defaultBellBreak');
  final _genCount = TextEditingController(text: '$defaultBellCount');
  final List<_Row> _rows = [];
  bool _byDate = false;
  DateTime? _date;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.onDate != null) {
      _byDate = true;
      _date = parseDate(widget.onDate!);
    }
    _loadRows();
  }

  @override
  void dispose() {
    _genStart.dispose();
    _genDuration.dispose();
    _genBreaks.dispose();
    _genCount.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  String? get _dateIso => _byDate && _date != null ? formatDate(_date!) : null;

  /// Строки таблицы из данных: звонки этой даты (если есть), иначе
  /// обычные.
  void _loadRows() {
    final data = ref.read(studyDataProvider).value;
    for (final r in _rows) {
      r.dispose();
    }
    _rows.clear();
    if (data == null) return;
    var source = data.bellsOf(widget.semesterId);
    final iso = _dateIso;
    if (iso != null) {
      final own = [
        for (final b in data.dateBellsOf(widget.semesterId))
          if (b.onDate == iso) b,
      ];
      if (own.isNotEmpty) source = own;
    }
    for (final b in source) {
      _rows.add(_Row(b.number, b.startTime, b.endTime));
    }
  }

  void _generate() {
    final start = normalizeTime(_genStart.text);
    final duration = int.tryParse(_genDuration.text.trim());
    final count = int.tryParse(_genCount.text.trim());
    final parts = _genBreaks.text
        .split(RegExp('[,; ]+'))
        .where((p) => p.isNotEmpty)
        .map(int.tryParse)
        .toList();
    if (start == null ||
        duration == null ||
        count == null ||
        parts.isEmpty ||
        parts.contains(null)) {
      setState(
        () => _error =
            'Заполните начало (ЧЧ:ММ), длительность, перемены и число пар',
      );
      return;
    }
    final breaks = parts.length == 1
        ? parts.first!
        : [for (final p in parts) p!];
    final grid = generateBells(start, duration, breaks, count);
    if (grid == null) {
      setState(
        () => _error =
            'Сетка не получилась: проверьте длительность (1–300), перемены '
            '(0–240), число пар (1–12) и что последняя пара кончается до '
            '23:59. Перемен должно быть на одну меньше, чем пар.',
      );
      return;
    }
    setState(() {
      _error = null;
      for (final r in _rows) {
        r.dispose();
      }
      _rows
        ..clear()
        ..addAll([
          for (final b in grid) _Row(b.number, b.startTime, b.endTime),
        ]);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_byDate && _date == null) {
      setState(() => _error = 'Выберите дату');
      return;
    }
    final grid = <Bell>[];
    for (final r in _rows) {
      final start = normalizeTime(r.start.text);
      final end = normalizeTime(r.end.text);
      if (start == null || end == null) {
        setState(() => _error = 'Пара ${r.number}: время — в формате ЧЧ:ММ');
        return;
      }
      final problem = bellProblem(r.number, start, end, onDate: _dateIso);
      if (problem != null) {
        setState(() => _error = 'Пара ${r.number}: $problem');
        return;
      }
      grid.add(
        Bell(
          semesterId: widget.semesterId,
          number: r.number,
          startTime: start,
          endTime: end,
        ),
      );
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await ref
          .read(studyRepositoryProvider)
          .replaceBells(
            semesterId: widget.semesterId,
            grid: grid,
            onDate: _dateIso,
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

  Future<void> _restoreRegular() async {
    final iso = _dateIso;
    if (iso == null) return;
    await ref
        .read(studyRepositoryProvider)
        .clearDateBells(widget.semesterId, iso);
    if (mounted) Navigator.of(context).pop();
  }

  void _addRow() {
    if (_rows.length >= 12) return;
    var number = 1;
    final used = {for (final r in _rows) r.number};
    while (used.contains(number)) {
      number++;
    }
    setState(() => _rows.add(_Row(number, '', '')));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final today = ref.watch(todayProvider);
    final data = ref.watch(studyDataProvider).value;
    final hasDateBells =
        data != null &&
        _dateIso != null &&
        data.dateBellsOf(widget.semesterId).any((b) => b.onDate == _dateIso);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Звонки'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Для каких дней',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ChipRow(
                          children: [
                            FilterPill(
                              key: const Key('bells-scope-all'),
                              label: 'Для всех дней',
                              selected: !_byDate,
                              onTap: () => setState(() {
                                _byDate = false;
                                _loadRows();
                              }),
                            ),
                            FilterPill(
                              key: const Key('bells-scope-date'),
                              label: 'Только на дату',
                              selected: _byDate,
                              onTap: () => setState(() {
                                _byDate = true;
                                _date ??= today;
                                _loadRows();
                              }),
                            ),
                          ],
                        ),
                        if (_byDate) ...[
                          const SizedBox(height: AppSpacing.s2),
                          DateChoiceRow(
                            keyPrefix: 'bells-date',
                            today: today,
                            value: _date,
                            onChanged: (d) => setState(() {
                              _date = d;
                              _loadRows();
                            }),
                          ),
                        ],
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Быстрая сетка',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _field(
                                'bells-gen-start',
                                'Начало 1 пары',
                                TimeTextField(controller: _genStart),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.s2),
                            Expanded(
                              child: _field(
                                'bells-gen-duration',
                                'Пара, мин',
                                FormTextField(
                                  controller: _genDuration,
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: _field(
                                'bells-gen-breaks',
                                'Перемены, мин (10 или 10,10,30)',
                                FormTextField(controller: _genBreaks),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.s2),
                            Expanded(
                              child: _field(
                                'bells-gen-count',
                                'Пар',
                                FormTextField(
                                  controller: _genCount,
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ElevatedButton(
                            key: const Key('bells-generate'),
                            onPressed: _generate,
                            child: const Text('Заполнить сетку'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Звонки',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < _rows.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.s1,
                            ),
                            child: Row(
                              key: Key('bells-row-$i'),
                              children: [
                                SizedBox(
                                  width: 36,
                                  child: Text(
                                    '${_rows[i].number}',
                                    style: t.bodyStrong,
                                  ),
                                ),
                                Expanded(
                                  child: KeyedSubtree(
                                    key: Key('bells-start-$i'),
                                    child: TimeTextField(
                                      controller: _rows[i].start,
                                    ),
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 6),
                                  child: Text('—'),
                                ),
                                Expanded(
                                  child: KeyedSubtree(
                                    key: Key('bells-end-$i'),
                                    child: TimeTextField(
                                      controller: _rows[i].end,
                                      hint: '10:00',
                                    ),
                                  ),
                                ),
                                IconButton(
                                  key: Key('bells-remove-$i'),
                                  tooltip: 'Убрать пару',
                                  onPressed: () => setState(() {
                                    _rows.removeAt(i).dispose();
                                  }),
                                  icon: const Icon(LucideIcons.x, size: 18),
                                ),
                              ],
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const Key('bells-add'),
                            onPressed: _addRow,
                            icon: const Icon(LucideIcons.plus, size: 18),
                            label: const Text('Добавить пару'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('bells-error')),
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
                if (hasDateBells)
                  TextButton(
                    key: const Key('bells-restore'),
                    onPressed: _restoreRegular,
                    child: Text(
                      'Вернуть обычные',
                      style: TextStyle(color: c.textSecondary),
                    ),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('bells-save'),
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

  Widget _field(String key, String label, Widget field) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        KeyedSubtree(key: Key(key), child: field),
      ],
    ),
  );
}
