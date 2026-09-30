import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_elevation.dart';
import 'package:my_tasker/core/theme/app_motion.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/shell/app_section.dart';

/// Плавающий таб-бар телефона (02, 3.2): пилюля `surface/2` + `elev/3`,
/// 5 разделов с подписями, справа — зелёный круг «+» 56 dp.
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
    // При масштабе шрифта > 130 % подписи неактивных вкладок скрываются.
    final compactLabels = MediaQuery.textScalerOf(context).scale(1) > 1.3;
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
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s1),
              decoration: AppElevation.floating(c, radius: AppRadii.borderFull),
              child: Row(
                children: [
                  for (final section in AppSection.tabs)
                    Expanded(
                      child: _TabItem(
                        section: section,
                        active: section == selected,
                        showLabel: !compactLabels || section == selected,
                        onTap: () => onSelect(section),
                      ),
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
    required this.showLabel,
    required this.onTap,
  });

  final AppSection section;
  final bool active;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final color = active ? c.accent : c.textTertiary;
    return Semantics(
      button: true,
      selected: active,
      label: section.label,
      excludeSemantics: true,
      child: InkWell(
        key: Key('nav-${section.name}'),
        borderRadius: AppRadii.borderFull,
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            decoration: BoxDecoration(
              color: active ? c.accentMuted : Colors.transparent,
              borderRadius: AppRadii.borderFull,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(section.icon, size: 24, color: color),
                if (showLabel)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      section.label,
                      maxLines: 1,
                      style: t.tabLabel.copyWith(color: color),
                    ),
                  ),
              ],
            ),
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
          color: c.accent,
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
            child: Icon(LucideIcons.plus, size: 24, color: c.textOnAccent),
          ),
        ),
      ),
    );
  }
}
