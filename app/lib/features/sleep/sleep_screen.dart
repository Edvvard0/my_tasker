import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/widgets/module_placeholder.dart';
import 'package:my_tasker/features/shell/sections_screen.dart';

/// «Сон». ЗАГЛУШКА до этапа 8.
class SleepScreen extends StatelessWidget {
  const SleepScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePlaceholder(
      title: 'Сон',
      icon: LucideIcons.moon,
      description: 'Журнал сна, heatmap и связь с продуктивностью.',
      stage: 8,
      onBack: backToSections(context),
    );
  }
}
