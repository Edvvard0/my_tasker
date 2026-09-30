import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/widgets/module_placeholder.dart';
import 'package:my_tasker/features/shell/sections_screen.dart';

/// «Учёба». ЗАГЛУШКА до этапа 7.
class StudyScreen extends StatelessWidget {
  const StudyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePlaceholder(
      title: 'Учёба',
      icon: LucideIcons.graduationCap,
      description: 'Пары, пропуски и учебные долги.',
      stage: 7,
      onBack: backToSections(context),
    );
  }
}
