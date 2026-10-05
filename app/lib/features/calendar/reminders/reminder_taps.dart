import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/presentation/event_editor.dart';
import 'package:my_tasker/features/shell/app_router.dart';
import 'package:my_tasker/features/study/presentation/lesson_sheet.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';

/// Куда ведёт нажатие на уведомление-напоминание.
@immutable
sealed class ReminderTarget {
  const ReminderTarget();
}

/// Событие (экземпляр [key] — `original_start`).
class EventTarget extends ReminderTarget {
  const EventTarget(this.eventId, this.key);

  final String eventId;
  final String key;

  @override
  bool operator ==(Object other) =>
      other is EventTarget && other.eventId == eventId && other.key == key;

  @override
  int get hashCode => Object.hash(eventId, key);
}

/// Задача.
class TaskTarget extends ReminderTarget {
  const TaskTarget(this.taskId);

  final String taskId;

  @override
  bool operator ==(Object other) =>
      other is TaskTarget && other.taskId == taskId;

  @override
  int get hashCode => taskId.hashCode;
}

/// Занятие «Был на паре?» (Этап 7): пара [slotId] на дату по расписанию
/// [date].
class StudyTarget extends ReminderTarget {
  const StudyTarget(this.slotId, this.date);

  final String slotId;
  final String date;

  @override
  bool operator ==(Object other) =>
      other is StudyTarget && other.slotId == slotId && other.date == date;

  @override
  int get hashCode => Object.hash(slotId, date);
}

/// Разбирает `payload` уведомления (`event:<id>|<ключ>`, `task:<id>` или
/// `study:<пара>|<дата>`); `null` — не наше или битое.
ReminderTarget? parseReminderPayload(String? payload) {
  if (payload == null) return null;
  if (payload.startsWith('event:')) {
    final body = payload.substring(6);
    final bar = body.indexOf('|');
    if (bar <= 0 || bar == body.length - 1) return null;
    return EventTarget(body.substring(0, bar), body.substring(bar + 1));
  }
  if (payload.startsWith('task:')) {
    final id = payload.substring(5);
    return id.isEmpty ? null : TaskTarget(id);
  }
  if (payload.startsWith('study:')) {
    final body = payload.substring(6);
    final bar = body.indexOf('|');
    if (bar <= 0 || bar == body.length - 1) return null;
    return StudyTarget(body.substring(0, bar), body.substring(bar + 1));
  }
  return null;
}

/// Шина нажатий на уведомления: плагин (в том числе при холодном старте
/// приложения из уведомления) кладёт сюда `payload`, а интерфейс, когда
/// готов, забирает цель. Нажатие, пришедшее до подписки, ждёт её.
class ReminderTaps {
  final StreamController<ReminderTarget> _controller =
      StreamController<ReminderTarget>.broadcast();
  ReminderTarget? _pending;

  Stream<ReminderTarget> get stream => _controller.stream;

  /// Нажатие с `payload`; чужие и битые игнорируются.
  void add(String? payload) {
    final target = parseReminderPayload(payload);
    if (target == null) return;
    if (_controller.hasListener) {
      _controller.add(target);
    } else {
      _pending = target;
    }
  }

  /// Нажатие, пришедшее до подписки (однократно).
  ReminderTarget? takePending() {
    final target = _pending;
    _pending = null;
    return target;
  }
}

final reminderTapsProvider = Provider<ReminderTaps>((ref) => ReminderTaps());

/// Открывает событие или задачу по нажатию на напоминание. Следит корень
/// приложения.
final reminderTapHandlerProvider = Provider<void>((ref) {
  final taps = ref.watch(reminderTapsProvider);
  Future<void> handle(ReminderTarget target) async {
    // Холодный старт: оболочка ещё строится — немного ждём.
    BuildContext? context;
    for (var i = 0; i < 50; i++) {
      if (!ref.mounted) return;
      context = rootNavigatorKey.currentContext;
      if (context != null && ref.read(authControllerProvider) is SignedIn) {
        break;
      }
      context = null;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (context == null || !context.mounted) return;
    switch (target) {
      case EventTarget():
        final event = await ref
            .read(calendarRepositoryProvider)
            .getEvent(target.eventId);
        if (event == null || !context.mounted) return;
        await showEventEditor(
          context,
          eventId: target.eventId,
          instanceKey: target.key,
        );
      case TaskTarget():
        final task = await ref
            .read(taskRepositoryProvider)
            .getTask(target.taskId);
        if (task == null || !context.mounted) return;
        await showTaskEditor(context, taskId: target.taskId);
      case StudyTarget():
        await showAttendanceSheet(
          context,
          slotId: target.slotId,
          scheduledDate: target.date,
        );
    }
  }

  final sub = taps.stream.listen((t) => unawaited(handle(t)));
  ref.onDispose(sub.cancel);
  final pending = taps.takePending();
  if (pending != null) unawaited(handle(pending));
});
