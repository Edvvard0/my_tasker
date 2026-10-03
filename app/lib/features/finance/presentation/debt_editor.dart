import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/widgets/amount_field.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_pickers.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

/// Открывает редактор долга: [debtId] — правка, иначе создание с
/// направлением [direction].
Future<void> showDebtEditor(
  BuildContext context, {
  String? debtId,
  DebtDirection direction = DebtDirection.owedToMe,
}) => showEditorSheet<void>(
  context,
  builder: (_) => DebtEditor(debtId: debtId, initialDirection: direction),
);

/// Редактор долга (02, 5.4.3): направление, контрагент текстом (человека из
/// «Работы» пока нет), сумма, дата, срок, комментарий. У нового долга —
/// необязательная запись займа операцией на счёт («выдал» / «получил»).
class DebtEditor extends ConsumerStatefulWidget {
  const DebtEditor({
    this.debtId,
    this.initialDirection = DebtDirection.owedToMe,
    super.key,
  });

  final String? debtId;
  final DebtDirection initialDirection;

  @override
  ConsumerState<DebtEditor> createState() => _DebtEditorState();
}

class _DebtEditorState extends ConsumerState<DebtEditor> {
  final _who = TextEditingController();
  final _amount = TextEditingController();
  final _comment = TextEditingController();

  Debt? _original;
  late DebtDirection _direction = widget.initialDirection;
  DateTime? _debtDate;
  DateTime? _dueDate;
  bool _loan = false;
  String? _loanAccountId;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.debtId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _who.dispose();
    _amount.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final debt = await ref
        .read(financeRepositoryProvider)
        .getDebt(widget.debtId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (debt == null) {
        _missing = true;
        return;
      }
      _original = debt;
      _direction = debt.direction;
      _who.text = debt.counterparty ?? '';
      _amount.text = amountInputText(debt.amount);
      _debtDate = parseDate(debt.debtDate);
      _dueDate = debt.dueDate == null ? null : parseDate(debt.dueDate!);
      _comment.text = debt.comment ?? '';
    });
  }

  DateTime _today() => parseDate(ref.read(moscowTodayProvider))!;

  Future<void> _save() async {
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
    try {
      final original = _original;
      final debt = Debt(
        id: original?.id ?? repo.newId(),
        direction: _direction,
        personId: original?.personId,
        counterparty: _who.text,
        amount: amount,
        debtDate: formatDate(_debtDate ?? _today()),
        dueDate: _dueDate == null ? null : formatDate(_dueDate!),
        comment: _comment.text,
      );
      if (original == null) {
        await repo.createDebt(
          debt,
          loanAccountId: _loan ? _loanAccountId : null,
        );
      } else {
        await repo.updateDebt(debt);
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

  Future<void> _pickAccount(List<Account> accounts) async {
    final picked = await showAccountPicker(
      context,
      accounts: accounts,
      balances: ref.read(financeBalancesProvider).value,
      selectedId: _loanAccountId,
      title: _direction == DebtDirection.owedToMe
          ? 'С какого счёта выдал'
          : 'На какой счёт пришло',
    );
    if (picked == null) return;
    setState(() => _loanAccountId = picked);
  }

  Widget _errorRow(String text) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        key: const Key('debt-error'),
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

  /// Запись займа операцией на счёт: только у нового долга.
  Widget _loanBlock(List<Account> accounts, FinanceLookups? lookups) {
    final c = context.colors;
    final t = context.text;
    final gave = _direction == DebtDirection.owedToMe;
    if (accounts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.s4),
        child: Text(
          'Чтобы записать, как деньги прошли через счёт, сначала добавь счёт.',
          key: const Key('debt-loan-no-accounts'),
          style: t.bodyS.copyWith(color: c.textSecondary),
        ),
      );
    }
    final account = lookups?.account(_loanAccountId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.s2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  gave
                      ? 'Записать выдачу займа на счёт'
                      : 'Записать получение займа на счёт',
                  style: t.body,
                ),
              ),
              Switch(
                key: const Key('debt-loan'),
                value: _loan,
                onChanged: (v) => setState(() {
                  _loan = v;
                  _loanAccountId ??= accounts.first.id;
                }),
              ),
            ],
          ),
        ),
        if (_loan) ...[
          FormBlock(
            label: gave ? 'Со счёта' : 'На счёт',
            child: PickerTile(
              key: const Key('debt-loan-account'),
              icon: account == null
                  ? LucideIcons.wallet
                  : accountKindIcon(account.kind),
              text: account?.name ?? 'Выбери счёт',
              hint: account == null,
              onTap: () => _pickAccount(accounts),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s4),
            child: Text(
              gave
                  ? 'Баланс счёта уменьшится, но «расход» месяца не изменится: '
                        'это займ, а не трата.'
                  : 'Баланс счёта увеличится, но «доход» месяца не изменится: '
                        'это займ, а не заработок.',
              key: const Key('debt-loan-note'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
        ] else
          const SizedBox(height: AppSpacing.s2),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final title = _isNew ? 'Новый долг' : 'Долг';
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_missing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(title: title),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Долг не найден: возможно, его удалили на другом устройстве.',
              key: const Key('debt-missing'),
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = _today();
    final accounts = ref.watch(activeAccountsProvider).value ?? const [];
    final lookups = ref.watch(financeLookupsProvider).value;
    final gave = _direction == DebtDirection.owedToMe;
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
                    child: SegmentedPill<DebtDirection>(
                      keyPrefix: 'debt-direction',
                      options: {
                        for (final d in DebtDirection.values) d: d.label,
                      },
                      selected: _direction,
                      onChanged: (d) => setState(() => _direction = d),
                    ),
                  ),
                  FormBlock(
                    label: gave ? 'Кто должен' : 'Кому должен',
                    child: FormTextField(
                      key: const Key('debt-who'),
                      controller: _who,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Имя или название',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Сумма',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AmountField(
                          key: const Key('debt-amount'),
                          controller: _amount,
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        AmountChips(
                          controller: _amount,
                          keyPrefix: 'debt-chip',
                        ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Дата долга',
                    child: DateChoiceRow(
                      keyPrefix: 'debt-date',
                      today: today,
                      value: _debtDate ?? today,
                      onChanged: (d) => setState(() => _debtDate = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Срок возврата',
                    child: DateChoiceRow(
                      keyPrefix: 'debt-due',
                      today: today,
                      value: _dueDate,
                      allowNone: true,
                      noneLabel: 'Без срока',
                      onChanged: (d) => setState(() => _dueDate = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Комментарий',
                    child: FormTextField(
                      key: const Key('debt-comment'),
                      controller: _comment,
                      minLines: 2,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(hintText: 'Заметка'),
                    ),
                  ),
                  if (_isNew) _loanBlock(accounts, lookups),
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
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const Key('debt-save'),
                onPressed: _saving ? null : _save,
                child: const Text('Сохранить'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
