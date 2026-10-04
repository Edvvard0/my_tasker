import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart'
    show WorkPerson;
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show
        FormError,
        MoneyTextField,
        dateFromText,
        dateToText,
        moneyFieldText,
        parseMoneyField;
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show PaidBar;

/// «Долги»: мне должны / я должен, остатки с частичными погашениями
/// (статус вычисляется), срок и просрочка.
class DebtsScreen extends ConsumerStatefulWidget {
  const DebtsScreen({super.key});

  @override
  ConsumerState<DebtsScreen> createState() => _DebtsScreenState();
}

class _DebtsScreenState extends ConsumerState<DebtsScreen> {
  DebtDirection _direction = DebtDirection.owedToMe;
  bool _closed = false;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      key: const Key('debts-screen'),
      title: 'Долги',
      parentLabel: 'Финансы',
      onBack: () => financeBack(context),
      actions: [
        IconButton(
          key: const Key('debts-add'),
          tooltip: 'Новый долг',
          onPressed: () => showDebtEditor(context, direction: _direction),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: FinanceBuilder(
        builder: (context, data) => _Body(
          data: data,
          direction: _direction,
          closed: _closed,
          onDirection: (d) => setState(() => _direction = d),
          onClosed: (v) => setState(() => _closed = v),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.data,
    required this.direction,
    required this.closed,
    required this.onDirection,
    required this.onClosed,
  });

  final FinanceData data;
  final DebtDirection direction;
  final bool closed;
  final ValueChanged<DebtDirection> onDirection;
  final ValueChanged<bool> onClosed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final summary = data.debtSummary;
    final debts = [
      for (final d in data.debts)
        if (d.direction == direction &&
            ((summary.stateOf(d.id)?.status == DebtStatus.closed) == closed))
          d,
    ];
    final total = direction == DebtDirection.owedToMe
        ? summary.owedToMe
        : summary.iOwe;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                direction.label.toUpperCase(),
                style: t.overline.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s1),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AmountText(
                  total,
                  style: t.display,
                  textKey: const Key('debts-total'),
                ),
              ),
              Text(
                'Открытые остатки без закрытых долгов',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
        ChipRow(
          children: [
            for (final d in DebtDirection.values)
              FilterPill(
                key: Key('debts-direction-${d.wire}'),
                label: d.label,
                selected: direction == d,
                onTap: () => onDirection(d),
              ),
            FilterPill(
              key: const Key('debts-closed'),
              label: 'Закрытые',
              selected: closed,
              onTap: () => onClosed(!closed),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        if (debts.isEmpty)
          EmptyState(
            key: const Key('debts-empty'),
            icon: LucideIcons.handCoins,
            title: closed ? 'Закрытых долгов нет' : 'Долгов нет',
            message: closed
                ? 'Сюда попадают полностью погашенные долги.'
                : 'Запишите, кто вам должен или кому должны вы: возвраты '
                      'можно отмечать частями.',
            action: closed
                ? null
                : FilledButton(
                    key: const Key('debts-empty-add'),
                    onPressed: () =>
                        showDebtEditor(context, direction: direction),
                    child: const Text('Добавить долг'),
                  ),
          )
        else
          for (final d in debts) ...[
            _DebtCard(data: data, debt: d, state: summary.stateOf(d.id)!),
            const SizedBox(height: AppSpacing.s2),
          ],
        if (!closed && direction == DebtDirection.owedToMe) ...[
          const FinanceSection(title: 'Из «Работы»'),
          AppCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              key: const Key('debts-work-link'),
              borderRadius: AppRadii.borderL,
              onTap: () => context.push('/finance/work'),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Ожидаемые поступления по проектам',
                        style: t.body,
                      ),
                    ),
                    AmountText(
                      data.receivables.total,
                      style: t.numM.copyWith(color: c.textSecondary),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Icon(
                      LucideIcons.chevronRight,
                      size: 18,
                      color: c.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _DebtCard extends ConsumerWidget {
  const _DebtCard({
    required this.data,
    required this.debt,
    required this.state,
  });

  final FinanceData data;
  final Debt debt;
  final DebtState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final format = ref.watch(amountFormatProvider);
    final tone = switch (state.status) {
      DebtStatus.open => StatusTone.neutral,
      DebtStatus.partial => StatusTone.warning,
      DebtStatus.closed => StatusTone.success,
    };
    final paidBp = debt.amount <= 0 ? 0 : (state.repaid * 10000 ~/ debt.amount);
    return InkWell(
      key: Key('debt-${debt.id}'),
      borderRadius: AppRadii.borderL,
      onTap: () => showDebtSheet(context, debt.id),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    data.debtorName(debt),
                    style: t.h3,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                StatusPill(label: state.status.label, tone: tone),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    state.status == DebtStatus.closed ? 'Погашен' : 'Осталось',
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                ),
                AmountText(
                  state.status == DebtStatus.closed
                      ? debt.amount
                      : state.remaining,
                  style: t.numL,
                ),
              ],
            ),
            if (state.status != DebtStatus.closed && state.repaid > 0) ...[
              const SizedBox(height: AppSpacing.s2),
              PaidBar(basisPoints: paidBp),
            ],
            const SizedBox(height: AppSpacing.s2),
            Text(
              [
                'из ${format.full(debt.amount)}',
                if (debt.dueDate != null)
                  'срок ${formatDateText(debt.dueDate, data.now)}',
                if (state.overdue) 'просрочен',
              ].join(' · '),
              style: t.caption.copyWith(
                color: state.overdue ? c.textPrimary : c.textSecondary,
                fontWeight: state.overdue ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Форма долга: [debtId] — правка, иначе новый.
Future<void> showDebtEditor(
  BuildContext context, {
  String? debtId,
  DebtDirection direction = DebtDirection.owedToMe,
}) => showEditorSheet<void>(
  context,
  builder: (_) => DebtEditor(debtId: debtId, direction: direction),
);

class DebtEditor extends ConsumerStatefulWidget {
  const DebtEditor({
    this.debtId,
    this.direction = DebtDirection.owedToMe,
    super.key,
  });

  final String? debtId;
  final DebtDirection direction;

  @override
  ConsumerState<DebtEditor> createState() => _DebtEditorState();
}

class _DebtEditorState extends ConsumerState<DebtEditor> {
  final _counterparty = TextEditingController();
  final _amount = TextEditingController();
  final _comment = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  Debt? _original;
  late DebtDirection _direction = widget.direction;
  String? _personId;
  late DateTime _date;
  DateTime? _due;
  String? _accountId;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.debtId == null;

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
    _counterparty.dispose();
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
      _personId = debt.personId;
      _counterparty.text = debt.counterparty ?? '';
      _amount.text = moneyFieldText(debt.amount);
      _comment.text = debt.comment ?? '';
      _date = dateFromText(debt.debtDate) ?? _date;
      _due = dateFromText(debt.dueDate);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount = parseMoneyField(_amount.text, 'Сумма долга');
    if (amount.error != null || amount.kopecks == null) {
      setState(() => _error = amount.error ?? 'Укажите сумму долга');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final debt = Debt(
        id: _original?.id ?? repo.newId(),
        direction: _direction,
        personId: _personId,
        counterparty: _counterparty.text,
        amount: amount.kopecks!,
        debtDate: formatDate(_date),
        dueDate: dateToText(_due),
        comment: _comment.text,
      );
      if (_isNew) {
        await repo.createDebt(debt, accountId: _accountId);
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

  Future<void> _delete() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить долг?',
      message:
          'Долг и его погашения уйдут в корзину. Операции по счетам останутся: '
          'деньги реально двигались. Вернуть можно в течение 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(financeRepositoryProvider).deleteDebt(widget.debtId!);
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
          const SheetHeader(title: 'Долг'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Долг не найден: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = parseDate(moscowDay(ref.watch(clockProvider)().toUtc()))!;
    final people = [
      for (final p
          in ref.watch(workPeopleProvider).value ?? const <WorkPerson>[])
        if (!p.archived || p.id == _personId) p,
    ];
    final accounts = [
      for (final a in ref.watch(accountsProvider).value ?? const <Account>[])
        if (!a.archived) a,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый долг' : 'Долг'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ChipRow(
                    children: [
                      for (final d in DebtDirection.values)
                        FilterPill(
                          key: Key('debt-direction-${d.wire}'),
                          label: d.label,
                          selected: _direction == d,
                          onTap: () => setState(() => _direction = d),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  if (people.isNotEmpty)
                    FormBlock(
                      label: 'Человек из «Работы»',
                      child: ChipRow(
                        children: [
                          FilterPill(
                            key: const Key('debt-person-none'),
                            label: 'Не из списка',
                            selected: _personId == null,
                            onTap: () => setState(() => _personId = null),
                          ),
                          for (final p in people)
                            FilterPill(
                              key: Key('debt-person-${p.id}'),
                              label: p.name,
                              selected: _personId == p.id,
                              icon: LucideIcons.user,
                              onTap: () => setState(() => _personId = p.id),
                            ),
                        ],
                      ),
                    ),
                  FormBlock(
                    label: _personId == null ? 'Кто' : 'Пометка о человеке',
                    child: FormTextField(
                      key: const Key('debt-counterparty'),
                      controller: _counterparty,
                      decoration: InputDecoration(
                        hintText: _personId == null
                            ? 'Имя или название'
                            : 'Необязательно',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Сумма',
                    child: MoneyTextField(
                      key: const Key('debt-amount'),
                      controller: _amount,
                    ),
                  ),
                  FormBlock(
                    label: 'Дата долга',
                    child: DateChoiceRow(
                      keyPrefix: 'debt-date',
                      today: today,
                      value: _date,
                      onChanged: (d) => setState(() => _date = d!),
                    ),
                  ),
                  FormBlock(
                    label: 'Срок',
                    child: DateChoiceRow(
                      keyPrefix: 'debt-due',
                      today: today,
                      value: _due,
                      allowNone: true,
                      noneLabel: 'Без срока',
                      onChanged: (d) => setState(() => _due = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Комментарий',
                    child: FormTextField(
                      key: const Key('debt-comment'),
                      controller: _comment,
                      decoration: const InputDecoration(
                        hintText: 'Необязательно',
                      ),
                    ),
                  ),
                  if (_isNew && accounts.isNotEmpty)
                    FormBlock(
                      label: _direction == DebtDirection.owedToMe
                          ? 'Выдал со счёта'
                          : 'Получил на счёт',
                      child: AccountChips(
                        keyPrefix: 'debt-account',
                        accounts: accounts,
                        selectedId: _accountId,
                        noneLabel: 'Не отражать',
                        onSelect: (id) => setState(() => _accountId = id),
                      ),
                    ),
                  if (_error != null)
                    FormError(_error!, key: const Key('debt-error')),
                ],
              ),
            ),
          ),
          EditorActions(
            saveKey: const Key('debt-save'),
            onSave: _save,
            saving: _saving,
            deleteKey: const Key('debt-delete'),
            onDelete: _isNew ? null : _delete,
          ),
        ],
      ),
    );
  }
}

/// Карточка долга: итоги, погашения и форма «Отметить возврат».
Future<void> showDebtSheet(BuildContext context, String debtId) =>
    showEditorSheet<void>(context, builder: (_) => DebtSheet(debtId: debtId));

class DebtSheet extends ConsumerStatefulWidget {
  const DebtSheet({required this.debtId, super.key});

  final String debtId;

  @override
  ConsumerState<DebtSheet> createState() => _DebtSheetState();
}

class _DebtSheetState extends ConsumerState<DebtSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  DateTime? _date;
  String? _accountId;
  String? _error;
  bool _saving = false;
  bool _amountTouched = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _repay(Debt debt) async {
    if (_saving) return;
    final amount = parseMoneyField(_amount.text, 'Сумма возврата');
    if (amount.error != null || amount.kopecks == null || amount.kopecks == 0) {
      setState(() => _error = amount.error ?? 'Укажите сумму возврата');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await ref
          .read(financeRepositoryProvider)
          .repayDebt(
            debt: debt,
            amount: amount.kopecks!,
            repaidOn: formatDate(_date!),
            accountId: _accountId,
            note: _note.text,
          );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _amount.clear();
        _note.clear();
        _amountTouched = false;
      });
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final data = ref.watch(financeDataProvider).value;
    final debt = data?.debtById[widget.debtId];
    if (data == null) return const EditorLoading();
    if (debt == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Долг'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Долг не найден: возможно, его удалили на другом устройстве.',
              key: const Key('debt-sheet-missing'),
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final state = data.debtSummary.stateOf(debt.id)!;
    final repayments = data.repaymentsOf(debt.id);
    final today = parseDate(data.today)!;
    _date ??= today;
    if (!_amountTouched && _amount.text.isEmpty && state.remaining > 0) {
      _amount.text = moneyFieldText(state.remaining);
    }
    final accounts = [
      for (final a in data.accounts)
        if (!a.archived) a,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            title: data.debtorName(debt),
            trailing: IconButton(
              key: const Key('debt-sheet-edit'),
              tooltip: 'Изменить долг',
              onPressed: () => showDebtEditor(context, debtId: debt.id),
              icon: const Icon(LucideIcons.pencil, size: 20),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _line(
                    context,
                    'Статус',
                    Text(
                      state.status.label,
                      style: t.bodyStrong,
                      key: const Key('debt-status'),
                    ),
                  ),
                  _line(
                    context,
                    'Сумма долга',
                    AmountText(debt.amount, style: t.numM),
                  ),
                  _line(
                    context,
                    'Погашено',
                    AmountText(
                      state.repaid,
                      style: t.numM,
                      textKey: const Key('debt-repaid'),
                    ),
                  ),
                  _line(
                    context,
                    'Осталось',
                    AmountText(
                      state.remaining,
                      style: t.numL,
                      textKey: const Key('debt-remaining'),
                    ),
                  ),
                  if (state.overpaid > 0)
                    FinanceWarning(
                      text:
                          'Погашений больше суммы долга — переплата: '
                          '${ref.watch(amountFormatProvider).full(state.overpaid)}.',
                    ),
                  const FinanceSection(title: 'Погашения'),
                  if (repayments.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                      child: Text(
                        'Возвратов пока не было.',
                        key: const Key('debt-no-repayments'),
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ),
                  for (final r in repayments)
                    ListTile(
                      key: Key('repayment-${r.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: AmountText(r.amount, style: t.numM),
                      subtitle: Text(
                        [
                          formatDateText(r.repaidOn, data.now),
                          if (r.transactionId != null) 'по счёту',
                          if (r.note != null) r.note!,
                        ].join(' · '),
                        style: t.caption.copyWith(color: c.textSecondary),
                      ),
                      trailing: IconButton(
                        key: Key('repayment-delete-${r.id}'),
                        tooltip: 'Удалить погашение',
                        icon: const Icon(LucideIcons.trash2, size: 18),
                        onPressed: () => ref
                            .read(financeRepositoryProvider)
                            .deleteRepayment(r.id),
                      ),
                    ),
                  if (state.remaining > 0) ...[
                    const FinanceSection(title: 'Отметить возврат'),
                    FormBlock(
                      label: 'Сумма',
                      child: MoneyTextField(
                        key: const Key('repay-amount'),
                        controller: _amount,
                        onChanged: (_) => _amountTouched = true,
                      ),
                    ),
                    FormBlock(
                      label: 'Дата',
                      child: DateChoiceRow(
                        keyPrefix: 'repay-date',
                        today: today,
                        value: _date,
                        onChanged: (d) => setState(() => _date = d),
                      ),
                    ),
                    if (accounts.isNotEmpty)
                      FormBlock(
                        label: debt.direction == DebtDirection.owedToMe
                            ? 'Деньги пришли на счёт'
                            : 'Деньги ушли со счёта',
                        child: AccountChips(
                          keyPrefix: 'repay-account',
                          accounts: accounts,
                          selectedId: _accountId,
                          noneLabel: 'Без движения денег',
                          onSelect: (id) => setState(() => _accountId = id),
                        ),
                      ),
                    FormBlock(
                      label: 'Заметка',
                      child: FormTextField(
                        key: const Key('repay-note'),
                        controller: _note,
                        decoration: const InputDecoration(
                          hintText: 'Необязательно',
                        ),
                      ),
                    ),
                    if (_error != null)
                      FormError(_error!, key: const Key('repay-error')),
                  ],
                ],
              ),
            ),
          ),
          if (state.remaining > 0)
            EditorActions(
              saveKey: const Key('repay-save'),
              onSave: () => _repay(debt),
              saving: _saving,
              saveLabel: 'Отметить возврат',
            )
          else
            const SizedBox(height: AppSpacing.s4),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, Widget value) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: context.text.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
          value,
        ],
      ),
    );
  }
}
