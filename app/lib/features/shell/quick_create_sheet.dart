import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/presentation/event_editor.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';
import 'package:my_tasker/features/tasks/presentation/quick_add_bar.dart';
import 'package:my_tasker/features/tasks/presentation/task_editor.dart';

/// Открывает окно быстрого создания («+», 02, 4.4): строка быстрого ввода
/// задачи с чипами (дата, время, приоритет, проект…) и кнопки «Задача» /
/// «Событие» для полных форм.
Future<void> showQuickCreate(BuildContext context) {
  if (context.windowClass.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const QuickCreateBody(),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: const QuickCreateBody(),
      ),
    ),
  );
}

/// Содержимое окна «Создать».
class QuickCreateBody extends StatelessWidget {
  const QuickCreateBody({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s6,
        AppSpacing.s2,
        AppSpacing.s6,
        AppSpacing.s6 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Создать', style: t.h2),
          const SizedBox(height: AppSpacing.s1),
          Text(
            'Напишите одной строкой: «Позвонить завтра 15:00 !2 #работа».',
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s4),
          QuickAddBar(
            autofocus: true,
            onCreated: (result) {
              final messenger = ScaffoldMessenger.of(context);
              Navigator.of(context).pop();
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    result.created.isEmpty
                        ? 'Задача добавлена'
                        : 'Задача добавлена · создано: '
                              '${result.created.join(', ')}',
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  key: const Key('quick-create-task'),
                  onPressed: () {
                    final root = Navigator.of(context).context;
                    Navigator.of(context).pop();
                    unawaited(showTaskEditor(root));
                  },
                  icon: const Icon(LucideIcons.circleCheck, size: 18),
                  label: const Text('Задача'),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: ElevatedButton.icon(
                  key: const Key('quick-create-event'),
                  onPressed: () {
                    final root = Navigator.of(context).context;
                    Navigator.of(context).pop();
                    unawaited(showEventEditor(root));
                  },
                  icon: const Icon(LucideIcons.calendarPlus, size: 18),
                  label: const Text('Событие'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('quick-create-transaction'),
              onPressed: () {
                final root = Navigator.of(context).context;
                Navigator.of(context).pop();
                unawaited(showTransactionEditor(root));
              },
              icon: const Icon(LucideIcons.wallet, size: 18),
              label: const Text('Операция'),
            ),
          ),
        ],
      ),
    );
  }
}
