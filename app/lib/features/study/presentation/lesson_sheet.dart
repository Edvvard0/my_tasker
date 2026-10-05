import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/presentation/schedule_editors.dart';

/// Лист занятия [lessonKey] на дату [date]: сведения, отметка
/// посещаемости («Был / Пропустил / Отменена преподавателем») и изменения
/// («для всех пар» — правка пары, «только на эту дату» — изменение на
/// дату).
Future<void> showLessonSheet(
  BuildContext context, {
  required String date,
  required String lessonKey,
}) => showEditorSheet<void>(
  context,
  builder: (_) => LessonSheet(date: date, lessonKey: lessonKey),
);

/// Открывает лист занятия пары [slotId] по дате по расписанию
/// [scheduledDate] (из уведомления «Был на паре?»).
Future<void> showAttendanceSheet(
  BuildContext context, {
  required String slotId,
  required String scheduledDate,
}) => showLessonSheet(
  context,
  date: scheduledDate,
  lessonKey: 'slot:$slotId@$scheduledDate',
);

class LessonSheet extends ConsumerWidget {
  const LessonSheet({required this.date, required this.lessonKey, super.key});

  final String date;
  final String lessonKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(studyDataProvider).value;
    final c = context.colors;
    final t = context.text;
    if (data == null) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // Перенесённое занятие живёт в день `new_date`; ищем и в дате по
    // расписанию, и в соседних днях переноса.
    final day = data.dayOf(date);
    var lesson = day.lessons.where((l) => l.key == lessonKey).firstOrNull;
    var lessonDay = day;
    if (lesson == null) {
      final moved = lessonKey.startsWith('slot:')
          ? data.overrides
                .where(
                  (o) =>
                      o.action == OverrideAction.move &&
                      'slot:${o.slotId}@${o.date}' == lessonKey &&
                      o.newDate != null,
                )
                .firstOrNull
          : null;
      if (moved != null) {
        lessonDay = data.dayOf(moved.newDate!);
        lesson = lessonDay.lessons.where((l) => l.key == lessonKey).firstOrNull;
      }
    }
    if (lesson == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Занятие'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Занятие не найдено: расписание изменилось.',
              key: const Key('lesson-missing'),
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final l = lesson;
    final mark = l.slotId == null
        ? null
        : data.markBySlotDate[(l.slotId!, l.scheduledDate)];
    final semester = data.semesterById[lessonDay.semesterId];
    final repo = ref.read(studyRepositoryProvider);
    final started = l.date.compareTo(data.today) <= 0;
    final canMark = l.isSlot && !l.isMovedAway && !l.cancelled && started;

    Future<void> setMark(AttendanceStatus s) async {
      await repo.mark(l.slotId!, l.scheduledDate, s);
      if (context.mounted) Navigator.of(context).pop();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: l.title ?? 'Занятие'),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${dateLabel(l.date)} · ${lessonTime(l.start, l.end)}',
                  key: const Key('lesson-when'),
                  style: t.body,
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    l.kind.label,
                    if (l.roomText.isNotEmpty) l.roomText,
                    if (l.number != null) '${l.number} пара',
                    cycleWeekLabel(semester, lessonDay.cycleWeek),
                  ].join(' · '),
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
                if (l.cancelled)
                  _note(
                    context,
                    'Пара отменена на эту дату: в пропуски не идёт.',
                  ),
                if (l.movedTo != null)
                  _note(context, 'Пара перенесена на ${dateLabel(l.movedTo!)}'),
                if (l.movedFrom != null)
                  _note(context, 'Перенесена с ${dateLabel(l.movedFrom!)}'),
                if (!l.isSlot)
                  _note(
                    context,
                    'Занятие особого дня: не отмечается и в пропуски не идёт.',
                  ),
                if (l.isSlot && !l.isMovedAway && !l.cancelled && !started)
                  _note(context, 'Отметить посещаемость можно в день занятия.'),
                const SizedBox(height: AppSpacing.s4),
                if (canMark) ...[
                  Text(
                    'Посещаемость',
                    style: t.label.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  Wrap(
                    spacing: AppSpacing.s2,
                    runSpacing: AppSpacing.s2,
                    children: [
                      FilterPill(
                        key: const Key('mark-present'),
                        label: 'Был',
                        icon: LucideIcons.circleCheck,
                        selected: mark?.status == AttendanceStatus.present,
                        onTap: () => setMark(AttendanceStatus.present),
                      ),
                      FilterPill(
                        key: const Key('mark-absent'),
                        label: 'Пропустил',
                        icon: LucideIcons.circleX,
                        selected: mark?.status == AttendanceStatus.absent,
                        onTap: () => setMark(AttendanceStatus.absent),
                      ),
                      FilterPill(
                        key: const Key('mark-cancelled'),
                        label: 'Отменена',
                        icon: LucideIcons.ban,
                        selected: mark?.status == AttendanceStatus.cancelled,
                        onTap: () => setMark(AttendanceStatus.cancelled),
                      ),
                      if (mark != null)
                        FilterPill(
                          key: const Key('mark-clear'),
                          label: 'Снять отметку',
                          selected: false,
                          onTap: () async {
                            await repo.unmark(l.slotId!, l.scheduledDate);
                            if (context.mounted) Navigator.of(context).pop();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s4),
                ],
                if (l.isSlot) ...[
                  if (l.cancelled || l.isMovedAway || l.changed)
                    _action(
                      context,
                      key: const Key('lesson-restore'),
                      icon: LucideIcons.undo2,
                      label: 'Вернуть по расписанию',
                      onTap: () async {
                        await repo.clearOverride(l.slotId!, l.scheduledDate);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                  _action(
                    context,
                    key: const Key('lesson-override'),
                    icon: LucideIcons.calendarClock,
                    label: 'Изменить только на эту дату',
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(
                        showOverrideEditor(
                          context,
                          slotId: l.slotId!,
                          date: l.scheduledDate,
                        ),
                      );
                    },
                  ),
                  _action(
                    context,
                    key: const Key('lesson-edit-slot'),
                    icon: LucideIcons.pencil,
                    label: 'Изменить для всех таких пар',
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(showSlotEditor(context, slotId: l.slotId));
                    },
                  ),
                ] else
                  _action(
                    context,
                    key: const Key('lesson-edit-rule'),
                    icon: LucideIcons.pencil,
                    label: 'Изменить особый день',
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(
                        showRuleEditor(
                          context,
                          ruleId: l.ruleId,
                          semesterId: lessonDay.semesterId!,
                        ),
                      );
                    },
                  ),
                const SizedBox(height: AppSpacing.s4),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _note(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.s2),
    child: Text(
      text,
      style: context.text.bodyS.copyWith(color: context.colors.textSecondary),
    ),
  );

  Widget _action(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => ListTile(
    key: key,
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, size: 20, color: context.colors.textSecondary),
    title: Text(label),
    onTap: onTap,
  );
}

/// Подпись «Занятие» для списков, где нужна иконка отметки.
AttendanceStatus? markOf(StudyData data, Lesson lesson) {
  final slotId = lesson.slotId;
  if (slotId == null) return null;
  return data.markBySlotDate[(slotId, lesson.scheduledDate)]?.status;
}
