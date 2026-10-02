import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/domain/recurrence_draft.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/recurrence_field.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_validation.dart';

/// Открывает редактор задачи. [taskId] — правка существующей; иначе
/// создание (с необязательным начальным сроком [initialDue] и названием).
Future<void> showTaskEditor(
  BuildContext context, {
  String? taskId,
  TaskDue? initialDue,
  String? initialTitle,
}) => showEditorSheet<void>(
  context,
  builder: (_) => TaskEditor(
    taskId: taskId,
    initialDue: initialDue,
    initialTitle: initialTitle,
  ),
);

class _SubtaskDraft {
  _SubtaskDraft({required this.title, this.id, this.done = false});

  final String? id;
  String title;
  bool done;
}

/// Редактор задачи (02, 4.2 и 6.3): название, заметки, статус (5), приоритет
/// P1–P5, срок (дата, время или без срока), длительность, повторение,
/// напоминания, чек-лист, теги, проект и человек.
class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({
    this.taskId,
    this.initialDue,
    this.initialTitle,
    super.key,
  });

  final String? taskId;
  final TaskDue? initialDue;
  final String? initialTitle;

  @override
  ConsumerState<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<TaskEditor> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _newSubtask = TextEditingController();
  final _newTag = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  TaskEntity? _original;
  TaskStatus _status = TaskStatus.inbox;
  bool _statusTouched = false;
  int? _priority;
  DateTime? _date;
  TimeOfDay? _time;
  int _duration = 60;
  RecurrenceDraft _repeat = RecurrenceDraft.none;
  RecurrenceMode _mode = RecurrenceMode.schedule;
  List<int> _reminders = [];
  String? _projectId;
  String? _personId;
  final List<String> _tags = [];
  final List<_SubtaskDraft> _subtasks = [];
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.taskId == null;

  @override
  void initState() {
    super.initState();
    _title.text = widget.initialTitle ?? '';
    final due = widget.initialDue;
    if (due != null) _applyDue(due);
    if (_isNew) {
      _status = _date == null ? TaskStatus.inbox : TaskStatus.todo;
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _newSubtask.dispose();
    _newTag.dispose();
    super.dispose();
  }

  void _applyDue(TaskDue due) {
    if (due.hasTime) {
      final zone = requireLocation(due.tz!);
      final wall = utcToWall(zone, due.at!);
      _date = dateOnly(wall);
      _time = TimeOfDay(hour: wall.hour, minute: wall.minute);
    } else {
      _date = due.date;
      _time = null;
    }
  }

  Future<void> _load() async {
    final repo = ref.read(taskRepositoryProvider);
    final task = await repo.getTask(widget.taskId!);
    if (!mounted) return;
    if (task == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    final subtasks = await repo.subtasksOf(task.id);
    final tags = await repo.tagsOfTask(task.id);
    if (!mounted) return;
    final zone = ref.read(deviceTimeZoneProvider);
    final cycle = ref.read(weekCycleProvider).value;
    setState(() {
      _original = task;
      _title.text = task.title;
      _notes.text = task.notes ?? '';
      _status = task.status;
      _statusTouched = true;
      _priority = task.priority;
      _applyDue(task.due);
      _duration = task.durationMinutes ?? 60;
      if (task.rrule != null && !task.due.isNone) {
        _repeat = RecurrenceDraft.fromRule(
          RRule.parse(task.rrule!, allDay: !task.due.hasTime),
          start: task.due.localDate!,
          zone: task.due.hasTime ? requireLocation(task.due.tz!) : zone,
          cycle: cycle,
        );
        _mode = task.recurrenceMode ?? RecurrenceMode.schedule;
      }
      _reminders = [...?task.reminders];
      _projectId = task.projectId;
      _personId = task.personId;
      _tags.addAll(tags.map((t) => t.name));
      for (final s in subtasks) {
        _subtasks.add(_SubtaskDraft(id: s.id, title: s.title, done: s.done));
      }
      _loading = false;
    });
  }

  TaskDue _due() {
    final date = _date;
    if (date == null) return const TaskDue.none();
    final time = _time;
    if (time == null) return TaskDue.date(date);
    final zone = ref.read(deviceTimeZoneProvider);
    return TaskDue.at(
      wallToUtc(zone, date.year, date.month, date.day, time.hour, time.minute),
      zone.name,
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(taskRepositoryProvider);
    final zone = ref.read(deviceTimeZoneProvider);
    final cycle = ref.read(weekCycleProvider).value;
    try {
      var due = _due();
      String? rrule;
      RecurrenceMode? mode;
      if (!_repeat.isNone && !due.isNone) {
        final start = due.localDate!;
        var rule = _repeat.toRule(
          start: start,
          allDay: !due.hasTime,
          zone: zone,
          cycle: cycle,
        )!;
        final first = _repeat.cycleWeek != null && cycle != null
            ? cycle.firstDate(
                start,
                rule.byDay.isEmpty ? 0 : rule.byDay.first.weekday,
                _repeat.cycleWeek!,
              )
            : firstMatchingDate(rule, start);
        if (first != start) {
          due = _dueOnDate(first);
          rule = _repeat.toRule(
            start: first,
            allDay: !due.hasTime,
            zone: zone,
            cycle: cycle,
          )!;
        }
        rrule = rule.toRuleString();
        mode = _mode;
      }
      final id = widget.taskId ?? repo.newTaskId();
      final base =
          _original ?? TaskEntity(id: id, title: '', status: TaskStatus.todo);
      final status =
          _status == TaskStatus.done && base.status != TaskStatus.done
          ? TaskStatus.done
          : _status;
      final draft = base.copyWith(
        title: _title.text,
        notes: _notes.text.trim().isEmpty ? null : _notes.text,
        status: status,
        priority: _priority,
        due: due,
        durationMinutes: due.hasTime ? _duration : null,
        rrule: rrule,
        recurrenceMode: mode,
        projectId: _projectId,
        personId: _personId,
        reminders: due.isNone || _reminders.isEmpty ? null : _reminders,
        completedAt: status == TaskStatus.done
            ? (base.completedAt ?? ref.read(nowProvider))
            : null,
      );
      if (_isNew) {
        await repo.createTask(draft);
      } else {
        await repo.updateTask(draft);
      }
      await _applySubtasks(repo, id);
      await repo.setTaskTags(id, _tags);
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

  TaskDue _dueOnDate(DateTime date) {
    final time = _time;
    if (time == null) return TaskDue.date(date);
    final zone = ref.read(deviceTimeZoneProvider);
    return TaskDue.at(
      wallToUtc(zone, date.year, date.month, date.day, time.hour, time.minute),
      zone.name,
    );
  }

  Future<void> _applySubtasks(TaskRepository repo, String taskId) async {
    final existing = {for (final s in await repo.subtasksOf(taskId)) s.id: s};
    final keep = {for (final d in _subtasks) ?d.id};
    for (final s in existing.values) {
      if (!keep.contains(s.id)) await repo.deleteSubtask(s.id);
    }
    final order = <String>[];
    for (final d in _subtasks) {
      if (d.id == null) {
        order.add(await repo.addSubtask(taskId, d.title));
        continue;
      }
      final old = existing[d.id];
      if (old != null) {
        if (old.title != d.title) await repo.renameSubtask(d.id!, d.title);
        if (old.done != d.done) {
          await repo.setSubtaskDone(d.id!, done: d.done);
        }
      }
      order.add(d.id!);
    }
    if (order.isNotEmpty) await repo.reorderSubtasks(taskId, order);
  }

  Future<void> _delete() async {
    final id = widget.taskId!;
    final repo = ref.read(taskRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final title = _title.text;
    await repo.deleteTask(id);
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Удалено: «$title»'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () => repo.restoreTask(id),
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
          const SheetHeader(title: 'Задача'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Задача не найдена: возможно, её удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = ref.watch(todayProvider);
    final projects = ref.watch(projectsProvider).value ?? const [];
    final people = ref.watch(peopleProvider).value ?? const [];
    final cycle = ref.watch(weekCycleProvider).value;
    final hasDue = _date != null;
    final allDay = _time == null;
    final start = _date ?? today;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новая задача' : 'Задача'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('task-title'),
                      controller: _title,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Что нужно сделать',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Статус',
                    child: ChipRow(
                      children: [
                        for (final s in TaskStatus.values)
                          FilterPill(
                            key: Key('task-status-${s.wire}'),
                            label: s.label,
                            selected: _status == s,
                            onTap: () => setState(() {
                              _status = s;
                              _statusTouched = true;
                            }),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Приоритет',
                    child: ChipRow(
                      children: [
                        FilterPill(
                          key: const Key('task-priority-none'),
                          label: 'Нет',
                          selected: _priority == null,
                          onTap: () => setState(() => _priority = null),
                        ),
                        for (var p = 1; p <= 5; p++)
                          FilterPill(
                            key: Key('task-priority-$p'),
                            label: 'P$p',
                            selected: _priority == p,
                            icon: p == 1 ? LucideIcons.flag : null,
                            onTap: () => setState(() => _priority = p),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Дата',
                    child: DateChoiceRow(
                      keyPrefix: 'task-date',
                      today: today,
                      value: _date,
                      allowNone: true,
                      noneLabel: 'Без даты',
                      onChanged: (d) => setState(() {
                        _date = d;
                        if (d == null) {
                          _time = null;
                          _repeat = RecurrenceDraft.none;
                          _reminders = [];
                        } else if (!_statusTouched &&
                            _status == TaskStatus.inbox) {
                          _status = TaskStatus.todo;
                        }
                      }),
                    ),
                  ),
                  if (hasDue) ...[
                    FormBlock(
                      label: 'Время',
                      child: TimeChoiceRow(
                        keyPrefix: 'task-time',
                        value: _time,
                        onChanged: (v) => setState(() {
                          _time = v;
                          // Напоминания «всё-дневные» и «по времени» разные.
                          _reminders = [];
                        }),
                      ),
                    ),
                    if (_time != null)
                      FormBlock(
                        label: 'Длительность (блок в сетке)',
                        child: ChipRow(
                          children: [
                            for (final m in const [15, 30, 60, 90, 120])
                              FilterPill(
                                key: Key('task-duration-$m'),
                                label: m < 60
                                    ? '$m мин'
                                    : (m % 60 == 0
                                          ? '${m ~/ 60} ч'
                                          : '${m ~/ 60} ч ${m % 60}'),
                                selected: _duration == m,
                                onTap: () => setState(() => _duration = m),
                              ),
                          ],
                        ),
                      ),
                  ],
                  FormBlock(
                    label: 'Повторение',
                    child: hasDue
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RecurrenceField(
                                draft: _repeat,
                                start: start,
                                cycle: cycle,
                                onChanged: (d) => setState(() => _repeat = d),
                                onOpenCycleSettings: () {
                                  Navigator.of(context).pop();
                                  context.go('/calendar/settings');
                                },
                              ),
                              if (!_repeat.isNone) ...[
                                const SizedBox(height: AppSpacing.s3),
                                ChipRow(
                                  children: [
                                    for (final m in RecurrenceMode.values)
                                      FilterPill(
                                        key: Key('task-mode-${m.wire}'),
                                        label: m.label,
                                        selected: _mode == m,
                                        onTap: () => setState(() => _mode = m),
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          )
                        : Text(
                            'Повторение доступно для задач со сроком.',
                            style: t.bodyS.copyWith(color: c.textTertiary),
                          ),
                  ),
                  if (hasDue)
                    FormBlock(
                      label: 'Напоминания',
                      child: RemindersField(
                        value: _reminders,
                        allDay: allDay,
                        onChanged: (v) => setState(() => _reminders = v),
                      ),
                    ),
                  FormBlock(label: 'Чек-лист', child: _checklist(context)),
                  FormBlock(
                    label: 'Проект',
                    child: _projectPicker(context, projects),
                  ),
                  FormBlock(
                    label: 'Человек',
                    child: _personPicker(context, people),
                  ),
                  FormBlock(label: 'Теги', child: _tagsField(context)),
                  FormBlock(
                    label: 'Заметки',
                    child: FormTextField(
                      key: const Key('task-notes'),
                      controller: _notes,
                      minLines: 3,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        hintText: 'Подробности (markdown)',
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: Row(
                        key: const Key('task-error'),
                        children: [
                          Icon(
                            LucideIcons.circleAlert,
                            size: 16,
                            color: c.danger,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _error!,
                              style: t.bodyS.copyWith(color: c.danger),
                            ),
                          ),
                        ],
                      ),
                    ),
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
                    key: const Key('task-delete'),
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
                  key: const Key('task-save'),
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

  // ---- чек-лист ---------------------------------------------------------------

  Widget _checklist(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _subtasks.length; i++)
          Row(
            key: Key('subtask-$i'),
            children: [
              Checkbox(
                value: _subtasks[i].done,
                onChanged: (v) =>
                    setState(() => _subtasks[i].done = v ?? false),
              ),
              Expanded(
                child: Text(
                  _subtasks[i].title,
                  style: context.text.body.copyWith(
                    color: _subtasks[i].done ? c.textTertiary : c.textPrimary,
                    decoration: _subtasks[i].done
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
              ),
              IconButton(
                key: Key('subtask-remove-$i'),
                tooltip: 'Убрать пункт',
                onPressed: () => setState(() => _subtasks.removeAt(i)),
                icon: Icon(LucideIcons.x, size: 18, color: c.textSecondary),
              ),
            ],
          ),
        FormTextField(
          key: const Key('subtask-new'),
          controller: _newSubtask,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'Добавить пункт',
            prefixIcon: Icon(LucideIcons.plus, size: 18, color: c.textTertiary),
          ),
          onSubmitted: (_) => _addSubtask(),
        ),
      ],
    );
  }

  void _addSubtask() {
    final text = _newSubtask.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _subtasks.add(_SubtaskDraft(title: text));
      _newSubtask.clear();
    });
  }

  // ---- проект, человек, теги ----------------------------------------------------

  Widget _projectPicker(BuildContext context, List<Project> projects) {
    final active = [
      for (final p in projects)
        if (!p.archived || p.id == _projectId) p,
    ];
    return ChipRow(
      children: [
        FilterPill(
          key: const Key('task-project-none'),
          label: 'Нет',
          selected: _projectId == null,
          onTap: () => setState(() => _projectId = null),
        ),
        for (final p in active)
          FilterPill(
            key: Key('task-project-${p.id}'),
            label: p.title,
            selected: _projectId == p.id,
            icon: LucideIcons.folder,
            onTap: () => setState(() => _projectId = p.id),
          ),
        FilterPill(
          key: const Key('task-project-new'),
          label: 'Новый',
          selected: false,
          icon: LucideIcons.plus,
          onTap: () async {
            final name = await _askName(context, 'Новый проект');
            if (name == null) return;
            final id = await ref
                .read(taskRepositoryProvider)
                .createProject(name);
            if (mounted) setState(() => _projectId = id);
          },
        ),
      ],
    );
  }

  Widget _personPicker(BuildContext context, List<Person> people) {
    final active = [
      for (final p in people)
        if (!p.archived || p.id == _personId) p,
    ];
    return ChipRow(
      children: [
        FilterPill(
          key: const Key('task-person-none'),
          label: 'Нет',
          selected: _personId == null,
          onTap: () => setState(() => _personId = null),
        ),
        for (final p in active)
          FilterPill(
            key: Key('task-person-${p.id}'),
            label: p.name,
            selected: _personId == p.id,
            icon: LucideIcons.user,
            onTap: () => setState(() => _personId = p.id),
          ),
        FilterPill(
          key: const Key('task-person-new'),
          label: 'Новый',
          selected: false,
          icon: LucideIcons.plus,
          onTap: () async {
            final name = await _askName(context, 'Новый человек');
            if (name == null) return;
            final id = await ref
                .read(taskRepositoryProvider)
                .createPerson(name);
            if (mounted) setState(() => _personId = id);
          },
        ),
      ],
    );
  }

  Future<String?> _askName(BuildContext context, String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: context.text.h3),
        content: FormTextField(
          key: const Key('ask-name-field'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Название'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('ask-name-ok'),
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    ).then((v) => v == null || v.isEmpty ? null : v);
  }

  Widget _tagsField(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s2),
            child: Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: [
                for (final tag in _tags)
                  InputPill(
                    key: Key('task-tag-$tag'),
                    label: '#$tag',
                    icon: LucideIcons.tag,
                    onRemove: () => setState(() => _tags.remove(tag)),
                  ),
              ],
            ),
          ),
        FormTextField(
          key: const Key('task-tag-new'),
          controller: _newTag,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'Добавить тег',
            prefixIcon: Icon(LucideIcons.tag, size: 18, color: c.textTertiary),
          ),
          onSubmitted: (_) => _addTag(),
        ),
      ],
    );
  }

  void _addTag() {
    final name = _newTag.text.trim().replaceFirst(RegExp('^[#+]'), '');
    if (name.isEmpty) return;
    if (!isValidTagName(name)) {
      setState(() => _error = 'Имя тега: без пробелов и символов # @ + !');
      return;
    }
    setState(() {
      _error = null;
      if (!_tags.any((t) => t.toLowerCase() == name.toLowerCase())) {
        _tags.add(name);
      }
      _newTag.clear();
    });
  }
}
