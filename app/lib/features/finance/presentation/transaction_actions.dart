import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Удаляет операцию (мягко, в корзину) и показывает снэкбар
/// «Операция удалена · Отменить» (02, 4.9, 7.3).
Future<void> deleteTransactionWithUndo(
  BuildContext context,
  WidgetRef ref,
  FinanceTransaction transaction,
) async {
  final repo = ref.read(financeRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  await repo.deleteTransaction(transaction.id);
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: const Text('Операция удалена'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Отменить',
          onPressed: () => repo.restoreTransaction(transaction.id),
        ),
      ),
    );
}
