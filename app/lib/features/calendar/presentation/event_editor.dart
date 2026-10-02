import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/domain/recurrence_draft.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/recurrence_field.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/recurrence_scope_dialog.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/timezone_picker.dart';
import 'package:timezone/timezone.dart' as tz;

/// Открывает редактор события. [eventId] — правка существующего (с
/// [instanceKey] — конкретного экземпляра повторяющегося); иначе создание
/// с начальными [initialDate]/[initialTime].
Future<void> showEventEditor(
  BuildContext context, {
  String? eventId,
  String? instanceKey,
  DateTime? initialDate,
  TimeOfDay? initialTime,
  int? initialDuration,
}) => showEditorSheet<void>(
  context,
  builder: (_) => EventEditor(
    eventId: eventId,
    instanceKey: instanceKey,
    initialDate: initialDate,
    initialTime: initialTime,
    initialDuration: initialDuration,
  ),
);

/// Редактор события: слой, «весь день», дата и время, длительность,
/// таймзона, место, описание, повторение (в т. ч. «чёт/нечёт»),
/// напоминания. Для повторяющихся спрашивает «Только это · Это и
/// следующие · Все в серии» (spec 5.4).
class EventEditor extends ConsumerStatefulWidget {
  const EventEditor({
    this.eventId,
    this.instanceKey,
    this.initialDate,
    this.initialTime,
    this.initialDuration,
    super.key,
  });

  final String? eventId;
  final String? instanceKey;
  final DateTime? initialDate;
  final TimeOfDay? initialTime;
  final int? initialDuration;

  @override
  ConsumerState<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends ConsumerState<EventEditor> {
  final _title = TextEditingController();
  final _location = TextEditingController();
  final _description = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  EventEntity? _original;
  String? _calendarId;
  bool _allDay = false;
  DateTime? _startDate;
  DateTime? _endDate;
  TimeOfDay _startTime = const TimeOfDay(hour: 9, minute: 0);
  int _duration = 60;
  String _zone = 'UTC';
  RecurrenceDraft _repeat = RecurrenceDraft.none;
  List<int> _reminders = [];
  String? _error;
  bool _saving = false;

  // Экземпляр, который правим: исходный слот и его дата в поясе события.
  String? _instanceKey;
  DateTime? _instanceOriginalDate;

  bool get _isNew => widget.eventId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _initNew();
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    super.dispose();
  }

  void _initNew() {
    final today = ref.read(todayProvider);
    final device = ref.read(deviceTimeZoneProvider);
    _zone = isIanaLocation(device) ? device.name : 'UTC';
    _startDate = widget.initialDate ?? today;
    _endDate = _startDate;
    final time = widget.initialTime;
    if (time != null) {
      _startTime = time;
    } else if (widget.initialDate == null) {
      final now = ref.read(nowWallProvider);
      _startTime = TimeOfDay(hour: (now.hour + 1) % 24, minute: 0);
    }
    _duration = widget.initialDuration ?? 60;
    _loading = false;
    unawaited(_pickDefaultCalendar());
  }

  Future<void> _pickDefaultCalendar() async {
    final layers = await ref.read(calendarLayersProvider.future);
    if (!mounted) return;
    final real = [
      for (final l in layers)
        if (!l.isVirtual) l,
    ];
    if (real.isEmpty) return;
    setState(() => _calendarId ??= real.first.id);
  }

  Future<void> _load() async {
    final repo = ref.read(calendarRepositoryProvider);
    final event = await repo.getEvent(widget.eventId!);
    if (!mounted) return;
    if (event == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    final overrides = await repo.overridesOf(event.id);
    if (!mounted) return;
    final cycle = ref.read(weekCycleProvider).value;
    final key = widget.instanceKey;
    final override = key == null
        ? null
        : overrides.where((o) => o.originalStart == key).firstOrNull;
    setState(() {
      _original = event;
      _instanceKey = key;
      _calendarId = event.calendarId;
      _allDay = event.allDay;
      _title.text = override?.title ?? event.title;
      _location.text = override?.location ?? event.location ?? '';
      _description.text = override?.description ?? event.description ?? '';
      _reminders = [...?(override?.reminders ?? event.reminders)];
      _zone = event.tz ?? ref.read(deviceTimeZoneProvider).name;
      final series = event.series;
      if (event.allDay) {
        var start = event.startDate!;
        var end = event.endDate!;
        if (key != null && series != null) {
          final slot = series.slotOf(key);
          if (slot != null) {
            start = slot.start;
            end = slot.end;
          }
          _instanceOriginalDate = start;
          if (override?.startDate != null) {
            start = override!.startDate!;
            end = override.endDate!;
          }
        }
        _startDate = start;
        _endDate = end;
      } else {
        final zone = requireLocation(event.tz!);
        var start = event.startAt!;
        var end = event.endAt!;
        if (key != null && series != null) {
          final slot = series.slotOf(key);
          if (slot != null) {
            start = slot.start;
            end = slot.end;
          }
          _instanceOriginalDate = dateOnly(utcToWall(zone, start));
          if (override?.startAt != null) {
            start = override!.startAt!;
            end = override.endAt!;
          }
        }
        final wall = utcToWall(zone, start);
        _startDate = dateOnly(wall);
        _startTime = TimeOfDay(hour: wall.hour, minute: wall.minute);
        _duration = end.difference(start).inMinutes;
      }
      if (event.rrule != null) {
        final wallStart = event.allDay
            ? event.startDate!
            : dateOnly(utcToWall(requireLocation(event.tz!), event.startAt!));
        _repeat = RecurrenceDraft.fromRule(
          RRule.parse(event.rrule!, allDay: event.allDay),
          start: wallStart,
          zone: event.tz == null ? null : requireLocation(event.tz!),
          cycle: cycle,
        );
      }
      _loading = false;
    });
  }

  tz.Location get _location_ => requireLocation(_zone);

  DateTime _instant(DateTime date, TimeOfDay time) => wallToUtc(
    _location_,
    date.year,
    date.month,
    date.day,
    time.hour,
    time.minute,
  );

  /// Событие из полей формы (для новой серии — с началом [startDate]).
  EventEntity _compose({
    required DateTime startDate,
    String? rrule,
    List<int>? reminders,
  }) {
    final base =
        _original ??
        EventEntity(
          id:
              widget.eventId ??
              ref.read(calendarRepositoryProvider).newEventId(),
          calendarId: _calendarId ?? '',
          title: '',
          allDay: _allDay,
        );
    final loc = _location.text.trim();
    final desc = _description.text.trim();
    if (_allDay) {
      final endDate = _endDate == null || _endDate!.isBefore(startDate)
          ? startDate
          : _endDate!;
      return base.copyWith(
        calendarId: _calendarId,
        title: _title.text,
        location: loc.isEmpty ? null : loc,
        description: desc.isEmpty ? null : desc,
        allDay: true,
        startAt: null,
        endAt: null,
        tz: null,
        startDate: startDate,
        endDate: endDate,
        rrule: rrule,
        reminders: reminders,
      );
    }
    final start = _instant(startDate, _startTime);
    return base.copyWith(
      calendarId: _calendarId,
      title: _title.text,
      location: loc.isEmpty ? null : loc,
      description: desc.isEmpty ? null : desc,
      allDay: false,
      startAt: start,
      endAt: start.add(Duration(minutes: _duration)),
      tz: _zone,
      startDate: null,
      endDate: null,
      rrule: rrule,
      reminders: reminders,
    );
  }

  /// Правило и подходящее ему начало серии из выбранного [date].
  ({RRule? rule, DateTime start}) _ruleFor(DateTime date) {
    if (_repeat.isNone) return (rule: null, start: date);
    final cycle = ref.read(weekCycleProvider).value;
    final zone = _allDay ? null : _location_;
    var rule = _repeat.toRule(
      start: date,
      allDay: _allDay,
      zone: zone,
      cycle: cycle,
    )!;
    var start = date;
    if (_repeat.cycleWeek != null && cycle != null && cycle.isEnabled) {
      final weekday = rule.byDay.isEmpty
          ? weekdayIndex(date)
          : rule.byDay.first.weekday;
      start = cycle.firstDate(date, weekday, _repeat.cycleWeek!);
    } else {
      start = firstMatchingDate(rule, date);
    }
    if (start != date) {
      rule = _repeat.toRule(
        start: start,
        allDay: _allDay,
        zone: zone,
        cycle: cycle,
      )!;
    }
    return (rule: rule, start: start);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(calendarRepositoryProvider);
    try {
      if (_calendarId == null) {
        throw const ValidationError('Выберите календарь');
      }
      final reminders = _reminders.isEmpty ? null : [..._reminders];
      final original = _original;
      final today = ref.read(todayProvider);
      final date = _startDate ?? today;
      if (original == null) {
        final r = _ruleFor(date);
        await repo.createEvent(
          _compose(
            startDate: r.start,
            rrule: r.rule?.toRuleString(),
            reminders: reminders,
          ),
        );
      } else if (original.rrule == null || _instanceKey == null) {
        final r = _ruleFor(date);
        await repo.updateEvent(
          _compose(
            startDate: r.start,
            rrule: r.rule?.toRuleString(),
            reminders: reminders,
          ),
        );
      } else {
        final scope = await showRecurrenceScopeDialog(
          context,
          title: 'Изменить повторяющееся событие',
        );
        if (scope == null) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        await _saveScoped(repo, original, scope, reminders);
      }
      if (!mounted) return;
      final dropped = repo.lastDroppedOverrides;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      if (dropped > 0) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Исключения серии сброшены: $dropped. Их даты больше не '
              'совпадают с повторениями.',
            ),
          ),
        );
      }
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _saveScoped(
    CalendarRepository repo,
    EventEntity original,
    RecurrenceScope scope,
    List<int>? reminders,
  ) async {
    final key = _instanceKey!;
    final date = _startDate!;
    switch (scope) {
      case RecurrenceScope.only:
        final draftRule = _ruleFor(date).rule?.toRuleString();
        if (draftRule != original.rrule) {
          throw const ValidationError(
            'Повторение меняется только для «Все в серии» или '
            '«Это и следующие»',
          );
        }
        final composed = _compose(
          startDate: date,
          rrule: original.rrule,
          reminders: reminders,
        );
        await repo.overrideInstance(
          original,
          key,
          _instanceChange(original, composed, key),
        );
      case RecurrenceScope.following:
        final r = _ruleFor(date);
        await repo.splitFollowing(
          original,
          key,
          _compose(
            startDate: r.start,
            rrule: r.rule?.toRuleString(),
            reminders: reminders,
          ),
        );
      case RecurrenceScope.all:
        // Сдвиг экземпляра переносится на начало серии.
        final shift = daysBetween(_instanceOriginalDate ?? date, date);
        final masterStart = original.allDay
            ? original.startDate!
            : dateOnly(
                utcToWall(requireLocation(original.tz!), original.startAt!),
              );
        final r = _ruleFor(addDays(masterStart, shift));
        await repo.updateEvent(
          _compose(
            startDate: r.start,
            rrule: r.rule?.toRuleString(),
            reminders: reminders,
          ),
        );
    }
  }

  /// Что отличается у экземпляра от исходной серии: остальное — `null`
  /// («как в событии»).
  InstanceChange _instanceChange(
    EventEntity master,
    EventEntity composed,
    String key,
  ) {
    final series = master.series;
    final slot = series?.slotOf(key);
    DateTime? startAt;
    DateTime? endAt;
    DateTime? startDate;
    DateTime? endDate;
    if (master.allDay) {
      if (slot == null ||
          slot.start != composed.startDate ||
          slot.end != composed.endDate) {
        startDate = composed.startDate;
        endDate = composed.endDate;
      }
    } else if (slot == null ||
        slot.start != composed.startAt ||
        slot.end != composed.endAt) {
      startAt = composed.startAt;
      endAt = composed.endAt;
    }
    final same =
        (master.reminders ?? const <int>[]).join(',') ==
        (composed.reminders ?? const <int>[]).join(',');
    return InstanceChange(
      title: composed.title.trim() == master.title ? null : composed.title,
      description: composed.description == master.description
          ? null
          : (composed.description ?? ''),
      location: composed.location == master.location
          ? null
          : (composed.location ?? ''),
      startAt: startAt,
      endAt: endAt,
      startDate: startDate,
      endDate: endDate,
      reminders: same ? null : (composed.reminders ?? const []),
    );
  }

  Future<void> _delete() async {
    final original = _original;
    if (original == null) return;
    final repo = ref.read(calendarRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final key = _instanceKey;
    var undo = () => repo.restoreEvent(original.id);
    if (original.rrule != null && key != null) {
      final scope = await showRecurrenceScopeDialog(
        context,
        title: 'Удалить повторяющееся событие',
      );
      if (scope == null) return;
      switch (scope) {
        case RecurrenceScope.only:
          await repo.cancelInstance(original, key);
          undo = () => repo.restoreInstance(original, key);
        case RecurrenceScope.following:
          await repo.deleteFollowing(original, key);
          undo = () async {};
        case RecurrenceScope.all:
          await repo.deleteEvent(original.id);
      }
    } else {
      await repo.deleteEvent(original.id);
    }
    if (!mounted) return;
    final title = _title.text;
    Navigator.of(context).pop();
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Удалено: «$title»'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(label: 'Отменить', onPressed: undo),
        ),
      );
  }

  Future<void> _pickEnd() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTimeOfDay(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;
    final start = _startTime.hour * 60 + _startTime.minute;
    var end = picked.hour * 60 + picked.minute;
    if (end <= start) end += 24 * 60;
    setState(() => _duration = end - start);
  }

  TimeOfDay _endTimeOfDay() {
    final total = (_startTime.hour * 60 + _startTime.minute + _duration) % 1440;
    return TimeOfDay(hour: total ~/ 60, minute: total % 60);
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
          const SheetHeader(title: 'Событие'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Событие не найдено: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = ref.watch(todayProvider);
    final allLayers =
        ref.watch(calendarLayersProvider).value ?? const <CalendarLayer>[];
    final layers = [
      for (final l in allLayers)
        if (!l.isVirtual) l,
    ];
    final cycle = ref.watch(weekCycleProvider).value;
    final device = ref.watch(deviceTimeZoneProvider);
    final start = _startDate ?? today;
    final zone = findLocation(_zone);
    final endTime = _endTimeOfDay();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новое событие' : 'Событие'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('event-title'),
                      controller: _title,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Например, «Созвон Creora»',
                      ),
                    ),
                  ),
                  if (layers.isNotEmpty)
                    FormBlock(
                      label: 'Календарь',
                      child: ChipRow(
                        children: [
                          for (final l in layers)
                            FilterPill(
                              key: Key('event-layer-${l.id}'),
                              label: l.name,
                              selected: _calendarId == l.id,
                              onTap: () => setState(() => _calendarId = l.id),
                            ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s4),
                    child: Row(
                      children: [
                        Expanded(child: Text('Весь день', style: t.body)),
                        Switch(
                          key: const Key('event-all-day'),
                          value: _allDay,
                          onChanged: (v) => setState(() {
                            _allDay = v;
                            _reminders = [];
                            _endDate ??= _startDate;
                          }),
                        ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: _allDay ? 'Начало' : 'Дата',
                    child: DateChoiceRow(
                      keyPrefix: 'event-date',
                      today: today,
                      value: _startDate,
                      onChanged: (d) => setState(() {
                        final span = _startDate == null || _endDate == null
                            ? 0
                            : daysBetween(_startDate!, _endDate!);
                        _startDate = d;
                        _endDate = addDays(d!, span);
                      }),
                    ),
                  ),
                  if (_allDay)
                    FormBlock(
                      label: 'Конец (включительно)',
                      child: DateChoiceRow(
                        keyPrefix: 'event-end-date',
                        today: today,
                        value: _endDate,
                        onChanged: (d) => setState(() => _endDate = d),
                      ),
                    )
                  else ...[
                    FormBlock(
                      label: 'Начало',
                      child: TimeChoiceRow(
                        keyPrefix: 'event-time',
                        value: _startTime,
                        allowNone: false,
                        onChanged: (v) =>
                            setState(() => _startTime = v ?? _startTime),
                      ),
                    ),
                    FormBlock(
                      label:
                          'Длительность · до ${clockText(endTime.hour, endTime.minute)}',
                      child: ChipRow(
                        children: [
                          for (final m in const [15, 30, 45, 60, 90, 120])
                            FilterPill(
                              key: Key('event-duration-$m'),
                              label: durationText(m),
                              selected: _duration == m,
                              onTap: () => setState(() => _duration = m),
                            ),
                          FilterPill(
                            key: const Key('event-duration-pick'),
                            label:
                                const [
                                  15,
                                  30,
                                  45,
                                  60,
                                  90,
                                  120,
                                ].contains(_duration)
                                ? 'Другое'
                                : durationText(_duration),
                            selected: !const [
                              15,
                              30,
                              45,
                              60,
                              90,
                              120,
                            ].contains(_duration),
                            icon: LucideIcons.clock,
                            onTap: _pickEnd,
                          ),
                        ],
                      ),
                    ),
                    FormBlock(
                      label: 'Часовой пояс',
                      child: PickerTile(
                        key: const Key('event-timezone'),
                        icon: LucideIcons.globe,
                        text: zone == null
                            ? _zone
                            : '$_zone · ${utcOffsetLabel(zone, DateTime.now().toUtc())}',
                        onTap: () async {
                          final picked = await showTimeZonePicker(
                            context,
                            current: _zone,
                            deviceZone: device.name,
                          );
                          if (picked != null) setState(() => _zone = picked);
                        },
                      ),
                    ),
                  ],
                  FormBlock(
                    label: 'Повторение',
                    child: RecurrenceField(
                      draft: _repeat,
                      start: start,
                      cycle: cycle,
                      onChanged: (d) => setState(() => _repeat = d),
                      onOpenCycleSettings: () {
                        Navigator.of(context).pop();
                        context.go('/calendar/settings');
                      },
                    ),
                  ),
                  FormBlock(
                    label: 'Напоминания',
                    child: RemindersField(
                      value: _reminders,
                      allDay: _allDay,
                      onChanged: (v) => setState(() => _reminders = v),
                    ),
                  ),
                  FormBlock(
                    label: 'Место',
                    child: FormTextField(
                      key: const Key('event-location'),
                      controller: _location,
                      decoration: InputDecoration(
                        hintText: 'Аудитория, адрес или ссылка',
                        prefixIcon: Icon(
                          LucideIcons.mapPin,
                          size: 18,
                          color: c.textTertiary,
                        ),
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Описание',
                    child: FormTextField(
                      key: const Key('event-description'),
                      controller: _description,
                      minLines: 3,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(hintText: 'Заметки'),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: Row(
                        key: const Key('event-error'),
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
                    key: const Key('event-delete'),
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
                  key: const Key('event-save'),
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
