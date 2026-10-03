import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/transaction_draft.dart';
import 'package:my_tasker/features/finance/presentation/account_editor.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/privacy/finance_gate.dart';
import 'package:my_tasker/features/finance/presentation/transaction_actions.dart';
import 'package:my_tasker/features/finance/presentation/widgets/amount_field.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_pickers.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

/// Открывает редактор операции. [transactionId] — правка существующей;
/// иначе создание с видом [kind] (по умолчанию расход) и счётом
/// [accountId] (по умолчанию первый активный).
///
/// Если раздел закрыт замком (операцию создают из общего «+» в другом
/// разделе), сначала просит PIN: без разблокировки редактор не открывается.
Future<void> showTransactionEditor(
  BuildContext context, {
  String? transactionId,
  TransactionKind kind = TransactionKind.expense,
  String? accountId,
}) async {
  if (!await ensureFinanceUnlocked(context)) return;
  if (!context.mounted) return;
  await showEditorSheet<void>(
    context,
    builder: (_) => TransactionEditor(
      transactionId: transactionId,
      initialKind: kind,
      initialAccountId: accountId,
    ),
  );
}

/// Редактор операции (02, 4.4): сегмент «Расход / Доход / Перевод», поле
/// суммы с автоформатом и чипами, счёт (у перевода «откуда → куда»),
/// категория нужного вида, дата и время, мерчант, комментарий.
class TransactionEditor extends ConsumerStatefulWidget {
  const TransactionEditor({
    this.transactionId,
    this.initialKind = TransactionKind.expense,
    this.initialAccountId,
    super.key,
  });

  final String? transactionId;
  final TransactionKind initialKind;
  final String? initialAccountId;

  @override
  ConsumerState<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends ConsumerState<TransactionEditor> {
  final _amount = TextEditingController();
  final _merchant = TextEditingController();
  final _comment = TextEditingController();

  late TransactionDraft _draft;
  FinanceTransaction? _original;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.transactionId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      final now = ref.read(nowProvider);
      _draft = TransactionDraft(
        kind: widget.initialKind,
        occurredAt: DateTime.fromMillisecondsSinceEpoch(
          now.millisecondsSinceEpoch ~/ 1000 * 1000,
          isUtc: true,
        ),
        accountId: widget.initialAccountId,
      );
      _loading = false;
    } else {
      _draft = TransactionDraft(
        kind: widget.initialKind,
        occurredAt: ref.read(nowProvider),
      );
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
        .getTransaction(widget.transactionId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (tx == null) {
        _missing = true;
        return;
      }
      _original = tx;
      _draft = TransactionDraft.fromTransaction(tx);
      _amount.text = amountInputText(tx.amount);
      _merchant.text = tx.merchant ?? '';
      _comment.text = tx.comment ?? '';
    });
  }

  void _update(TransactionDraft next) => setState(() {
    _draft = next;
    _error = null;
  });

  /// Счёт по умолчанию — первый активный; у нового перевода «куда» — второй.
  void _ensureDefaults(List<Account> accounts) {
    if (accounts.isEmpty || !_isNew) return;
    var next = _draft;
    if (next.accountId == null ||
        !accounts.any((a) => a.id == next.accountId)) {
      next = next.copyWith(accountId: accounts.first.id);
    }
    if (next.isTransfer && next.toAccountId == null && accounts.length > 1) {
      next = next.copyWith(
        toAccountId: accounts.firstWhere((a) => a.id != next.accountId).id,
      );
    }
    _draft = next;
  }

  Future<void> _save() async {
    if (_saving) return;
    final problem = _draft.problem;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final original = _original;
      if (original == null) {
        await repo.createTransaction(_draft.toTransaction(repo.newId()));
      } else {
        await repo.updateTransaction(
          _draft.toTransaction(original.id, base: original),
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
    await deleteTransactionWithUndo(context, ref, original);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickAccount({required bool destination}) async {
    final accounts = ref.read(activeAccountsProvider).value ?? const [];
    final exclude = destination ? _draft.accountId : null;
    final picked = await showAccountPicker(
      context,
      accounts: [
        for (final a in accounts)
          if (a.id != exclude) a,
      ],
      balances: ref.read(financeBalancesProvider).value,
      selectedId: destination ? _draft.toAccountId : _draft.accountId,
      title: destination
          ? 'Куда'
          : _draft.isTransfer
          ? 'Откуда'
          : 'Счёт',
    );
    if (picked == null) return;
    _update(
      destination
          ? _draft.copyWith(toAccountId: picked)
          : _draft.withAccount(picked),
    );
  }

  Future<void> _pickCategory() async {
    final categories = ref.read(categoriesProvider).value ?? const [];
    final pick = await showCategoryPicker(
      context,
      categories: categories,
      kind: _draft.kind == TransactionKind.income
          ? CategoryKind.income
          : CategoryKind.expense,
      selectedId: _draft.categoryId,
    );
    if (pick == null) return;
    _update(_draft.copyWith(categoryId: pick.id));
  }

  DateTime _wall() =>
      utcToWall(ref.read(deviceTimeZoneProvider), _draft.occurredAt);

  void _setWall(DateTime date, TimeOfDay time) {
    final zone = ref.read(deviceTimeZoneProvider);
    _update(
      _draft.copyWith(
        occurredAt: wallToUtc(
          zone,
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ),
      ),
    );
  }

  Widget _errorRow(String text) {
    final c = context.colors;
    return Row(
      key: const Key('tx-error'),
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
    );
  }

  Widget _backdatedWarning(List<String> names) {
    final c = context.colors;
    final t = context.text;
    return Container(
      key: const Key('tx-backdated-warning'),
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
              names.length == 1
                  ? 'Операция раньше последней сверки счёта «${names.single}». '
                        'Баланс счёта не изменится: сверка считается точной на '
                        'свой момент.'
                  : 'Операция раньше последней сверки счетов '
                        '${names.map((n) => '«$n»').join(', ')}. Их баланс не '
                        'изменится: сверка считается точной на свой момент.',
              style: t.bodyS,
            ),
          ),
        ],
      ),
    );
  }

  Widget _noAccounts() => Padding(
    padding: const EdgeInsets.all(AppSpacing.s6),
    child: Column(
      key: const Key('tx-no-accounts'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Сначала добавь счёт', style: context.text.h3),
        const SizedBox(height: AppSpacing.s1),
        Text(
          'Операция всегда записывается на счёт: наличные, карту или вклад.',
          style: context.text.bodyS.copyWith(
            color: context.colors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        FilledButton(
          key: const Key('tx-add-account'),
          onPressed: () => unawaited(showAccountEditor(context)),
          child: const Text('Добавить счёт'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final title = _isNew ? 'Новая операция' : 'Операция';
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
              'Операция не найдена: возможно, её удалили на другом '
              'устройстве.',
              key: const Key('tx-missing'),
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final accountsAsync = ref.watch(activeAccountsProvider);
    if (!accountsAsync.hasValue) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final accounts = accountsAsync.requireValue;
    final lookups = ref.watch(financeLookupsProvider).value;
    final checkpoints = ref.watch(checkpointsProvider).value ?? const [];
    if (accounts.isEmpty && _isNew) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: title),
          _noAccounts(),
        ],
      );
    }
    _ensureDefaults(accounts);
    final today = ref.watch(todayProvider);
    final wall = _wall();
    final names = [
      for (final id in _draft.backdatedAccounts(checkpoints))
        lookups?.accountName(id) ?? 'Счёт',
    ];
    final account = lookups?.account(_draft.accountId);
    final toAccount = lookups?.account(_draft.toAccountId);
    final category = lookups?.category(_draft.categoryId);
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
                    child: SegmentedPill<TransactionKind>(
                      keyPrefix: 'tx-kind',
                      options: {
                        for (final k in TransactionKind.values) k: k.label,
                      },
                      selected: _draft.kind,
                      onChanged: (k) => _update(
                        _draft.withKind(
                          k,
                          categoryKind: lookups
                              ?.category(_draft.categoryId)
                              ?.kind,
                        ),
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Сумма',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AmountField(
                          key: const Key('tx-amount'),
                          controller: _amount,
                          autofocus: _isNew,
                          onChanged: (v) =>
                              _update(_draft.copyWith(amountText: v)),
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        AmountChips(
                          controller: _amount,
                          keyPrefix: 'tx-chip',
                          onChanged: (v) =>
                              _update(_draft.copyWith(amountText: v)),
                        ),
                      ],
                    ),
                  ),
                  if (_draft.isTransfer) ...[
                    FormBlock(
                      label: 'Откуда',
                      child: PickerTile(
                        key: const Key('tx-from'),
                        icon: account == null
                            ? LucideIcons.wallet
                            : accountKindIcon(account.kind),
                        text: account?.name ?? 'Выбери счёт',
                        hint: account == null,
                        onTap: () => _pickAccount(destination: false),
                      ),
                    ),
                    FormBlock(
                      label: 'Куда',
                      child: PickerTile(
                        key: const Key('tx-to'),
                        icon: toAccount == null
                            ? LucideIcons.wallet
                            : accountKindIcon(toAccount.kind),
                        text: toAccount?.name ?? 'Выбери счёт',
                        hint: toAccount == null,
                        onTap: () => _pickAccount(destination: true),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const Key('tx-swap'),
                        onPressed: _draft.toAccountId == null
                            ? null
                            : () => _update(_draft.swapped()),
                        icon: const Icon(LucideIcons.arrowUpDown, size: 16),
                        label: const Text('Поменять местами'),
                      ),
                    ),
                  ] else ...[
                    FormBlock(
                      label: 'Счёт',
                      child: PickerTile(
                        key: const Key('tx-account'),
                        icon: account == null
                            ? LucideIcons.wallet
                            : accountKindIcon(account.kind),
                        text: account?.name ?? 'Выбери счёт',
                        hint: account == null,
                        onTap: () => _pickAccount(destination: false),
                      ),
                    ),
                    FormBlock(
                      label: 'Категория',
                      child: PickerTile(
                        key: const Key('tx-category'),
                        icon: categoryIcon(category?.icon),
                        text: category?.name ?? 'Без категории',
                        hint: category == null,
                        onTap: _pickCategory,
                      ),
                    ),
                  ],
                  FormBlock(
                    label: 'Дата',
                    child: DateChoiceRow(
                      keyPrefix: 'tx-date',
                      today: today,
                      value: civil(wall.year, wall.month, wall.day),
                      onChanged: (d) => _setWall(
                        d!,
                        TimeOfDay(hour: wall.hour, minute: wall.minute),
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Время',
                    child: TimeChoiceRow(
                      keyPrefix: 'tx-time',
                      allowNone: false,
                      value: TimeOfDay(hour: wall.hour, minute: wall.minute),
                      onChanged: (v) =>
                          _setWall(civil(wall.year, wall.month, wall.day), v!),
                    ),
                  ),
                  if (names.isNotEmpty) _backdatedWarning(names),
                  FormBlock(
                    label: 'Мерчант',
                    child: FormTextField(
                      key: const Key('tx-merchant'),
                      controller: _merchant,
                      textInputAction: TextInputAction.next,
                      onChanged: (v) => _update(_draft.copyWith(merchant: v)),
                      decoration: InputDecoration(
                        hintText: _draft.kind == TransactionKind.income
                            ? 'От кого'
                            : 'Магазин или кому',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Комментарий',
                    child: FormTextField(
                      key: const Key('tx-comment'),
                      controller: _comment,
                      minLines: 2,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      onChanged: (v) => _update(_draft.copyWith(comment: v)),
                      decoration: const InputDecoration(hintText: 'Заметка'),
                    ),
                  ),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  _errorRow(_error!),
                  const SizedBox(height: AppSpacing.s2),
                ],
                Row(
                  children: [
                    if (!_isNew)
                      OutlinedButton.icon(
                        key: const Key('tx-delete'),
                        onPressed: _delete,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.danger,
                          side: BorderSide(color: c.danger),
                        ),
                        icon: const Icon(LucideIcons.trash2, size: 18),
                        label: const Text('Удалить'),
                      ),
                    const Spacer(),
                    FilledButton(
                      key: const Key('tx-save'),
                      onPressed: _saving ? null : _save,
                      child: const Text('Сохранить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
