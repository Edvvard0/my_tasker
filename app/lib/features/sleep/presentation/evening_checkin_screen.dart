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
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/sleep/application/ritual_tasks.dart';
import 'package:my_tasker/features/sleep/application/sleep_providers.dart';
import 'package:my_tasker/features/sleep/data/sleep_repository.dart';
import 'package:my_tasker/features/sleep/domain/sleep_format.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/sleep/domain/sleep_validation.dart'
    show maxCheckinTasks;
import 'package:my_tasker/features/sleep/presentation/ritual_widgets.dart';
import 'package:my_tasker/features/sleep/presentation/sleep_widgets.dart';
import 'package:my_tasker/features/tasks/application/task_providers.dart'
    show TaskListData;
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';
import 'package:my_tasker/features/tasks/presentation/task_card.dart'
    show TaskCheckbox;
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;
import 'package:timezone/timezone.dart' as tz;

/// «Вечерний чек-ин»: что сделано сегодня, что перенести (на завтра или на
/// дату), оценка дня 1–5 и заметка. Перенос меняет сроки задач обычными
/// правками через синхронизацию (`SleepRepository.applyCarryOver`); решения
/// пишутся в чек-ин журналом намерения.
class EveningCheckinScreen extends ConsumerWidget {
  const EveningCheckinScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('evening-checkin'),
      title: 'Вечерний чек-ин',
      parentLabel: 'Сон',
      onBack: () => sleepBack(context),
      child: SleepBody(
        builder: (context, sleep) => RitualTasksBody(
          builder: (context, tasks, zone) =>
              _CheckinForm(sleep: sleep, tasks: tasks, zone: zone),
        ),
      ),
    );
  }
}

class _CheckinForm extends ConsumerStatefulWidget {
  const _CheckinForm({
    required this.sleep,
    required this.tasks,
    required this.zone,
  });

  final SleepData sleep;
  final TaskListData tasks;
  final tz.Location zone;

  @override
  ConsumerState<_CheckinForm> createState() => _CheckinFormState();
}

class _CheckinFormState extends ConsumerState<_CheckinForm> {
  final _note = TextEditingController();
  final Map<String, CarryDecision> _carry = {};
  int? _rating;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final checkin = widget.sleep.checkinByDate[widget.sleep.today];
    if (checkin != null) {
      _rating = checkin.rating;
      _note.text = checkin.note ?? '';
      for (final d in checkin.carryOver) {
        _carry[d.taskId] = d;
      }
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  DayTasks _day() => dayTasks(
    widget.tasks,
    today: parseDate(widget.sleep.today)!,
    zone: widget.zone,
    planIds: widget.sleep.planByDate[widget.sleep.today]?.taskIds ?? const [],
  );

  Future<void> _toggleDone(TaskEntry entry) async {
    await ref
        .read(taskRepositoryProvider)
        .toggleDone(
          entry.task,
          instanceDate: entry.instanceDate,
          localToday: ref.read(todayProvider),
        );
  }

  Future<void> _pickDate(String taskId) async {
    final today = parseDate(widget.sleep.today)!;
    final tomorrow = addDays(today, 1);
    final picked = await showDatePicker(
      context: context,
      initialDate: tomorrow,
      firstDate: tomorrow,
      lastDate: DateTime(maxYear),
      locale: const Locale('ru'),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _carry[taskId] = CarryDecision.onDate(
        taskId,
        formatDate(civil(picked.year, picked.month, picked.day)),
      );
    });
  }

  Future<void> _save(DayTasks day) async {
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(sleepRepositoryProvider);
    final openIds = {for (final e in day.open) e.task.id};
    // Переносим только то, что ещё не закрыто и не повторяется...
    final decisions = [
      for (final d in _carry.values)
        if (openIds.contains(d.taskId)) d,
    ];
    // ...а в журнал намерения кладём и прежние решения по задачам, которые
    // уже перенесены (их нет среди открытых): повторное сохранение чек-ина
    // не стирает историю.
    final earlier = widget.sleep.checkinByDate[widget.sleep.today]?.carryOver;
    final journal = [
      for (final d in earlier ?? const <CarryDecision>[])
        if (!openIds.contains(d.taskId)) d,
      ...decisions,
    ];
    try {
      await repo.saveCheckin(
        date: widget.sleep.today,
        doneTaskIds: [
          for (final e in day.done.take(maxCheckinTasks)) e.task.id,
        ],
        carryOver: journal.length > maxCheckinTasks
            ? journal.sublist(journal.length - maxCheckinTasks)
            : journal,
        rating: _rating,
        note: _note.text,
      );
      final outcome = await repo.applyCarryOver(widget.sleep.today, decisions);
      if (!mounted) return;
      final moved = outcome.moved.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            moved == 0
                ? 'Чек-ин сохранён'
                : 'Чек-ин сохранён · перенесено $moved '
                      '${pluralRu(moved, 'задача', 'задачи', 'задач')}',
          ),
        ),
      );
      sleepBack(context);
    } on ValidationError catch (e) {
      _failSave(e.message);
    } on Object catch (e) {
      // Например, задачу удалили на другом устройстве, пока шло сохранение.
      _failSave(
        e is StateError
            ? 'Задача удалена на другом устройстве. Обновите список и '
                  'сохраните ещё раз.'
            : 'Не удалось сохранить чек-ин. Повторите ещё раз.',
      );
    }
  }

  void _failSave(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _saving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sleep = widget.sleep;
    final c = context.colors;
    final t = context.text;
    final day = _day();
    final carryable = [
      for (final e in day.open)
        if (!e.task.isRecurring) e,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                dayTitle(parseDate(sleep.today)!),
                key: const Key('checkin-date'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ),
            if (sleep.eveningDone)
              const StatusPill(
                key: Key('checkin-done-pill'),
                label: 'Чек-ин сделан',
                tone: StatusTone.success,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        RitualHeader(title: 'СДЕЛАНО СЕГОДНЯ', trailing: '${day.done.length}'),
        AppCard(
          key: const Key('checkin-done'),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
          child: day.done.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.s3),
                  child: Text(
                    'Пока ни одной закрытой задачи. Отметьте сделанное ниже.',
                    key: const Key('checkin-done-empty'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                )
              : Column(
                  children: [
                    for (final e in day.done)
                      _TaskRow(
                        entry: e,
                        zone: widget.zone,
                        done: true,
                        onToggle: () => unawaited(_toggleDone(e)),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.s4),
        RitualHeader(
          title: 'НЕ СДЕЛАНО · ЧТО ПЕРЕНЕСТИ',
          trailing: '${day.open.length}',
        ),
        if (day.open.isEmpty)
          AppCard(
            key: const Key('checkin-open-empty'),
            child: Row(
              children: [
                Icon(LucideIcons.check, size: 20, color: c.textSecondary),
                const SizedBox(width: AppSpacing.s3),
                Text('Всё закрыто — переносить нечего', style: t.body),
              ],
            ),
          )
        else ...[
          AppCard(
            key: const Key('checkin-open'),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
            child: Column(
              children: [
                for (final e in day.open)
                  _TaskRow(
                    entry: e,
                    zone: widget.zone,
                    done: false,
                    onToggle: () => unawaited(_toggleDone(e)),
                    carry: e.task.isRecurring ? null : _carry[e.task.id],
                    recurring: e.task.isRecurring,
                    onCarry: (d) => setState(() {
                      if (d == null) {
                        _carry.remove(e.task.id);
                      } else {
                        _carry[e.task.id] = d;
                      }
                    }),
                    onPickDate: () => unawaited(_pickDate(e.task.id)),
                  ),
              ],
            ),
          ),
          if (carryable.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('checkin-carry-all'),
                onPressed: () => setState(() {
                  for (final e in carryable) {
                    _carry[e.task.id] = CarryDecision.tomorrow(e.task.id);
                  }
                }),
                child: const Text('Перенести всё на завтра'),
              ),
            ),
        ],
        const SizedBox(height: AppSpacing.s4),
        const RitualHeader(title: 'КАК ПРОШЁЛ ДЕНЬ'),
        RatingRow(
          value: _rating,
          onChanged: (v) => setState(() => _rating = v),
          keyPrefix: 'checkin-rating',
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('тяжело', style: t.caption.copyWith(color: c.textTertiary)),
              Text('отлично', style: t.caption.copyWith(color: c.textTertiary)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        const RitualHeader(title: 'ЗАМЕТКА'),
        FormTextField(
          key: const Key('checkin-note'),
          controller: _note,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: 'Необязательно: что запомнить о дне',
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (_error != null) FormError(_error!, key: const Key('checkin-error')),
        FilledButton(
          key: const Key('checkin-save'),
          onPressed: _saving ? null : () => _save(day),
          child: Text(
            sleep.eveningDone ? 'Сохранить изменения' : 'Завершить день',
          ),
        ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.entry,
    required this.zone,
    required this.done,
    required this.onToggle,
    this.carry,
    this.recurring = false,
    this.onCarry,
    this.onPickDate,
  });

  final TaskEntry entry;
  final tz.Location zone;
  final bool done;
  final VoidCallback onToggle;
  final CarryDecision? carry;
  final bool recurring;
  final ValueChanged<CarryDecision?>? onCarry;
  final VoidCallback? onPickDate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final id = entry.task.id;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            key: Key('checkin-task-$id'),
            children: [
              KeyedSubtree(
                key: Key('checkin-check-$id'),
                child: TaskCheckbox(
                  checked: done,
                  priority: entry.task.priority,
                  onChanged: onToggle,
                ),
              ),
              Expanded(
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
                      recurring
                          ? 'повторяется — не переносится'
                          : taskCaption(entry, zone),
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!done && !recurring)
            Padding(
              padding: const EdgeInsets.only(left: 44, bottom: AppSpacing.s2),
              child: ChipRow(
                children: [
                  FilterPill(
                    key: Key('checkin-keep-$id'),
                    label: 'Оставить',
                    selected: carry == null,
                    onTap: () => onCarry!(null),
                  ),
                  FilterPill(
                    key: Key('checkin-tomorrow-$id'),
                    label: 'На завтра',
                    selected: carry != null && carry!.isTomorrow,
                    onTap: () => onCarry!(CarryDecision.tomorrow(id)),
                  ),
                  FilterPill(
                    key: Key('checkin-date-$id'),
                    label: carry != null && !carry!.isTomorrow
                        ? dateShort(carry!.date!)
                        : 'На дату',
                    selected: carry != null && !carry!.isTomorrow,
                    icon: LucideIcons.calendar,
                    onTap: onPickDate,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
