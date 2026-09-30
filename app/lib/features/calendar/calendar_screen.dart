import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/module_placeholder.dart';
import 'package:my_tasker/features/calendar/calendar_tasks_switcher.dart';

/// «Календарь». ЗАГЛУШКА до этапа 2.
class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePlaceholder(
      title: 'Календарь',
      icon: LucideIcons.calendar,
      color: context.colors.moduleCalendar,
      description: 'Расписание, день, 3 дня, неделя и месяц.',
      stage: 2,
      header: const CalendarTasksSwitcher(tasksSelected: false),
    );
  }
}

/// «Задачи» — вкладка внутри «Календаря». ЗАГЛУШКА до этапа 2.
class TasksScreen extends StatelessWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePlaceholder(
      title: 'Календарь',
      icon: LucideIcons.circleCheck,
      color: context.colors.moduleCalendar,
      description: 'Списки задач, бэклог, статусы и приоритеты P1–P5.',
      stage: 2,
      header: const CalendarTasksSwitcher(tasksSelected: true),
    );
  }
}
