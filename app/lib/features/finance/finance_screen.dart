import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/module_placeholder.dart';

/// «Финансы». ЗАГЛУШКА до этапа 5.
class FinanceScreen extends StatelessWidget {
  const FinanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePlaceholder(
      title: 'Финансы',
      icon: LucideIcons.wallet,
      color: context.colors.moduleFinance,
      description: 'Счета, операции, долги, цели и аналитика.',
      stage: 5,
    );
  }
}
