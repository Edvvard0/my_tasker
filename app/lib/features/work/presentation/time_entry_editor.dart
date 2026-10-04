import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart';

/// Открывает форму записи времени вручную: [entryId] — правка завершённой
/// записи, иначе новая (с [projectId] по умолчанию).
Future<void> showTimeEntryEditor(
  BuildContext context, {
  String? entryId,
  String? projectId,
}) => showEditorSheet<void>(
  context,
  builder: (_) => TimeEntryEditor(entryId: entryId, projectId: projectId),
);

/// Запись времени вручную: проект, доработка, день, начало и длительность,
/// «оплачиваемое» и заметка. Время вводится по часам устройства; отчёты
/// считают день записи по Москве (spec 4.8).
class TimeEntryEditor extends ConsumerStatefulWidget {
  const TimeEntryEditor({this.entryId, this.projectId, super.key});

  final String? entryId;
  final String? projectId;

  @override
  ConsumerState<TimeEntryEditor> createState() => _TimeEntryEditorState();
}

class _TimeEntryEditorState extends ConsumerState<TimeEntryEditor> {
  final _minutes = TextEditingController(text: '60');
  final _note = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  TimeEntry? _original;
  String? _projectId;
  String? _changeRequestId;
  DateTime? _date;
  TimeOfDay _start = const TimeOfDay(hour: 9, minute: 0);
  bool _billable = true;
  bool _timeTouched = false;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.entryId == null;

  @override
  void initState() {
    super.initState();
    _projectId = widget.projectId;
    if (_isNew) {
      _date = ref.read(todayProvider);
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _minutes.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final entry = await ref
        .read(workRepositoryProvider)
        .getEntry(widget.entryId!);
    if (!mounted) return;
    if (entry == null || entry.isRunning) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    final zone = ref.read(deviceTimeZoneProvider);
    final wall = utcToWall(zone, entry.startedAt);
    setState(() {
      _original = entry;
      _projectId = entry.projectId;
      _changeRequestId = entry.changeRequestId;
      _date = dateOnly(wall);
      _start = TimeOfDay(hour: wall.hour, minute: wall.minute);
      _minutes.text =
          '${(entry.endedAt!.difference(entry.startedAt).inSeconds / 60).round()}';
      _billable = entry.billable;
      _note.text = entry.note ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final projectId = _projectId;
    if (projectId == null) {
      setState(() => _error = 'Выберите проект');
      return;
    }
    final minutes = int.tryParse(_minutes.text.trim());
    if (minutes == null || minutes <= 0) {
      setState(() => _error = 'Длительность — число минут больше нуля');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(workRepositoryProvider);
    final zone = ref.read(deviceTimeZoneProvider);
    try {
      final original = _original;
      DateTime start;
      DateTime end;
      if (original != null && !_timeTouched) {
        start = original.startedAt;
        end = original.endedAt!;
      } else {
        final d = _date!;
        start = wallToUtc(
          zone,
          d.year,
          d.month,
          d.day,
          _start.hour,
          _start.minute,
        );
        end = start.add(Duration(minutes: minutes));
      }
      final note = _note.text.trim().isEmpty ? null : _note.text.trim();
      if (original == null) {
        await repo.addManualEntry(
          TimeEntry(
            id: repo.newId(),
            projectId: projectId,
            changeRequestId: _changeRequestId,
            startedAt: start,
            endedAt: end,
            billable: _billable,
            note: note,
            source: TimeSource.manual,
          ),
        );
      } else {
        await repo.updateEntry(
          original.copyWith(
            projectId: projectId,
            changeRequestId: _changeRequestId,
            startedAt: start,
            endedAt: end,
            billable: _billable,
            note: note,
          ),
        );
      }
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

  Future<void> _delete() async {
    final repo = ref.read(workRepositoryProvider);
    final id = widget.entryId!;
    final messenger = ScaffoldMessenger.of(context);
    await repo.deleteEntry(id);
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text('Запись времени удалена'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () => repo.restoreEntry(id),
          ),
        ),
      );
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
          const SheetHeader(title: 'Время'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Запись не найдена или ещё идёт. Остановите таймер, чтобы '
              'править запись.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = ref.watch(todayProvider);
    final data = ref.watch(workDataProvider).value;
    final projects = [
      for (final p in data?.projects ?? const <WorkProject>[])
        if ((!p.archived && p.effectiveStatus != ProjectStatus.cancelled) ||
            p.id == _projectId)
          p,
    ];
    final crs = _projectId == null || data == null
        ? const <ChangeRequest>[]
        : [
            for (final cr in data.changeRequestsOf(_projectId!))
              if (cr.status != ChangeRequestStatus.cancelled ||
                  cr.id == _changeRequestId)
                cr,
          ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Время вручную' : 'Запись времени'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Проект',
                    child: ChipRow(
                      children: [
                        for (final p in projects)
                          FilterPill(
                            key: Key('entry-project-${p.id}'),
                            label: p.title,
                            selected: _projectId == p.id,
                            icon: LucideIcons.folder,
                            onTap: () => setState(() {
                              if (_projectId != p.id) _changeRequestId = null;
                              _projectId = p.id;
                            }),
                          ),
                      ],
                    ),
                  ),
                  if (crs.isNotEmpty)
                    FormBlock(
                      label: 'Доработка',
                      child: ChipRow(
                        children: [
                          FilterPill(
                            key: const Key('entry-cr-none'),
                            label: 'Без доработки',
                            selected: _changeRequestId == null,
                            onTap: () =>
                                setState(() => _changeRequestId = null),
                          ),
                          for (final cr in crs)
                            FilterPill(
                              key: Key('entry-cr-${cr.id}'),
                              label: cr.title,
                              selected: _changeRequestId == cr.id,
                              onTap: () =>
                                  setState(() => _changeRequestId = cr.id),
                            ),
                        ],
                      ),
                    ),
                  FormBlock(
                    label: 'День',
                    child: DateChoiceRow(
                      keyPrefix: 'entry-date',
                      today: today,
                      value: _date,
                      onChanged: (d) => setState(() {
                        _date = d;
                        _timeTouched = true;
                      }),
                    ),
                  ),
                  FormBlock(
                    label: 'Начало',
                    child: TimeChoiceRow(
                      keyPrefix: 'entry-start',
                      value: _start,
                      allowNone: false,
                      onChanged: (v) => setState(() {
                        _start = v!;
                        _timeTouched = true;
                      }),
                    ),
                  ),
                  FormBlock(
                    label: 'Длительность, минут',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ChipRow(
                          children: [
                            for (final m in const [15, 30, 60, 120, 240])
                              FilterPill(
                                key: Key('entry-minutes-$m'),
                                label: m < 60 ? '$m мин' : '${m ~/ 60} ч',
                                selected: _minutes.text.trim() == '$m',
                                onTap: () => setState(() {
                                  _minutes.text = '$m';
                                  _timeTouched = true;
                                }),
                              ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        FormTextField(
                          key: const Key('entry-minutes'),
                          controller: _minutes,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          onChanged: (_) => setState(() => _timeTouched = true),
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    key: const Key('entry-billable'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('Оплачиваемое', style: t.body),
                    subtitle: Text(
                      'Идёт в доход в час',
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                    value: _billable,
                    onChanged: (v) => setState(() => _billable = v),
                  ),
                  FormBlock(
                    label: 'Заметка',
                    child: FormTextField(
                      key: const Key('entry-note'),
                      controller: _note,
                      decoration: const InputDecoration(
                        hintText: 'Необязательно',
                      ),
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('entry-error')),
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
                  OutlinedButton.icon(
                    key: const Key('entry-delete'),
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.danger,
                      side: BorderSide(color: c.danger),
                    ),
                    icon: const Icon(LucideIcons.trash2, size: 18),
                    label: const Text('Удалить'),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('entry-save'),
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
