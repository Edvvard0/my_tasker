import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/banks/data/bank_drafts.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/account_editor.dart';
import 'package:my_tasker/features/finance/presentation/category_picker.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
import 'package:my_tasker/features/work/domain/work_format.dart'
    show formatDateText;
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError, moneyFieldText, moneyInputFormatters, parseMoneyField;

/// Открывает форму операции: [txId] — правка; иначе новая ([kind],
/// [accountId] — начальные значения). Быстрый ввод: сумма, категория,
/// счёт — три касания, остальное по умолчанию (сегодня, «подтверждена»).
///
/// [prefill] — заготовка для новой операции (например, из нераспознанного
/// уведомления банка, Этап 6); [onSaved] получает id сохранённой операции.
Future<void> showTransactionEditor(
  BuildContext context, {
  String? txId,
  TxKind? kind,
  String? accountId,
  TransactionPrefill? prefill,
  ValueChanged<String>? onSaved,
}) => showEditorSheet<void>(
  context,
  builder: (_) => TransactionEditor(
    txId: txId,
    initialKind: kind,
    accountId: accountId,
    prefill: prefill,
    onSaved: onSaved,
  ),
);

/// Заготовка полей новой операции.
class TransactionPrefill {
  const TransactionPrefill({
    this.amount,
    this.merchant,
    this.comment,
    this.date,
  });

  /// Копейки.
  final int? amount;
  final String? merchant;
  final String? comment;

  /// Момент операции: берётся его московская дата.
  final DateTime? date;
}

/// Форма операции: расход, доход или перевод между своими счетами.
/// Перевод — одна запись «откуда → куда» без категории; он никогда не
/// считается доходом или расходом (spec 4.1).
class TransactionEditor extends ConsumerStatefulWidget {
  const TransactionEditor({
    this.txId,
    this.initialKind,
    this.accountId,
    this.prefill,
    this.onSaved,
    super.key,
  });

  final String? txId;
  final TxKind? initialKind;
  final String? accountId;
  final TransactionPrefill? prefill;
  final ValueChanged<String>? onSaved;

  @override
  ConsumerState<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends ConsumerState<TransactionEditor> {
  final _amount = TextEditingController();
  final _merchant = TextEditingController();
  final _comment = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  FinTransaction? _original;
  late TxKind _kind = widget.initialKind ?? TxKind.expense;
  String? _accountId;
  String? _toAccountId;
  String? _categoryId;
  late DateTime _date;
  String? _error;
  bool _saving = false;
  bool _defaultsApplied = false;

  bool get _isNew => widget.txId == null;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider)().toUtc();
    _date = parseDate(moscowDay(now))!;
    _accountId = widget.accountId;
    if (_isNew) {
      _loading = false;
      final prefill = widget.prefill;
      if (prefill != null) {
        final amount = prefill.amount;
        if (amount != null) _amount.text = moneyFieldText(amount);
        _merchant.text = prefill.merchant ?? '';
        _comment.text = prefill.comment ?? '';
        final date = prefill.date;
        if (date != null) _date = parseDate(moscowDay(date)) ?? _date;
      }
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tx = await ref
        .read(financeRepositoryProvider)
        .getTransaction(widget.txId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (tx == null) {
        _missing = true;
        return;
      }
      _original = tx;
      _kind = tx.kind;
      _amount.text = moneyFieldText(tx.amount);
      _merchant.text = tx.merchant ?? '';
      _comment.text = tx.comment ?? '';
      _accountId = tx.accountId;
      _toAccountId = tx.toAccountId;
      _categoryId = tx.categoryId;
      _date = parseDate(moscowDay(tx.occurredAt)) ?? _date;
      _defaultsApplied = true;
    });
  }

  /// Счёт по умолчанию: счёт последней операции, иначе первый открытый.
  void _applyDefaults(FinanceData data) {
    if (_defaultsApplied) return;
    _defaultsApplied = true;
    if (_accountId == null && data.activeAccounts.isNotEmpty) {
      final last = data.transactions.isEmpty ? null : data.transactions.first;
      final fromLast = last == null ? null : data.accountById[last.accountId];
      _accountId = fromLast != null && !fromLast.archived
          ? fromLast.id
          : data.activeAccounts.first.id;
    }
  }

  DateTime _moment(DateTime now) {
    final original = _original;
    final chosen = formatDate(_date);
    if (original != null && moscowDay(original.occurredAt) == chosen) {
      return original.occurredAt;
    }
    return momentForDate(chosen, now);
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount = parseMoneyField(_amount.text, 'Сумма');
    if (amount.error != null || amount.kopecks == null || amount.kopecks == 0) {
      setState(() => _error = amount.error ?? 'Укажите сумму');
      return;
    }
    if (_accountId == null) {
      setState(() => _error = 'Выберите счёт');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final base = _original;
      final tx = FinTransaction(
        id: base?.id ?? repo.newId(),
        kind: _kind,
        accountId: _accountId!,
        toAccountId: _kind == TxKind.transfer ? _toAccountId : null,
        amount: amount.kopecks!,
        occurredAt: _moment(ref.read(clockProvider)().toUtc()),
        categoryId: _kind == TxKind.transfer ? null : _categoryId,
        merchant: _merchant.text,
        comment: _comment.text,
        source: base?.source ?? TxSource.manual,
        status: base?.status ?? TxStatus.confirmed,
        externalId: base?.externalId,
        dedupHash: base?.dedupHash,
        workPaymentId: _kind == TxKind.income ? base?.workPaymentId : null,
        debtId: _kind == TxKind.transfer ? null : base?.debtId,
      );
      if (_isNew) {
        await repo.createTransaction(tx);
      } else {
        await repo.updateTransaction(tx);
      }
      widget.onSaved?.call(tx.id);
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

  Future<void> _confirmDraft() async {
    // Через Банки: подтверждение закрывает уведомление и создаёт точку
    // сверки по остатку из него (для операций без уведомления — обычное
    // подтверждение).
    await ref.read(bankDraftsProvider).confirm(_original!.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить операцию?',
      message:
          'Операция уйдёт в корзину, баланс счёта и аналитика пересчитаются. '
          'Вернуть можно в течение 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(financeRepositoryProvider).deleteTransaction(widget.txId!);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickCategory() async {
    final kind = _kind == TxKind.income
        ? CategoryKind.income
        : CategoryKind.expense;
    final choice = await showCategoryPicker(context, kind: kind);
    if (choice != null && mounted) setState(() => _categoryId = choice.id);
  }

  /// Самые частые категории вида: быстрый выбор одним касанием.
  List<FinCategory> _frequent(FinanceData data) {
    final kind = _kind == TxKind.income
        ? CategoryKind.income
        : CategoryKind.expense;
    final counts = <String, int>{};
    for (final t in data.transactions) {
      final id = t.categoryId;
      if (t.kind == _kind &&
          id != null &&
          data.categoryById[id]?.kind == kind) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    final ids = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final picked = [for (final id in ids.take(5)) data.categoryById[id]!];
    if (picked.length < 5) {
      for (final node in data.categoryTree(kind)) {
        if (picked.length >= 5) break;
        if (!picked.any((p) => p.id == node.category.id)) {
          picked.add(node.category);
        }
      }
    }
    return picked;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    if (_loading) return const EditorLoading();
    if (_missing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Операция'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Операция не найдена: возможно, её удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final data = ref.watch(financeDataProvider).value;
    if (data == null) return const EditorLoading();
    _applyDefaults(data);
    if (data.activeAccounts.isEmpty && data.accounts.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Новая операция'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Column(
              children: [
                Text(
                  'Сначала добавьте счёт: операции записываются на счёт.',
                  key: const Key('tx-no-accounts'),
                  style: t.body.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s4),
                addAccountButton(context),
              ],
            ),
          ),
        ],
      );
    }
    final today = parseDate(moscowDay(ref.watch(clockProvider)().toUtc()))!;
    final accounts = [
      for (final a in data.accounts)
        if (!a.archived || a.id == _accountId || a.id == _toAccountId) a,
    ];
    final isTransfer = _kind == TxKind.transfer;
    final frequent = isTransfer ? const <FinCategory>[] : _frequent(data);
    final selected = _categoryId == null
        ? null
        : data.categoryById[_categoryId];
    final moment = _moment(ref.watch(clockProvider)().toUtc());
    final backdated =
        _accountId != null &&
        isBeforeLastCheckpoint(_accountId!, moment, data.checkpoints);
    final account = data.accountById[_accountId];
    final beforeOpening = account != null && isBeforeOpening(account, moment);
    final future =
        formatDate(_date)
            .compareTo(moscowDay(ref.watch(clockProvider)().toUtc())) >
        0;
    final original = _original;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новая операция' : 'Операция'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ChipRow(
                    children: [
                      for (final k in TxKind.values)
                        FilterPill(
                          key: Key('tx-kind-${k.wire}'),
                          label: k.label,
                          selected: _kind == k,
                          onTap: () => setState(() {
                            if (_kind != k) _categoryId = null;
                            _kind = k;
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  FormTextField(
                    key: const Key('tx-amount'),
                    controller: _amount,
                    autofocus: _isNew,
                    style: t.display,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: moneyInputFormatters,
                    decoration: InputDecoration(
                      hintText: '0',
                      suffixText: '₽',
                      suffixStyle: t.h2.copyWith(color: c.textSecondary),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  FormBlock(
                    label: isTransfer ? 'Откуда' : 'Счёт',
                    child: AccountChips(
                      keyPrefix: 'tx-account',
                      accounts: accounts,
                      selectedId: _accountId,
                      onSelect: (id) => setState(() => _accountId = id),
                    ),
                  ),
                  if (isTransfer)
                    FormBlock(
                      label: 'Куда',
                      child: AccountChips(
                        keyPrefix: 'tx-to-account',
                        accounts: [
                          for (final a in accounts)
                            if (a.id != _accountId) a,
                        ],
                        selectedId: _toAccountId,
                        onSelect: (id) => setState(() => _toAccountId = id),
                      ),
                    ),
                  if (!isTransfer)
                    FormBlock(
                      label: 'Категория',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (frequent.isNotEmpty)
                            ChipRow(
                              children: [
                                for (final f in frequent)
                                  FilterPill(
                                    key: Key('tx-category-${f.id}'),
                                    label: f.name,
                                    selected: _categoryId == f.id,
                                    onTap: () => setState(
                                      () => _categoryId = _categoryId == f.id
                                          ? null
                                          : f.id,
                                    ),
                                  ),
                              ],
                            ),
                          const SizedBox(height: AppSpacing.s2),
                          PickerField(
                            key: const Key('tx-category-pick'),
                            text: selected == null
                                ? 'Без категории'
                                : data.categoryTitle(selected.id),
                            placeholder: selected == null,
                            onTap: _pickCategory,
                          ),
                        ],
                      ),
                    ),
                  FormBlock(
                    label: 'Дата (по Москве)',
                    child: DateChoiceRow(
                      keyPrefix: 'tx-date',
                      today: today,
                      value: _date,
                      onChanged: (d) => setState(() => _date = d!),
                    ),
                  ),
                  if (!isTransfer)
                    FormBlock(
                      label: 'Контрагент',
                      child: FormTextField(
                        key: const Key('tx-merchant'),
                        controller: _merchant,
                        decoration: const InputDecoration(
                          hintText: 'Например, Пятёрочка',
                        ),
                      ),
                    ),
                  FormBlock(
                    label: 'Комментарий',
                    child: FormTextField(
                      key: const Key('tx-comment'),
                      controller: _comment,
                      decoration: const InputDecoration(
                        hintText: 'Необязательно',
                      ),
                    ),
                  ),
                  if (backdated)
                    const _NoteLine(
                      key: Key('tx-backdated'),
                      text:
                          'Операция не позже последней сверки: баланс '
                          'счёта она не изменит — сверка считается истиной '
                          'на свой момент.',
                    ),
                  if (beforeOpening && !backdated)
                    _NoteLine(
                      key: const Key('tx-before-opening'),
                      text:
                          'Дата раньше открытия счёта (${formatDateText(account.openingDate, data.now)}): '
                          'баланс счёта операция не изменит — остаток на '
                          'открытие уже учитывает всё, что было до него.',
                    ),
                  if (future)
                    const _NoteLine(
                      key: Key('tx-future'),
                      text:
                          'Дата в будущем: операция сразу войдёт в текущий '
                          'баланс. Проверьте, что дата верна.',
                    ),
                  if (original != null && !original.isConfirmed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: OutlinedButton.icon(
                        key: const Key('tx-confirm'),
                        onPressed: _confirmDraft,
                        icon: const Icon(LucideIcons.check, size: 18),
                        label: Text('Подтвердить (${original.status.label})'),
                      ),
                    ),
                  if (_error != null)
                    FormError(_error!, key: const Key('tx-error')),
                ],
              ),
            ),
          ),
          EditorActions(
            saveKey: const Key('tx-save'),
            onSave: _save,
            saving: _saving,
            deleteKey: const Key('tx-delete'),
            onDelete: _isNew ? null : _delete,
          ),
        ],
      ),
    );
  }
}

/// Подпись «+ Операция» для кнопок: единая точка входа в форму.
void openNewTransaction(BuildContext context, {String? accountId}) =>
    unawaited(showTransactionEditor(context, accountId: accountId));

/// Пояснение под полями формы: значок и мелкий текст.
class _NoteLine extends StatelessWidget {
  const _NoteLine({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: 16, color: c.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: context.text.caption.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
