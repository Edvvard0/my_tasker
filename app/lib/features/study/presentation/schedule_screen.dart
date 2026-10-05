import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/presentation/lesson_sheet.dart';
import 'package:my_tasker/features/study/presentation/study_body.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/study/presentation/study_widgets.dart';

/// Вид расписания учёбы.
enum ScheduleMode {
  day('День'),
  week('Неделя');

  const ScheduleMode(this.label);

  final String label;
}

/// «Расписание»: занятия дня или недели с учётом особых дней, праздников
/// и изменений на дату; нажатие на занятие открывает отметку посещаемости
/// и изменения.
class ScheduleScreen extends ConsumerStatefulWidget {
  const ScheduleScreen({super.key});

  @override
  ConsumerState<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends ConsumerState<ScheduleScreen> {
  ScheduleMode _mode = ScheduleMode.day;
  DateTime? _focus;

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(todayProvider);
    final focus = _focus ?? today;
    return ScreenScaffold(
      key: const Key('schedule-screen'),
      title: 'Расписание',
      parentLabel: 'Учёба',
      onBack: () => studyBack(context),
      actions: [
        IconButton(
          key: const Key('schedule-edit'),
          tooltip: 'Редактор расписания',
          onPressed: () => context.push('/study/schedule/edit'),
          icon: const Icon(LucideIcons.slidersHorizontal, size: 22),
        ),
      ],
      child: StudyBody(
        builder: (context, data) {
          final step = _mode == ScheduleMode.day ? 1 : 7;
          final title = _mode == ScheduleMode.day
              ? dayTitle(focus)
              : weekRange(mondayOf(focus));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChipRow(
                children: [
                  for (final m in ScheduleMode.values)
                    FilterPill(
                      key: Key('schedule-mode-${m.name}'),
                      label: m.label,
                      selected: _mode == m,
                      onTap: () => setState(() => _mode = m),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.s2),
              Row(
                children: [
                  IconButton(
                    key: const Key('schedule-prev'),
                    tooltip: 'Назад',
                    onPressed: () =>
                        setState(() => _focus = addDays(focus, -step)),
                    icon: const Icon(LucideIcons.chevronLeft, size: 22),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      key: const Key('schedule-title'),
                      textAlign: TextAlign.center,
                      style: context.text.h3,
                    ),
                  ),
                  IconButton(
                    key: const Key('schedule-next'),
                    tooltip: 'Вперёд',
                    onPressed: () =>
                        setState(() => _focus = addDays(focus, step)),
                    icon: const Icon(LucideIcons.chevronRight, size: 22),
                  ),
                  TextButton(
                    key: const Key('schedule-today'),
                    onPressed: () => setState(() => _focus = null),
                    child: const Text('Сегодня'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s2),
              if (_mode == ScheduleMode.day)
                _DayCard(data: data, date: formatDate(focus))
              else
                for (var i = 0; i < 7; i++) ...[
                  _DayCard(
                    data: data,
                    date: formatDate(addDays(mondayOf(focus), i)),
                    compact: true,
                  ),
                  const SizedBox(height: AppSpacing.s2),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.data,
    required this.date,
    this.compact = false,
  });

  final StudyData data;
  final String date;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final day = data.dayOf(date);
    final semester = data.semesterById[day.semesterId];
    final week = day.cycleWeek == null || semester == null
        ? null
        : semester.weekLabel(day.cycleWeek!);
    final c = context.colors;
    return AppCard(
      key: Key('schedule-day-$date'),
      padding: EdgeInsets.all(compact ? AppSpacing.s3 : AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DayHeader(day: day, weekLabel: week),
          DayNote(day: day),
          if (day.lessons.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
              child: Text(
                switch (day.kind) {
                  DayKind.noSemester => 'Вне семестра',
                  DayKind.holiday => 'Праздник: занятий нет',
                  _ => 'Занятий нет',
                },
                key: Key('schedule-empty-$date'),
                style: context.text.bodyS.copyWith(color: c.textTertiary),
              ),
            )
          else
            for (final l in day.lessons)
              LessonTile(
                key: Key('lesson-${l.key}'),
                lesson: l,
                mark: markOf(data, l),
                compact: compact,
                onTap: () =>
                    showLessonSheet(context, date: day.date, lessonKey: l.key),
              ),
        ],
      ),
    );
  }
}
