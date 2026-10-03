import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/debt_actions.dart';
import 'package:my_tasker/features/finance/presentation/debt_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/finance_money.dart';
import 'package:my_tasker/features/finance/presentation/widgets/amount_field.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_pickers.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

/// Открывает лист погашения долга [debtId]: [repaymentId] — правка
/// существующего погашения, иначе новое.
///
/// [closeRemaining] — новое погашение сразу на весь остаток.
Future<void> showRepaymentSheet(
  BuildContext context, {
  required String debtId,
  String? repaymentId,
  bool closeRemaining = false,
}) => showEditorSheet<void>(
  context,
  builder: (_) => RepaymentSheet(
    debtId: debtId,
    repaymentId: repaymentId,
    closeRemaining: closeRemaining,
  ),
);

enum _Move { account, none }

/// Лист погашения: сумма (частичное или «закрыть остаток»), дата, заметка и
/// движение денег — операцией на счёт (доход «мне вернули» / расход «я
/// вернул», с `debt_id`) либо «списать без движения денег» («простил»,
/// «зачли»). У существующего погашения привязка к операции не меняется:
/// сумма и день привязанной операции следуют за погашением.
class RepaymentSheet extends ConsumerStatefulWidget {
  const RepaymentSheet({
    required this.debtId,
    this.repaymentId,
    this.closeRemaining = false,
    super.key,
  });

  final String debtId;
  final String? repaymentId;

  /// Новое погашение: сумма — весь остаток.
  final bool closeRemaining;

  @override
  ConsumerState<RepaymentSheet> createState() => _RepaymentSheetState();
}

class _RepaymentSheetState extends ConsumerState<RepaymentSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();

  DebtRepayment? _original;
  String? _linkedAccountName;
  DateTime? _date;
  _Move? _move;
  String? _accountId;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.repaymentId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _loading = false;
      final remaining = ref
          .read(debtDetailProvider(widget.debtId))
          .value
          ?.state
          .remaining;
      if (widget.closeRemaining && remaining != null && remaining > 0) {
        _amount.text = amountInputText(remaining);
      }
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(financeRepositoryProvider);
    final repayment = await repo.getRepayment(widget.repaymentId!);
    String? account;
    final txId = repayment?.transactionId;
    if (txId != null) {
      final tx = await repo.getTransaction(txId);
      if (tx != null) {
        account = (await repo.getAccount(tx.accountId))?.name ?? 'Счёт';
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (repayment == null || repayment.debtId != widget.debtId) {
        _missing = true;
        return;
      }
      _original = repayment;
      _linkedAccountName = account;
      _amount.text = amountInputText(repayment.amount);
      _date = parseDate(repayment.repaidOn);
      _note.text = repayment.note ?? '';
    });
  }

  DateTime _today() => parseDate(ref.read(moscowTodayProvider))!;

  Future<void> _save(DebtDetail detail, {required bool viaAccount}) async {
    if (_saving) return;
    final amount = parseAmountField(_amount.text);
    if (amount == null || amount < 1) {
      setState(() => _error = 'Введи сумму больше нуля');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    final day = formatDate(_date ?? _today());
    try {
      final original = _original;
      if (original == null) {
        await repo.addRepayment(
          debtId: detail.debt.id,
          amount: amount,
          repaidOn: day,
          accountId: viaAccount ? _accountId : null,
          note: _note.text,
        );
      } else {
        await repo.updateRepayment(
          original.copyWith(amount: amount, repaidOn: day, note: _note.text),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    final original = _original;
    if (original == null) return;
    if (await deleteRepaymentWithConfirm(context, ref, original) && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _pickAccount(List<Account> accounts, DebtDirection d) async {
    final picked = await showAccountPicker(
      context,
      accounts: accounts,
      balances: ref.read(financeBalancesProvider).value,
      selectedId: _accountId,
      title: d == DebtDirection.owedToMe
          ? 'На какой счёт вернули'
          : 'С какого счёта вернул',
    );
    if (picked == null) return;
    setState(() => _accountId = picked);
  }

  void _closeRemaining(int remaining) {
    final text = amountInputText(remaining);
    _amount.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _error = null);
  }

  Widget _note1(String text, {Key? key}) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s4),
    child: Text(
      text,
      key: key,
      style: context.text.bodyS.copyWith(color: context.colors.textSecondary),
    ),
  );

  Widget _overpayNotice(int over) {
    final c = context.colors;
    return Container(
      key: const Key('repay-overpay'),
      margin: const EdgeInsets.only(bottom: AppSpacing.s4),
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderM,
        border: Border.all(color: c.borderStrong),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.triangleAlert, size: 18, color: c.textPrimary),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              'Это больше остатка: получится переплата ${context.money(over)}. '
              'Можно сохранить, если так и было.',
              style: context.text.bodyS,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorRow(String text) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        key: const Key('repay-error'),
        children: [
          Icon(LucideIcons.circleAlert, size: 16, color: c.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: context.text.bodyS.copyWith(color: c.danger),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final title = _isNew ? 'Погашение' : 'Погашение долга';
    Widget placeholder(String text, Key key) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetHeader(title: title),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s6),
          child: Text(
            text,
            key: key,
            style: t.body.copyWith(color: c.textSecondary),
          ),
        ),
      ],
    );
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final detail = ref.watch(debtDetailProvider(widget.debtId)).value;
    if (_missing) {
      return placeholder(
        'Погашение не найдено: возможно, его удалили на другом устройстве.',
        const Key('repay-missing'),
      );
    }
    if (detail == null) {
      return placeholder(
        'Долг не найден: возможно, его удалили на другом устройстве.',
        const Key('repay-debt-missing'),
      );
    }
    final state = detail.state;
    final debt = detail.debt;
    final original = _original;
    // Остаток без самого редактируемого погашения.
    final repaidOthers = state.repaid - (original?.amount ?? 0);
    final available = debt.amount > repaidOthers
        ? debt.amount - repaidOthers
        : 0;
    final entered = parseAmountField(_amount.text) ?? 0;
    final over = entered > available ? entered - available : 0;
    final accounts = ref.watch(activeAccountsProvider).value ?? const [];
    final lookups = ref.watch(financeLookupsProvider).value;
    final viaAccount =
        _isNew &&
        accounts.isNotEmpty &&
        (_move ?? _Move.account) == _Move.account;
    if (_isNew && accounts.isNotEmpty) _accountId ??= accounts.first.id;
    final today = _today();
    final owedToMe = debt.direction == DebtDirection.owedToMe;
    final account = lookups?.account(_accountId);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: title),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s4),
                    child: Text(
                      '${debt.who} · остаток ${context.money(available)}',
                      key: const Key('repay-context'),
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ),
                  FormBlock(
                    label: repaymentVerb(debt.direction),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AmountField(
                          key: const Key('repay-amount'),
                          controller: _amount,
                          autofocus: _isNew,
                          onChanged: (_) => setState(() => _error = null),
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        ChipRow(
                          children: [
                            FilterPill(
                              key: const Key('repay-close'),
                              label:
                                  'Закрыть остаток · ${context.money(available)}',
                              selected: false,
                              icon: LucideIcons.circleCheck,
                              onTap: available == 0
                                  ? null
                                  : () => _closeRemaining(available),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (over > 0) _overpayNotice(over),
                  FormBlock(
                    label: 'Дата',
                    child: DateChoiceRow(
                      keyPrefix: 'repay-date',
                      today: today,
                      value: _date ?? today,
                      onChanged: (d) => setState(() => _date = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Заметка',
                    child: FormTextField(
                      key: const Key('repay-note'),
                      controller: _note,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        hintText: 'Необязательно',
                      ),
                    ),
                  ),
                  if (_isNew) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: SegmentedPill<_Move>(
                        keyPrefix: 'repay-move',
                        options: const {
                          _Move.account: 'Через счёт',
                          _Move.none: 'Без движения денег',
                        },
                        selected: viaAccount ? _Move.account : _Move.none,
                        onChanged: (m) => setState(() => _move = m),
                      ),
                    ),
                    if (viaAccount) ...[
                      FormBlock(
                        label: owedToMe ? 'На счёт' : 'Со счёта',
                        child: PickerTile(
                          key: const Key('repay-account'),
                          icon: account == null
                              ? LucideIcons.wallet
                              : accountKindIcon(account.kind),
                          text: account?.name ?? 'Выбери счёт',
                          hint: account == null,
                          onTap: () => _pickAccount(accounts, debt.direction),
                        ),
                      ),
                      _note1(
                        owedToMe
                            ? 'На счёт запишется операция: баланс вырастет, '
                                  'но «доход» месяца не изменится — это '
                                  'возврат долга.'
                            : 'Со счёта спишется операция: баланс '
                                  'уменьшится, но «расход» месяца не '
                                  'изменится — это возврат долга.',
                        key: const Key('repay-account-note'),
                      ),
                    ] else
                      _note1(
                        accounts.isEmpty
                            ? 'Счетов нет, поэтому долг уменьшится без '
                                  'операции на счёте.'
                            : 'Долг уменьшится без операции на счёте: '
                                  '«простил», «зачли».',
                        key: const Key('repay-none-note'),
                      ),
                  ] else
                    _note1(
                      _linkedAccountName == null
                          ? 'Без движения денег: операции на счёте нет.'
                          : 'Операция на счёте «$_linkedAccountName» '
                                'изменится вместе с погашением.',
                      key: const Key('repay-linked-note'),
                    ),
                  if (_error != null) _errorRow(_error!),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s6,
              AppSpacing.s2,
              AppSpacing.s6,
              AppSpacing.s4,
            ),
            child: Row(
              children: [
                if (!_isNew)
                  OutlinedButton.icon(
                    key: const Key('repay-delete'),
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.danger,
                      side: BorderSide(color: c.danger),
                    ),
                    icon: const Icon(LucideIcons.trash2, size: 18),
                    label: const Text('Удалить'),
                  ),
                const Spacer(),
                Flexible(
                  child: FilledButton(
                    key: const Key('repay-save'),
                    onPressed: _saving
                        ? null
                        : () => _save(detail, viaAccount: viaAccount),
                    child: Text(
                      _isNew && !viaAccount
                          ? 'Списать без движения денег'
                          : 'Сохранить',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
