import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';

void _toast(
  ScaffoldMessengerState messenger,
  String text, {
  VoidCallback? undo,
}) => messenger
  ..clearSnackBars()
  ..showSnackBar(
    SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 5),
      action: undo == null
          ? null
          : SnackBarAction(label: 'Отменить', onPressed: undo),
    ),
  );

/// Переносит цель в архив или возвращает из архива (расчёты не меняются).
Future<void> archiveGoalWithToast(
  BuildContext context,
  WidgetRef ref,
  Goal goal, {
  required bool archived,
}) async {
  final repo = ref.read(financeRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  await repo.archiveGoal(goal.id, archived: archived);
  _toast(
    messenger,
    archived
        ? 'Цель «${goal.name}» в архиве'
        : 'Цель «${goal.name}» возвращена из архива',
    undo: () => repo.archiveGoal(goal.id, archived: !archived),
  );
}

/// Удаляет цель в корзину; подтверждение называет последствия. `true` —
/// удалена.
Future<bool> deleteGoalWithConfirm(
  BuildContext context,
  WidgetRef ref,
  Goal goal,
) async {
  final repo = ref.read(financeRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showConfirmDialog(
    context,
    title: 'Удалить цель «${goal.name}»?',
    message:
        'Цель уйдёт в корзину; счета и долги не изменятся. Восстановить '
        'можно в течение 30 дней.',
    confirmLabel: 'Удалить',
    danger: true,
  );
  if (!ok) return false;
  await repo.deleteGoal(goal.id);
  _toast(
    messenger,
    'Цель «${goal.name}» удалена',
    undo: () => repo.restoreGoal(goal.id),
  );
  return true;
}
