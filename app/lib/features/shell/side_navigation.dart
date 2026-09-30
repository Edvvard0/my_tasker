import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_motion.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/shell/app_section.dart';

/// Левая навигация десктопа (02, 3.3): панель 256 px или рейл 72 px.
///
/// Фон — `bg/base` без визуального веса, как у Google Календаря. Сверху
/// «Создать», затем разделы, внизу «Настройки».
class SideNavigation extends StatelessWidget {
  const SideNavigation({
    required this.collapsed,
    required this.selected,
    required this.onSelect,
    required this.onCreate,
    this.onToggleCollapsed,
    super.key,
  });

  /// Рейл 72 px (иконки + подписи) вместо панели 256 px.
  final bool collapsed;
  final AppSection? selected;
  final ValueChanged<AppSection> onSelect;
  final VoidCallback onCreate;

  /// Кнопка `≡`; `null` — свернуть нельзя (узкое окно всегда рейл).
  final VoidCallback? onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final width = collapsed ? AppSpacing.railWidth : AppSpacing.sidePanelWidth;
    return AnimatedContainer(
      key: Key(collapsed ? 'nav-rail' : 'nav-side-panel'),
      duration: AppMotion.base,
      curve: AppMotion.standard,
      width: width,
      decoration: BoxDecoration(
        color: c.bgBase,
        border: Border(right: BorderSide(color: c.borderSubtle)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(collapsed: collapsed, onToggle: onToggleCollapsed),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3,
                vertical: AppSpacing.s2,
              ),
              child: _CreateAction(collapsed: collapsed, onPressed: onCreate),
            ),
            const SizedBox(height: AppSpacing.s2),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
                children: [
                  for (final section in AppSection.sidePanelMain)
                    _NavItem(
                      section: section,
                      selected: section == selected,
                      collapsed: collapsed,
                      onTap: () => onSelect(section),
                    ),
                ],
              ),
            ),
            Divider(color: c.borderSubtle),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s3),
              child: _NavItem(
                section: AppSection.settings,
                selected: selected == AppSection.settings,
                collapsed: collapsed,
                onTap: () => onSelect(AppSection.settings),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.collapsed, required this.onToggle});

  final bool collapsed;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return SizedBox(
      height: AppSpacing.topBarDesktop,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
        child: Row(
          mainAxisAlignment: collapsed
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            if (onToggle != null)
              IconButton(
                key: const Key('nav-toggle'),
                tooltip: collapsed ? 'Развернуть панель' : 'Свернуть панель',
                onPressed: onToggle,
                icon: const Icon(LucideIcons.menu, size: 24),
              ),
            if (!collapsed) ...[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text('My Tasker', style: t.h3),
            ],
          ],
        ),
      ),
    );
  }
}

class _CreateAction extends StatelessWidget {
  const _CreateAction({required this.collapsed, required this.onPressed});

  final bool collapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (collapsed) {
      return Center(
        child: IconButton.filled(
          key: const Key('create-button'),
          tooltip: 'Создать',
          onPressed: onPressed,
          style: IconButton.styleFrom(
            backgroundColor: c.accent,
            foregroundColor: c.textOnAccent,
            fixedSize: const Size(44, 44),
          ),
          icon: const Icon(LucideIcons.plus, size: 24),
        ),
      );
    }
    return FilledButton.icon(
      key: const Key('create-button'),
      onPressed: onPressed,
      icon: const Icon(LucideIcons.plus, size: 20),
      label: const Text('Создать'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  final AppSection section;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final textColor = selected ? c.accent : c.textPrimary;
    final iconColor = selected ? c.accent : section.moduleColor(c);

    final content = collapsed
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(section.icon, size: 24, color: iconColor),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  section.label,
                  maxLines: 1,
                  style: t.tabLabel.copyWith(color: textColor),
                ),
              ),
            ],
          )
        : Row(
            children: [
              Icon(section.icon, size: 20, color: iconColor),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  section.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.label.copyWith(color: textColor),
                ),
              ),
            ],
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Semantics(
        button: true,
        selected: selected,
        label: section.label,
        excludeSemantics: true,
        child: Material(
          color: selected ? c.accentMuted : Colors.transparent,
          borderRadius: collapsed ? AppRadii.borderM : AppRadii.borderFull,
          child: InkWell(
            key: Key('nav-${section.name}'),
            borderRadius: collapsed ? AppRadii.borderM : AppRadii.borderFull,
            hoverColor: AppColors.stateHover,
            onTap: onTap,
            child: Container(
              height: collapsed ? 56 : 40,
              padding: EdgeInsets.symmetric(
                horizontal: collapsed ? AppSpacing.s1 : AppSpacing.s4,
              ),
              alignment: collapsed ? Alignment.center : Alignment.centerLeft,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
