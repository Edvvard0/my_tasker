import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

/// Иконка отметки посещаемости: был, пропустил, отменена, не отмечено.
class AttendanceMarkIcon extends StatelessWidget {
  const AttendanceMarkIcon({required this.status, this.size = 20, super.key});

  /// `null` — не отмечено.
  final AttendanceStatus? status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, color, label) = switch (status) {
      AttendanceStatus.present => (
        LucideIcons.circleCheck,
        c.textPrimary,
        'Был',
      ),
      AttendanceStatus.absent => (LucideIcons.circleX, c.danger, 'Пропустил'),
      AttendanceStatus.cancelled => (
        LucideIcons.ban,
        c.textSecondary,
        'Отменена',
      ),
      null => (LucideIcons.circle, c.textTertiary, 'Не отмечено'),
    };
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Icon(icon, size: size, color: color),
    );
  }
}

/// Занятие в списке дня: время, название, тип и аудитория; отменённое
/// зачёркнуто, перенесённое и изменённое помечены.
class LessonTile extends StatelessWidget {
  const LessonTile({
    required this.lesson,
    this.mark,
    this.onTap,
    this.compact = false,
    super.key,
  });

  final Lesson lesson;

  /// Отметка посещаемости занятия (`null` — не отмечено); у занятий особых
  /// дней иконки нет.
  final AttendanceStatus? mark;
  final VoidCallback? onTap;

  /// Плотная строка для недельного вида.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final cancelled = lesson.cancelled || mark == AttendanceStatus.cancelled;
    final muted = cancelled || lesson.isMovedAway;
    final titleStyle = (compact ? t.bodyS : t.bodyStrong).copyWith(
      color: muted ? c.textTertiary : c.textPrimary,
      decoration: muted ? TextDecoration.lineThrough : null,
    );
    final notes = <String>[
      lesson.kind.label,
      if (lesson.roomText.isNotEmpty) lesson.roomText,
      if (lesson.number != null) '${lesson.number} пара',
    ];
    final badges = <String>[
      if (lesson.cancelled) 'отменена',
      if (!lesson.cancelled && mark == AttendanceStatus.cancelled)
        'отменена преподавателем',
      if (lesson.movedTo != null) 'перенесена на ${dateLabel(lesson.movedTo!)}',
      if (lesson.movedFrom != null) 'перенос с ${dateLabel(lesson.movedFrom!)}',
      if (lesson.changed && lesson.movedFrom == null) 'изменена',
    ];
    return Semantics(
      button: onTap != null,
      child: InkWell(
        borderRadius: AppRadii.borderL,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? AppSpacing.s2 : AppSpacing.s3,
            vertical: compact ? AppSpacing.s1 : AppSpacing.s3,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: compact ? 52 : 64,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lesson.start ?? '—',
                      style: t.numS.copyWith(
                        color: muted ? c.textTertiary : c.textPrimary,
                      ),
                    ),
                    if (lesson.end != null)
                      Text(
                        lesson.end!,
                        style: t.numS.copyWith(color: c.textTertiary),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lesson.title ?? 'Занятие',
                      style: titleStyle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      notes.join(' · '),
                      style: t.caption.copyWith(color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (badges.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          badges.join(' · '),
                          style: t.caption.copyWith(
                            color: c.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (lesson.isSlot && !lesson.isMovedAway)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.s2),
                  child: AttendanceMarkIcon(status: mark),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Шапка дня расписания: день недели, дата, неделя цикла и вид дня.
class DayHeader extends StatelessWidget {
  const DayHeader({required this.day, required this.weekLabel, super.key});

  final ScheduleDay day;

  /// Подпись недели цикла («Чётная»); `null` — вне семестра.
  final String? weekLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Row(
      children: [
        Expanded(
          child: Text(
            dateLabel(day.date),
            style: t.h3,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (weekLabel != null)
          Text(weekLabel!, style: t.caption.copyWith(color: c.textSecondary)),
        if (day.kind == DayKind.special || day.kind == DayKind.holiday) ...[
          const SizedBox(width: AppSpacing.s2),
          StatusPill(
            label: day.kind == DayKind.holiday ? 'Праздник' : 'Особый день',
            tone: day.kind == DayKind.holiday
                ? StatusTone.neutral
                : StatusTone.info,
          ),
        ],
      ],
    );
  }
}

/// Название особого дня или праздника под шапкой.
class DayNote extends StatelessWidget {
  const DayNote({required this.day, super.key});

  final ScheduleDay day;

  @override
  Widget build(BuildContext context) {
    final name = day.name;
    if (name == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s1),
      child: Text(
        name,
        style: context.text.bodyS.copyWith(color: context.colors.textSecondary),
      ),
    );
  }
}

/// Аудитория как пилюля «к1 28».
class RoomChip extends StatelessWidget {
  const RoomChip({required this.building, required this.room, super.key});

  final String? building;
  final String? room;

  @override
  Widget build(BuildContext context) {
    final text = formatRoom(building, room);
    if (text.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderFull,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.doorOpen, size: 13, color: c.textSecondary),
          const SizedBox(width: 4),
          Text(text, style: context.text.label.copyWith(color: c.textPrimary)),
        ],
      ),
    );
  }
}

/// Карточка со списком строк-`ListTile`: прозрачный `Material` внутри
/// карточки, чтобы нажатия и подсветка строк были видны на её фоне.
class ListCard extends StatelessWidget {
  const ListCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: Material(type: MaterialType.transparency, child: child),
  );
}
