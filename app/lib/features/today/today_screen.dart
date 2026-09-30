import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/widgets/module_placeholder.dart';

/// «Сегодня» — стартовый экран-хаб. ЗАГЛУШКА до этапа 2.
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ModulePlaceholder(
      title: 'Сегодня',
      icon: LucideIcons.sun,
      description:
          'Сводка дня: тревоги, ближайшее событие, задачи, цифры, '
          'сон и учёба.',
      stage: 2,
      actions: [
        // «Разделы» нужны только на телефоне: на десктопе все разделы
        // уже в левой панели.
        if (context.windowClass.isCompact)
          IconButton(
            key: const Key('open-sections'),
            tooltip: 'Разделы',
            onPressed: () => context.push('/sections'),
            icon: const Icon(LucideIcons.layoutGrid, size: 24),
          ),
      ],
    );
  }
}
