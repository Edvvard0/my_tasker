import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Сегментированный переключатель «Календарь / Задачи» (02, 3.1: «Задачи» —
/// вкладка внутри «Календаря»). Каждый сегмент — отдельный маршрут.
class CalendarTasksSwitcher extends StatelessWidget {
  const CalendarTasksSwitcher({required this.tasksSelected, super.key});

  final bool tasksSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s1),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: AppRadii.borderFull,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Segment(
              key: const Key('segment-calendar'),
              label: 'Календарь',
              selected: !tasksSelected,
              onTap: () => context.go('/calendar'),
            ),
            _Segment(
              key: const Key('segment-tasks'),
              label: 'Задачи',
              selected: tasksSelected,
              onTap: () => context.go('/calendar/tasks'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: AppRadii.borderFull,
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? c.surface1 : Colors.transparent,
            borderRadius: AppRadii.borderFull,
          ),
          child: Text(
            label,
            style: context.text.label.copyWith(
              color: selected ? c.textPrimary : c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
