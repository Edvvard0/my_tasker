import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/settings/application/server_connection_controller.dart';
import 'package:my_tasker/features/shell/sections_screen.dart';

/// «Настройки»: пока только подключение к серверу, справочник темы и версия.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final saved = ref.watch(serverConnectionSettingsProvider).value;
    final version = ref.watch(appConfigProvider).appVersion;
    return ScreenScaffold(
      title: 'Настройки',
      onBack: backToSections(context),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface1,
          borderRadius: AppRadii.borderL,
        ),
        child: Column(
          children: [
            _SettingsTile(
              key: const Key('settings-server'),
              icon: LucideIcons.server,
              title: 'Сервер',
              subtitle: saved?.url ?? 'Не настроен',
              onTap: () => context.go('/settings/server'),
            ),
            Divider(
              color: c.borderDefault,
              indent: AppSpacing.s4,
              endIndent: AppSpacing.s4,
            ),
            _SettingsTile(
              key: const Key('settings-theme'),
              icon: LucideIcons.palette,
              title: 'Внешний вид',
              subtitle: 'Тёмная тема · справочник дизайн-токенов',
              onTap: () => context.go('/settings/theme'),
            ),
            Divider(
              color: c.borderDefault,
              indent: AppSpacing.s4,
              endIndent: AppSpacing.s4,
            ),
            _SettingsTile(
              key: const Key('settings-about'),
              icon: LucideIcons.info,
              title: 'О приложении',
              subtitle: 'My Tasker $version',
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
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
            Icon(icon, size: 20, color: c.textSecondary),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.body),
                  Text(
                    subtitle,
                    style: t.bodyS.copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}
