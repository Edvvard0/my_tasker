import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_elevation.dart';
import 'package:my_tasker/core/theme/app_motion.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/shell/app_section.dart';

/// Плавающий таб-бар телефона (02, 3.2), как в референсе: пилюля `surface/2`
/// с мягкой тенью, только иконки; у активного раздела — белая иконка на
/// светло-сером круге, у остальных — серые иконки. Справа — белый круг «+».
/// Подписи есть только для доступности (Semantics).
class FloatingTabBar extends StatelessWidget {
  const FloatingTabBar({
    required this.selected,
    required this.onSelect,
    required this.onCreate,
    super.key,
  });

  /// Активный раздел таб-бара или `null` (открыт раздел вне таб-бара).
  final AppSection? selected;
  final ValueChanged<AppSection> onSelect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        0,
        AppSpacing.s4,
        AppSpacing.s3,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              key: const Key('floating-tab-bar'),
              height: AppSpacing.tabBarHeight,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
              decoration: AppElevation.floating(c, radius: AppRadii.borderFull),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final section in AppSection.tabs)
                    _TabItem(
                      section: section,
                      active: section == selected,
                      onTap: () => onSelect(section),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          _CreateButton(onPressed: onCreate),
        ],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.section,
    required this.active,
    required this.onTap,
  });

  final AppSection section;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      selected: active,
      label: section.label,
      excludeSemantics: true,
      child: InkResponse(
        key: Key('nav-${section.name}'),
        radius: 28,
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: active ? c.surface4 : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            section.icon,
            size: 24,
            color: active ? c.textPrimary : c.textTertiary,
          ),
        ),
      ),
    );
  }
}

class _CreateButton extends StatelessWidget {
  const _CreateButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: 'Создать',
      excludeSemantics: true,
      child: Container(
        width: AppSpacing.fabSize,
        height: AppSpacing.fabSize,
        decoration: BoxDecoration(
          color: c.surfaceInverse,
          shape: BoxShape.circle,
          boxShadow: const [AppElevation.shadow3],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            key: const Key('create-fab'),
            onTap: onPressed,
            containedInkWell: true,
            customBorder: const CircleBorder(),
            highlightColor: AppColors.statePressed,
            child: Icon(LucideIcons.plus, size: 24, color: c.textOnInverse),
          ),
        ),
      ),
    );
  }
}
