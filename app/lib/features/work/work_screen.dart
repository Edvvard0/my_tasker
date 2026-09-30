import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/module_placeholder.dart';

/// «Работа». ЗАГЛУШКА до этапа 4; «Серверы» вложены сюда (02, 3.1).
class WorkScreen extends StatelessWidget {
  const WorkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ModulePlaceholder(
      title: 'Работа',
      icon: LucideIcons.briefcase,
      color: c.moduleWork,
      description: 'Деньги, время и проекты.',
      stage: 4,
      extra: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.surface1,
            borderRadius: AppRadii.borderL,
            border: Border.all(color: c.borderDefault),
          ),
          child: Column(
            children: [
              const _SubsectionRow(
                label: 'Проекты',
                icon: LucideIcons.folderKanban,
                stage: 4,
              ),
              const _SubsectionRow(
                label: 'Люди',
                icon: LucideIcons.users,
                stage: 4,
              ),
              const _SubsectionRow(
                label: 'Поступления',
                icon: LucideIcons.banknote,
                stage: 4,
              ),
              const _SubsectionRow(
                label: 'Трекер времени',
                icon: LucideIcons.timer,
                stage: 4,
              ),
              _SubsectionRow(
                key: const Key('work-servers-link'),
                label: 'Серверы',
                icon: LucideIcons.server,
                stage: 9,
                onTap: () => context.go('/work/servers'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubsectionRow extends StatelessWidget {
  const _SubsectionRow({
    required this.label,
    required this.icon,
    required this.stage,
    this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final int stage;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.borderL,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: c.moduleWork),
            const SizedBox(width: AppSpacing.s3),
            Expanded(child: Text(label, style: t.body)),
            Text(
              'Этап $stage',
              style: t.caption.copyWith(color: c.textTertiary),
            ),
            if (onTap != null) ...[
              const SizedBox(width: AppSpacing.s2),
              Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
            ],
          ],
        ),
      ),
    );
  }
}
