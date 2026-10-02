import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';

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

int _balanceOf(WidgetRef ref, String id) =>
    ref.read(financeBalancesProvider).value?.of(id) ?? 0;

/// Архивирует счёт или возвращает из архива. Архив только скрывает счёт из
/// списков и на расчёты не влияет (spec 1.1), поэтому при ненулевом балансе
/// спрашивает подтверждение и напоминает про общий баланс. `true` — сделано.
Future<bool> toggleArchiveAccount(
  BuildContext context,
  WidgetRef ref,
  Account account,
) async {
  final repo = ref.read(financeRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  if (account.archived) {
    await repo.archiveAccount(account.id, archived: false);
    _toast(messenger, 'Счёт «${account.name}» возвращён из архива');
    return true;
  }
  final balance = _balanceOf(ref, account.id);
  if (balance != 0) {
    final totalNote = account.includeInTotal
        ? 'Эти деньги останутся в общем балансе: чтобы убрать их из общей '
              'суммы, сними «Учитывать в общем балансе».'
        : 'В общий баланс счёт и так не входит.';
    final ok = await showConfirmDialog(
      context,
      title: 'Архивировать «${account.name}»?',
      message:
          'На счёте ${moneyText(balance)}. Архив только скрывает счёт из '
          'списков. $totalNote',
      confirmLabel: 'Архивировать',
    );
    if (!ok) return false;
  }
  await repo.archiveAccount(account.id);
  _toast(
    messenger,
    'Счёт «${account.name}» в архиве',
    undo: () => repo.archiveAccount(account.id, archived: false),
  );
  return true;
}

/// Удаляет счёт в корзину вместе с его операциями и сверками (spec 2).
/// Подтверждение называет последствия; при ненулевом балансе — предупреждает.
/// `true` — удалён.
Future<bool> deleteAccountWithConfirm(
  BuildContext context,
  WidgetRef ref,
  Account account,
) async {
  final repo = ref.read(financeRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  final balance = _balanceOf(ref, account.id);
  final rows = ref.read(transactionRowsProvider).value ?? const [];
  final count = rows
      .where(
        (r) =>
            r['account_id'] == account.id || r['to_account_id'] == account.id,
      )
      .length;
  final balanceNote = balance == 0
      ? ''
      : ' На счёте ${moneyText(balance)}: эти деньги пропадут из балансов, '
            'пока счёт в корзине.';
  final ok = await showConfirmDialog(
    context,
    title: 'Удалить «${account.name}»?',
    message:
        'Счёт уйдёт в корзину вместе со всеми его операциями ($count) и '
        'сверками. Восстановить можно в течение 30 дней.$balanceNote',
    confirmLabel: 'Удалить',
    danger: true,
  );
  if (!ok) return false;
  await repo.deleteAccount(account.id);
  _toast(
    messenger,
    'Счёт «${account.name}» удалён',
    undo: () => repo.restoreAccount(account.id),
  );
  return true;
}
