import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/ai_settings_screen.dart';

/// «Агенты и промты»: шесть предустановленных агентов по разделам.
class AgentsScreen extends ConsumerWidget {
  const AgentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(aiBootstrapProvider);
    final agents = ref.watch(agentsProvider);
    final c = context.colors;
    return ScreenScaffold(
      title: 'Агенты и промты',
      parentLabel: 'Настройки ИИ',
      onBack: () => context.go('/ai/settings'),
      child: agents.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const EmptyState(
          icon: LucideIcons.circleAlert,
          title: 'Не удалось прочитать агентов',
          message: 'Попробуйте открыть экран ещё раз.',
        ),
        data: (list) => list.isEmpty
            ? const EmptyState(
                key: Key('agents-screen-empty'),
                icon: LucideIcons.bot,
                title: 'Агентов пока нет',
                message:
                    'Предустановленные агенты придут с сервера при первой '
                    'синхронизации.',
              )
            : Container(
                decoration: BoxDecoration(
                  color: c.surface1,
                  borderRadius: AppRadii.borderL,
                ),
                child: Column(
                  children: [
                    for (final a in list)
                      AiSettingsTile(
                        key: Key('agent-tile-${a.id}'),
                        icon: a.topic.icon,
                        title: a.name,
                        subtitle: 'Промт, версия ${a.promptVersion}',
                        onTap: () => context.go('/ai/settings/agents/${a.id}'),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
