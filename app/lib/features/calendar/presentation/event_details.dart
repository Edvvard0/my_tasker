import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_items.dart';
import 'package:my_tasker/features/calendar/domain/recurrence_draft.dart';
import 'package:my_tasker/features/calendar/presentation/event_editor.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/recurrence_scope_dialog.dart';

/// Карточка события (тап по блоку): время, слой, место, повторение
/// («по нечётным неделям, Вт»), напоминания; «Изменить» и «Удалить»
/// (для повторяющихся — «Только это · Это и следующие · Все в серии»).
Future<void> showEventDetails(BuildContext context, EventItem item) =>
    showEditorSheet<void>(context, builder: (_) => EventDetails(item: item));

class EventDetails extends ConsumerWidget {
  const EventDetails({required this.item, super.key});

  final EventItem item;

  String _when() {
    final start = item.start;
    final end = item.end;
    final day = dayTitle(dateOnly(start));
    if (item.allDay) {
      return item.firstDay == item.lastDay
          ? '$day · весь день'
          : '$day – ${dayTitle(item.lastDay)} · весь день';
    }
    if (dateOnly(start) == dateOnly(end) || !end.isAfter(start)) {
      return '$day · ${timeOf(start)}–${timeOf(end)}';
    }
    return '$day ${timeOf(start)} – ${dayTitle(dateOnly(end))} ${timeOf(end)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final event = item.event;
    final cycle = ref.watch(weekCycleProvider).value;
    final reminders = event.reminders ?? const <int>[];
    String? repeat;
    if (event.rrule != null) {
      repeat = describeRule(
        RRule.parse(event.rrule!, allDay: event.allDay),
        start: dateOnly(item.start),
        cycle: cycle,
      );
      if (item.alternating && !item.allDay) {
        repeat = '$repeat ${timeOf(item.start)}–${timeOf(item.end)}';
      }
    }
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c.textSecondary),
          const SizedBox(width: AppSpacing.s3),
          Expanded(child: Text(text, style: t.body)),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: item.title),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line(LucideIcons.clock, _when()),
                if (item.layerName != null)
                  line(LucideIcons.calendar, item.layerName!),
                if (item.location != null && item.location!.isNotEmpty)
                  line(LucideIcons.mapPin, item.location!),
                if (repeat != null) line(LucideIcons.repeat2, repeat),
                if (reminders.isNotEmpty)
                  line(
                    LucideIcons.bell,
                    reminders
                        .map(
                          (m) => RemindersField.label(m, allDay: event.allDay),
                        )
                        .join(', '),
                  ),
                if (event.description != null && event.description!.isNotEmpty)
                  line(LucideIcons.textAlignStart, event.description!),
                if (item.overridden)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                    child: Text(
                      'Этот экземпляр изменён отдельно от серии.',
                      style: t.bodyS.copyWith(color: c.textTertiary),
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
              OutlinedButton.icon(
                key: const Key('details-delete'),
                onPressed: () => _delete(context, ref),
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.danger,
                  side: BorderSide(color: c.danger),
                ),
                icon: const Icon(LucideIcons.trash2, size: 18),
                label: const Text('Удалить'),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const Key('details-edit'),
                onPressed: () {
                  final navigator = Navigator.of(context);
                  final root = navigator.context;
                  navigator.pop();
                  unawaited(
                    showEventEditor(
                      root,
                      eventId: event.id,
                      instanceKey: item.key,
                    ),
                  );
                },
                icon: const Icon(LucideIcons.pencil, size: 18),
                label: const Text('Изменить'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(calendarRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final event = item.event;
    var undo = () => repo.restoreEvent(event.id);
    if (event.isRecurring) {
      final scope = await showRecurrenceScopeDialog(
        context,
        title: 'Удалить повторяющееся событие',
      );
      if (scope == null) return;
      switch (scope) {
        case RecurrenceScope.only:
          await repo.cancelInstance(event, item.key);
          undo = () => repo.restoreInstance(event, item.key);
        case RecurrenceScope.following:
          await repo.deleteFollowing(event, item.key);
          undo = () async {};
        case RecurrenceScope.all:
          await repo.deleteEvent(event.id);
      }
    } else {
      await repo.deleteEvent(event.id);
    }
    if (!context.mounted) return;
    Navigator.of(context).pop();
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Удалено: «${item.title}»'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(label: 'Отменить', onPressed: undo),
        ),
      );
  }
}
