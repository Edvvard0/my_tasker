import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/widgets/module_placeholder.dart';

/// «Работа › Серверы»: мониторинг только наблюдает, серверами не управляет.
/// ЗАГЛУШКА до этапа 9.
class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePlaceholder(
      title: 'Серверы',
      parentLabel: 'Работа',
      icon: LucideIcons.server,
      description: 'Дашборд «Пульс»: статус, доступность, отклик и инциденты.',
      stage: 9,
      onBack: () => context.go('/work'),
    );
  }
}
