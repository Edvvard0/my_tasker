import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_money.dart';

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

/// Удаляет долг в корзину: одна операция `delete`, погашения уходят
/// каскадом, операции счетов остаются (spec 2). Подтверждение называет
/// последствия. `true` — удалён.
Future<bool> deleteDebtWithConfirm(
  BuildContext context,
  WidgetRef ref,
  Debt debt,
) async {
  final repo = ref.read(financeRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  final repayments = (ref.read(repaymentRowsProvider).value ?? const []).where(
    (r) => r['debt_id'] == debt.id,
  );
  final moves = ref
      .read(transactionRowsProvider)
      .value
      ?.where((r) => r['debt_id'] == debt.id)
      .length;
  final tail = (moves ?? 0) == 0
      ? ''
      : ' Операции на счетах (${moves!}) останутся: деньги двигались.';
  final ok = await showConfirmDialog(
    context,
    title: 'Удалить долг «${debt.who}»?',
    message:
        'Долг уйдёт в корзину вместе с погашениями (${repayments.length}).$tail '
        'Восстановить можно в течение 30 дней.',
    confirmLabel: 'Удалить',
    danger: true,
  );
  if (!ok) return false;
  await repo.deleteDebt(debt.id);
  _toast(
    messenger,
    'Долг «${debt.who}» удалён',
    undo: () => repo.restoreDebt(debt.id),
  );
  return true;
}

/// Удаляет погашение в корзину. Операция счёта, которой двигались деньги,
/// остаётся. `true` — удалено.
Future<bool> deleteRepaymentWithConfirm(
  BuildContext context,
  WidgetRef ref,
  DebtRepayment repayment,
) async {
  final repo = ref.read(financeRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  final linked = repayment.transactionId != null
      ? ' Операция на счёте останется: удали её отдельно, если деньги на '
            'самом деле не двигались.'
      : '';
  final ok = await showConfirmDialog(
    context,
    title: 'Удалить погашение ${context.money(repayment.amount)}?',
    message:
        'Погашение уйдёт в корзину, остаток долга вырастет.$linked '
        'Восстановить можно в течение 30 дней.',
    confirmLabel: 'Удалить',
    danger: true,
  );
  if (!ok) return false;
  await repo.deleteRepayment(repayment.id);
  _toast(
    messenger,
    'Погашение удалено',
    undo: () => repo.restoreRepayment(repayment.id),
  );
  return true;
}
