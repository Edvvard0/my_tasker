import 'package:flutter/material.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Открывает окно быстрого создания.
///
/// ЗАГЛУШКА: настоящий ввод (задача, событие, операция…) появится на
/// этапе 2 вместе с календарём и задачами.
Future<void> showQuickCreate(BuildContext context) {
  if (context.windowClass.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _QuickCreateBody(),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: const _QuickCreateBody(),
      ),
    ),
  );
}

class _QuickCreateBody extends StatelessWidget {
  const _QuickCreateBody();

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Создать', style: t.h2),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'Быстрое создание задач, событий и операций появится на '
            'этапе 2.',
            style: t.body.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s4),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Закрыть'),
            ),
          ),
        ],
      ),
    );
  }
}
