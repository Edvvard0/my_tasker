import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/account_actions.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/amount_field.dart';

/// Открывает редактор счёта: [accountId] — правка, иначе создание.
Future<void> showAccountEditor(BuildContext context, {String? accountId}) =>
    showEditorSheet<void>(
      context,
      builder: (_) => AccountEditor(accountId: accountId),
    );

/// Редактор счёта: название, вид, банк, последние 4 цифры (только у
/// карт), начальный баланс и дата открытия, «в общем балансе», кредитный
/// лимит (только у кредитки); у существующего — архив и удаление.
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

  Account? _original;
  AccountKind _kind = AccountKind.debitCard;
  DateTime? _openingDate;
  bool _includeInTotal = true;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.accountId == null;

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
      _kind = account.kind;
      _bank.text = account.bank ?? '';
      _last4.text = account.cardLast4 ?? '';
      _opening.text = account.openingBalance == 0
          ? ''
          : amountInputText(account.openingBalance);
      _openingDate = parseDate(account.openingDate);
      _includeInTotal = account.includeInTotal;
      _limit.text = account.creditLimit == null
          ? ''
          : amountInputText(account.creditLimit!);
    });
  }

  Account _compose(DateTime today) {
    final limit = parseAmountField(_limit.text);
    return Account(
      id: _original?.id ?? ref.read(financeRepositoryProvider).newId(),
      name: _name.text,
      kind: _kind,
      bank: _bank.text,
      cardLast4: _kind.isCard ? _last4.text : null,
      openingBalance: parseAmountField(_opening.text) ?? 0,
      openingDate: formatDate(_openingDate ?? today),
      includeInTotal: _includeInTotal,
      creditLimit: _kind == AccountKind.creditCard && limit != null
          ? limit
          : null,
      archived: _original?.archived ?? false,
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final account = _compose(ref.read(todayProvider));
      if (_original == null) {
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

  Future<void> _archive() async {
    final account = _original;
    if (account == null) return;
    if (await toggleArchiveAccount(context, ref, account) && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    final account = _original;
    if (account == null) return;
    if (await deleteAccountWithConfirm(context, ref, account) && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final title = _isNew ? 'Новый счёт' : 'Счёт';
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
              'Счёт не найден: возможно, его удалили на другом устройстве.',
              key: const Key('acc-missing'),
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = ref.watch(todayProvider);
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
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('acc-name'),
                      controller: _name,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Например, «Т-Банк Black»',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Вид',
                    child: ChipRow(
                      children: [
                        for (final k in AccountKind.values)
                          FilterPill(
                            key: Key('acc-kind-${k.name}'),
                            label: k.label,
                            selected: _kind == k,
                            icon: accountKindIcon(k),
                            onTap: () => setState(() => _kind = k),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Банк',
                    child: FormTextField(
                      key: const Key('acc-bank'),
                      controller: _bank,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Необязательно',
                      ),
                    ),
                  ),
                  if (_kind.isCard)
                    FormBlock(
                      label: 'Последние 4 цифры карты',
                      child: FormTextField(
                        key: const Key('acc-last4'),
                        controller: _last4,
                        maxLength: 4,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(hintText: '4242'),
                      ),
                    ),
                  FormBlock(
                    label: 'Начальный баланс',
                    child: AmountField(
                      key: const Key('acc-opening'),
                      controller: _opening,
                      allowNegative: true,
                    ),
                  ),
                  FormBlock(
                    label: 'Открыт с даты',
                    child: DateChoiceRow(
                      keyPrefix: 'acc-date',
                      today: today,
                      value: _openingDate ?? today,
                      onChanged: (d) => setState(() => _openingDate = d),
                    ),
                  ),
                  if (_kind == AccountKind.creditCard)
                    FormBlock(
                      label: 'Кредитный лимит',
                      child: AmountField(
                        key: const Key('acc-limit'),
                        controller: _limit,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Учитывать в общем балансе',
                            style: t.body,
                          ),
                        ),
                        Switch(
                          key: const Key('acc-include'),
                          value: _includeInTotal,
                          onChanged: (v) => setState(() => _includeInTotal = v),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: Row(
                        key: const Key('acc-error'),
                        children: [
                          Icon(
                            LucideIcons.circleAlert,
                            size: 16,
                            color: c.danger,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _error!,
                              style: t.bodyS.copyWith(color: c.danger),
                            ),
                          ),
                        ],
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
            child: Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!_isNew) ...[
                  OutlinedButton.icon(
                    key: const Key('acc-archive'),
                    onPressed: _archive,
                    icon: Icon(
                      _original!.archived
                          ? LucideIcons.archiveRestore
                          : LucideIcons.archive,
                      size: 18,
                    ),
                    label: Text(_original!.archived ? 'Из архива' : 'В архив'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('acc-delete'),
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.danger,
                      side: BorderSide(color: c.danger),
                    ),
                    icon: const Icon(LucideIcons.trash2, size: 18),
                    label: const Text('Удалить'),
                  ),
                ],
                FilledButton(
                  key: const Key('acc-save'),
                  onPressed: _saving ? null : _save,
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
