import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';

/// Обратная стрелка для разделов вне таб-бара (Учёба, Сон, Настройки):
/// на телефоне ведёт в сетку «Разделы», на десктопе не нужна.
VoidCallback? backToSections(BuildContext context) =>
    context.windowClass.isCompact ? () => context.go('/sections') : null;

/// Сетка «Разделы» (02, 3.2): разделы, которых нет в таб-баре телефона —
/// Учёба, Сон, Серверы, Настройки.
class SectionsScreen extends StatelessWidget {
  const SectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = <_SectionTile>[
      _SectionTile(
        keyName: 'study',
        label: 'Учёба',
        icon: LucideIcons.graduationCap,
        color: c.moduleStudy,
        path: '/study',
      ),
      _SectionTile(
        keyName: 'sleep',
        label: 'Сон',
        icon: LucideIcons.moon,
        color: c.moduleSleep,
        path: '/sleep',
      ),
      _SectionTile(
        keyName: 'servers',
        label: 'Серверы',
        icon: LucideIcons.server,
        color: c.moduleWork,
        path: '/work/servers',
      ),
      _SectionTile(
        keyName: 'settings',
        label: 'Настройки',
        icon: LucideIcons.settings,
        color: c.textSecondary,
        path: '/settings',
      ),
    ];
    return Scaffold(
      body: ScreenScaffold(
        title: 'Разделы',
        // Открыто прямой ссылкой (истории нет) — возвращаемся на «Сегодня».
        onBack: () => context.canPop() ? context.pop() : context.go('/today'),
        child: GridView.count(
          key: const Key('sections-grid'),
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.s3,
          crossAxisSpacing: AppSpacing.s3,
          childAspectRatio: 1.5,
          children: items,
        ),
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.keyName,
    required this.label,
    required this.icon,
    required this.color,
    required this.path,
  });

  final String keyName;
  final String label;
  final IconData icon;
  final Color color;
  final String path;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surface1,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.borderL,
        side: BorderSide(color: c.borderDefault),
      ),
      child: InkWell(
        key: Key('section-$keyName'),
        borderRadius: AppRadii.borderL,
        onTap: () => context.go(path),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 24, color: color),
              Text(label, style: context.text.h3),
            ],
          ),
        ),
      ),
    );
  }
}
