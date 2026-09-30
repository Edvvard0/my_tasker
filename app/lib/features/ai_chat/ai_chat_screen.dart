import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/widgets/module_placeholder.dart';

/// «ИИ». ЗАГЛУШКА до этапа 3.
class AiChatScreen extends StatelessWidget {
  const AiChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ModulePlaceholder(
      title: 'ИИ',
      icon: LucideIcons.sparkles,
      description: 'Чаты с ИИ-агентами по разделам.',
      stage: 3,
    );
  }
}
