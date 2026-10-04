import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает форму счёта: [accountId] — правка, иначе новый счёт.
Future<void> showAccountEditor(BuildContext context, {String? accountId}) =>
    showEditorSheet<void>(
      context,
      builder: (_) => AccountEditor(accountId: accountId),
    );

/// Форма счёта (spec 1.1): название, вид, банк, последние 4 цифры карты,
/// начальный остаток и дата, «учитывать в общем балансе», лимит кредитки
/// (справочно), архив. Кредитка — обычный счёт с балансом.
class AccountEditor extends ConsumerStatefulWidget {
  const AccountEditor({this.accountId, super.key});

  final String? accountId;

  @override
  ConsumerState<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends ConsumerState<AccountEditor> {
  final _name = TextEditingController();
  final _bank = TextEditingController();
  final _last4 = TextEditingController();
  final _opening = TextEditingController();
  final _limit = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  Account? _original;
  AccountKind _kind = AccountKind.debitCard;
  late DateTime _date;
  bool _includeInTotal = true;
  bool _archived = false;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.accountId == null;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider)().toUtc();
    _date = parseDate(moscowDay(now))!;
    if (_isNew) {
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _bank.dispose();
    _last4.dispose();
    _opening.dispose();
    _limit.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final account = await ref
        .read(financeRepositoryProvider)
        .getAccount(widget.accountId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (account == null) {
        _missing = true;
        return;
      }
      _original = account;
      _name.text = account.name;
      _bank.text = account.bank ?? '';
      _last4.text = account.cardLast4 ?? '';
      _opening.text = signedMoneyText(account.openingBalance);
      _limit.text = account.creditLimit == null
          ? ''
          : signedMoneyText(account.creditLimit);
      _kind = account.kind;
      _date = parseDate(account.openingDate) ?? _date;
      _includeInTotal = account.includeInTotal;
      _archived = account.archived;
    });
  }

  Future<void> _toggleArchive(bool value) async {
    final original = _original;
    if (value && original != null) {
      final data = ref.read(financeDataProvider).value;
      final balance = data?.balanceOf(original.id) ?? 0;
      if (balance != 0 && original.includeInTotal) {
        final ok = await showConfirmDialog(
          context,
          title: 'В архив со средствами?',
          message:
              'Архив только скрывает счёт из списков, его баланс останется в '
              'общем. Чтобы убрать деньги из общей суммы, снимите флаг «В '
              'общем балансе».',
          confirmLabel: 'В архив',
        );
        if (!ok || !mounted) return;
      }
    }
    setState(() => _archived = value);
  }

  Future<void> _save() async {
    if (_saving) return;
    final opening = parseSignedMoney(_opening.text, 'Начальный остаток');
    if (opening.error != null) {
      setState(() => _error = opening.error);
      return;
    }
    int? limit;
    if (_kind == AccountKind.creditCard && _limit.text.trim().isNotEmpty) {
      final parsed = tryParseAmount(_limit.text);
      if (parsed == null || parsed < 0) {
        setState(
          () => _error = 'Кредитный лимит: введите сумму, например 300 000',
        );
        return;
      }
      limit = parsed;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final last4 = _last4.text.trim();
      final account = Account(
        id: _original?.id ?? repo.newId(),
        name: _name.text,
        kind: _kind,
        bank: _bank.text,
        cardLast4: _kind.isCard && last4.isNotEmpty ? last4 : null,
        openingBalance: opening.kopecks ?? 0,
        openingDate: formatDate(_date),
        includeInTotal: _includeInTotal,
        creditLimit: limit,
        archived: _archived,
      );
      if (_isNew) {
        await repo.createAccount(account);
      } else {
        await repo.updateAccount(account);
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
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить счёт?',
      message:
          'Счёт уйдёт в корзину вместе со всеми его операциями (в том числе '
          'переводами на него и с него) и сверками. Вернуть можно в течение '
          '30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(financeRepositoryProvider).deleteAccount(widget.accountId!);
    if (mounted) Navigator.of(context).pop();
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
          const SheetHeader(title: 'Счёт'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Счёт не найден: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = parseDate(moscowDay(ref.watch(clockProvider)().toUtc()))!;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый счёт' : 'Счёт'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('account-name'),
                      controller: _name,
                      autofocus: _isNew,
                      decoration: const InputDecoration(
                        hintText: 'Например, Т-Банк',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Вид',
                    child: ChipRow(
                      children: [
                        for (final k in AccountKind.values)
                          FilterPill(
                            key: Key('account-kind-${k.wire}'),
                            label: k.label,
                            selected: _kind == k,
                            onTap: () => setState(() => _kind = k),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Банк',
                    child: FormTextField(
                      key: const Key('account-bank'),
                      controller: _bank,
                      decoration: const InputDecoration(
                        hintText: 'Необязательно',
                      ),
                    ),
                  ),
                  if (_kind.isCard)
                    FormBlock(
                      label: 'Последние 4 цифры карты',
                      child: FormTextField(
                        key: const Key('account-last4'),
                        controller: _last4,
                        maxLength: 4,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          hintText: '1234',
                          counterText: '',
                        ),
                      ),
                    ),
                  FormBlock(
                    label: 'Начальный остаток',
                    child: SignedMoneyField(
                      key: const Key('account-opening'),
                      controller: _opening,
                    ),
                  ),
                  FormBlock(
                    label: 'С какой даты (по Москве)',
                    child: DateChoiceRow(
                      keyPrefix: 'account-date',
                      today: today,
                      value: _date,
                      onChanged: (d) => setState(() => _date = d!),
                    ),
                  ),
                  if (_kind == AccountKind.creditCard)
                    FormBlock(
                      label: 'Кредитный лимит (справочно)',
                      child: SignedMoneyField(
                        key: const Key('account-limit'),
                        controller: _limit,
                        hint: 'Необязательно',
                      ),
                    ),
                  SwitchListTile(
                    key: const Key('account-in-total'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('В общем балансе', style: t.body),
                    subtitle: Text(
                      'Учитывать счёт в общей сумме',
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                    value: _includeInTotal,
                    onChanged: (v) => setState(() => _includeInTotal = v),
                  ),
                  if (!_isNew)
                    SwitchListTile(
                      key: const Key('account-archived'),
                      contentPadding: EdgeInsets.zero,
                      title: Text('В архиве', style: t.body),
                      subtitle: Text(
                        'Скрыть из списков; на расчёты не влияет',
                        style: t.caption.copyWith(color: c.textSecondary),
                      ),
                      value: _archived,
                      onChanged: _toggleArchive,
                    ),
                  const SizedBox(height: AppSpacing.s2),
                  if (_error != null)
                    FormError(_error!, key: const Key('account-error')),
                ],
              ),
            ),
          ),
          EditorActions(
            saveKey: const Key('account-save'),
            onSave: _save,
            saving: _saving,
            deleteKey: const Key('account-delete'),
            onDelete: _isNew ? null : _delete,
          ),
        ],
      ),
    );
  }
}

/// Пустое «добавить счёт» для пустых экранов.
Widget addAccountButton(BuildContext context) => FilledButton.icon(
  key: const Key('finance-add-account'),
  onPressed: () => showAccountEditor(context),
  icon: const Icon(LucideIcons.plus, size: 18),
  label: const Text('Добавить счёт'),
);
