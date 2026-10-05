import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/format/ru_format.dart' show pluralRu;
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/application/calendar_view.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/sleep/application/ritual_tasks.dart';
import 'package:my_tasker/features/sleep/application/sleep_providers.dart';
import 'package:my_tasker/features/sleep/data/sleep_repository.dart';
import 'package:my_tasker/features/sleep/domain/sleep_validation.dart'
    show maxPlanTasks;
import 'package:my_tasker/features/sleep/presentation/ritual_widgets.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_entry_sheet.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_widgets.dart';
import 'package:my_tasker/features/study/application/study_calendar.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/tasks/application/task_providers.dart'
    show TaskListData;
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;
import 'package:timezone/timezone.dart' as tz;

/// «Утренний план» (~2 минуты): как спал, задачи на сегодня, пары и события
/// дня; выбрать до 10 «главных дел» и одно «главное». Всё, кроме выбора и
/// заметки, вычисляется на клиенте из синхронизированных данных и в строку
/// плана не копируется (spec `stage8_sleep_rituals.md`, 1.2).
class MorningPlanScreen extends ConsumerWidget {
  const MorningPlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('morning-plan'),
      title: 'Утренний план',
      parentLabel: 'Сон',
      onBack: () => sleepBack(context),
      child: SleepBody(
        builder: (context, sleep) => RitualTasksBody(
          builder: (context, tasks, zone) =>
              _PlanForm(sleep: sleep, tasks: tasks, zone: zone),
        ),
      ),
    );
  }
}

class _PlanForm extends ConsumerStatefulWidget {
  const _PlanForm({
    required this.sleep,
    required this.tasks,
    required this.zone,
  });

  final SleepData sleep;
  final TaskListData tasks;
  final tz.Location zone;

  @override
  ConsumerState<_PlanForm> createState() => _PlanFormState();
}

class _PlanFormState extends ConsumerState<_PlanForm> {
  final _note = TextEditingController();
  late final List<String> _picked;
  String? _main;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final plan = widget.sleep.planByDate[widget.sleep.today];
    _picked = [...?plan?.taskIds];
    _main = plan?.mainTaskId;
    _note.text = plan?.note ?? '';
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    setState(() {
      _error = null;
      if (_picked.remove(id)) {
        if (_main == id) _main = null;
      } else if (_picked.length >= maxPlanTasks) {
        _error = 'В плане — не больше $maxPlanTasks дел';
      } else {
        _picked.add(id);
      }
    });
  }

  void _setMain(String id) {
    setState(() {
      _error = null;
      if (_main == id) {
        _main = null;
        return;
      }
      if (!_picked.contains(id)) {
        if (_picked.length >= maxPlanTasks) {
          _error = 'В плане — не больше $maxPlanTasks дел';
          return;
        }
        _picked.add(id);
      }
      _main = id;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await ref
          .read(sleepRepositoryProvider)
          .savePlan(
            date: widget.sleep.today,
            taskIds: _picked,
            mainTaskId: _main,
            note: _note.text,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('План на день сохранён')));
      sleepBack(context);
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sleep = widget.sleep;
    final today = parseDate(sleep.today)!;
    final c = context.colors;
    final t = context.text;
    final day = dayTasks(
      widget.tasks,
      today: today,
      zone: widget.zone,
      planIds: sleep.planByDate[sleep.today]?.taskIds ?? const [],
    );
    final items = ref.watch(
      calendarItemsProvider(DateSpan(today, addDays(today, 1))),
    );
    final study = ref.watch(studyDataProvider).value;
    final lessons = study == null
        ? const <StudyEventItem>[]
        : buildStudyItems(study, fromDate: today, toDate: addDays(today, 1));
    final events = [
      for (final i in items.value ?? const <CalendarItem>[])
        if (i is EventItem && i is! StudyEventItem) i,
    ];
    final entry = sleep.lastNight;
    final view = entry?.view;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                dayTitle(today),
                key: const Key('plan-date'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ),
            if (sleep.morningDone)
              const StatusPill(
                key: Key('plan-done-pill'),
                label: 'План сделан',
                tone: StatusTone.success,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        AppCard(
          key: const Key('plan-sleep'),
          child: Row(
            children: [
              Icon(LucideIcons.moon, size: 20, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view == null
                          ? 'Сон этой ночью не записан'
                          : durationText(view.minutes),
                      style: t.bodyStrong,
                    ),
                    if (view != null)
                      Text(
                        '${view.bedLocal} → ${view.wakeLocal}',
                        style: t.numS.copyWith(color: c.textSecondary),
                      ),
                  ],
                ),
              ),
              if (view == null)
                OutlinedButton(
                  key: const Key('plan-record-sleep'),
                  onPressed: () => unawaited(showSleepEntrySheet(context)),
                  child: const Text('Записать'),
                )
              else
                TextButton(
                  key: const Key('plan-edit-sleep'),
                  onPressed: () => unawaited(
                    showSleepEntrySheet(context, date: entry!.date),
                  ),
                  child: const Text('Изменить'),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        RitualHeader(
          title: 'ЗАДАЧИ НА СЕГОДНЯ',
          trailing: 'в плане ${_picked.length} из $maxPlanTasks',
        ),
        _tasksCard(context, day),
        if (lessons.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          RitualHeader(
            title: 'ПАРЫ',
            trailing:
                '${lessons.length} ${pluralRu(lessons.length, 'пара', 'пары', 'пар')}',
          ),
          AppCard(
            key: const Key('plan-lessons'),
            child: Column(
              children: [
                for (final l in lessons)
                  RitualInfoRow(
                    time: l.allDay
                        ? 'без времени'
                        : '${timeOf(l.start)}–${timeOf(l.end)}',
                    title: l.title,
                    caption: l.location,
                  ),
              ],
            ),
          ),
        ],
        if (events.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          RitualHeader(title: 'СОБЫТИЯ', trailing: '${events.length}'),
          AppCard(
            key: const Key('plan-events'),
            child: Column(
              children: [
                for (final e in events)
                  RitualInfoRow(
                    time: e.allDay
                        ? 'весь день'
                        : '${timeOf(e.start)}–${timeOf(e.end)}',
                    title: e.title,
                    caption: e.location,
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s4),
        const RitualHeader(title: 'ЗАМЕТКА К ДНЮ'),
        FormTextField(
          key: const Key('plan-note'),
          controller: _note,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: 'Необязательно: на что обратить внимание сегодня',
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (_error != null) FormError(_error!, key: const Key('plan-error')),
        FilledButton(
          key: const Key('plan-save'),
          onPressed: _saving ? null : _save,
          child: Text(
            sleep.morningDone ? 'Сохранить изменения' : 'Готово — в день',
          ),
        ),
      ],
    );
  }

  Widget _tasksCard(BuildContext context, DayTasks day) {
    final c = context.colors;
    final t = context.text;
    // Выбранные задачи, которых уже нет среди открытых: сделанные и удалённые.
    final doneInPlan = [
      for (final e in day.done)
        if (_picked.contains(e.task.id)) e,
    ];
    if (day.open.isEmpty && doneInPlan.isEmpty && day.missing.isEmpty) {
      return AppCard(
        key: const Key('plan-tasks-empty'),
        child: Row(
          children: [
            Icon(LucideIcons.check, size: 20, color: c.textSecondary),
            const SizedBox(width: AppSpacing.s3),
            Text('На сегодня задач нет', style: t.body),
          ],
        ),
      );
    }
    return AppCard(
      key: const Key('plan-tasks'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
      child: Column(
        children: [
          for (final e in day.open)
            _TaskPickRow(
              entry: e,
              zone: widget.zone,
              picked: _picked.contains(e.task.id),
              main: _main == e.task.id,
              onToggle: () => _toggle(e.task.id),
              onMain: () => _setMain(e.task.id),
            ),
          for (final e in doneInPlan)
            _TaskPickRow(
              entry: e,
              zone: widget.zone,
              picked: true,
              main: _main == e.task.id,
              done: true,
              onToggle: () => _toggle(e.task.id),
              onMain: () => _setMain(e.task.id),
            ),
          for (final id in day.missing)
            _MissingRow(id: id, onRemove: () => _toggle(id)),
        ],
      ),
    );
  }
}

class _TaskPickRow extends StatelessWidget {
  const _TaskPickRow({
    required this.entry,
    required this.zone,
    required this.picked,
    required this.main,
    required this.onToggle,
    required this.onMain,
    this.done = false,
  });

  final TaskEntry entry;
  final tz.Location zone;
  final bool picked;
  final bool main;
  final bool done;
  final VoidCallback onToggle;
  final VoidCallback onMain;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final id = entry.task.id;
    return InkWell(
      key: Key('plan-task-$id'),
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpacing.s4),
        child: Row(
          children: [
            Semantics(
              checked: picked,
              label: picked ? 'В плане' : 'Не в плане',
              excludeSemantics: true,
              child: Icon(
                picked ? LucideIcons.squareCheck : LucideIcons.square,
                size: 22,
                color: picked ? c.accent : c.textTertiary,
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.task.title,
                      style: t.body.copyWith(
                        decoration: done ? TextDecoration.lineThrough : null,
                        color: done ? c.textSecondary : c.textPrimary,
                      ),
                    ),
                    Text(
                      done ? 'сделано' : taskCaption(entry, zone),
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              key: Key('plan-main-$id'),
              tooltip: main ? 'Не главное' : 'Сделать главным',
              onPressed: onMain,
              icon: Icon(
                LucideIcons.star,
                size: 22,
                color: main ? c.accent : c.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingRow extends StatelessWidget {
  const _MissingRow({required this.id, required this.onRemove});

  final String id;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s2,
      ),
      child: Row(
        key: Key('plan-missing-$id'),
        children: [
          Icon(LucideIcons.trash2, size: 20, color: c.textTertiary),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              'Задача удалена',
              style: context.text.body.copyWith(color: c.textSecondary),
            ),
          ),
          TextButton(
            key: Key('plan-missing-remove-$id'),
            onPressed: onRemove,
            child: const Text('Убрать'),
          ),
        ],
      ),
    );
  }
}
