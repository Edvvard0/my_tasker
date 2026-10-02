import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';

/// Возврат с подэкрана настроек ИИ: на предыдущий экран либо в раздел «ИИ».
void backToAi(BuildContext context) =>
    context.canPop() ? context.pop() : context.go('/ai');

/// Строка настроек ИИ: иконка, название, пояснение, шеврон.
class AiSettingsTile extends StatelessWidget {
  const AiSettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

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
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// «Настройки ИИ»: агенты и промты, модели быстрого выбора, пресеты
/// контекста, расход и лимит.
class AiSettingsScreen extends StatelessWidget {
  const AiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget divider() => Divider(
      color: c.borderDefault,
      indent: AppSpacing.s4,
      endIndent: AppSpacing.s4,
    );
    return ScreenScaffold(
      title: 'Настройки ИИ',
      parentLabel: 'ИИ',
      onBack: () => backToAi(context),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface1,
          borderRadius: AppRadii.borderL,
        ),
        child: Column(
          children: [
            AiSettingsTile(
              key: const Key('ai-settings-agents'),
              icon: LucideIcons.bot,
              title: 'Агенты и промты',
              subtitle: 'Системные промты по разделам, история и сброс',
              onTap: () => context.go('/ai/settings/agents'),
            ),
            divider(),
            AiSettingsTile(
              key: const Key('ai-settings-models'),
              icon: LucideIcons.cloud,
              title: 'Модели быстрого выбора',
              subtitle: 'Избранные модели из каталога провайдера',
              onTap: () => context.go('/ai/settings/models'),
            ),
            divider(),
            AiSettingsTile(
              key: const Key('ai-settings-presets'),
              icon: LucideIcons.layers,
              title: 'Пресеты контекста',
              subtitle: 'Наборы данных для чата, пометка «не в облако»',
              onTap: () => context.go('/ai/settings/presets'),
            ),
            divider(),
            AiSettingsTile(
              key: const Key('ai-settings-usage'),
              icon: LucideIcons.wallet,
              title: 'Расход и лимит',
              subtitle: 'Траты за месяц в рублях и месячный лимит',
              onTap: () => context.go('/ai/settings/usage'),
            ),
          ],
        ),
      ),
    );
  }
}
