import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
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

/// Форма цели: [goalId] — правка, иначе новая с формулой по умолчанию
/// (случай Excel: все счета + долги мне + ожидаемые из «Работы»).
Future<void> showGoalEditor(BuildContext context, {String? goalId}) =>
    showEditorSheet<void>(context, builder: (_) => GoalEditor(goalId: goalId));

/// Конструктор формулы «Есть»: список слагаемых с знаком +/−; живой
/// предпросмотр «Есть» и «Не хватает» по текущим данным.
class GoalEditor extends ConsumerStatefulWidget {
  const GoalEditor({this.goalId, super.key});

  final String? goalId;

  @override
  ConsumerState<GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends ConsumerState<GoalEditor> {
  final _name = TextEditingController();
  final _target = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  Goal? _original;
  List<GoalTerm> _formula = defaultGoalFormula();
  DateTime? _deadline;
  bool _archived = false;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.goalId == null;

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
    _target.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final goal = await ref
        .read(financeRepositoryProvider)
        .getGoal(widget.goalId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (goal == null) {
        _missing = true;
        return;
      }
      _original = goal;
      _name.text = goal.name;
      _target.text = moneyFieldText(goal.targetAmount);
      _deadline = dateFromText(goal.deadlineDate);
      _formula = [...goal.formula];
      _archived = goal.archived;
    });
  }

  void _addTerm(GoalTermKind kind) => setState(() {
    _formula = [
      ..._formula,
      GoalTerm(
        kind: kind,
        // «Мои долги» по умолчанию вычитаются (spec 6.2).
        plus: kind != GoalTermKind.myDebts,
      ),
    ];
  });

  void _replace(int index, GoalTerm term) => setState(() {
    _formula = [..._formula]..[index] = term;
  });

  void _remove(int index) => setState(() {
    _formula = [
      for (var i = 0; i < _formula.length; i++)
        if (i != index) _formula[i],
    ];
  });

  Goal _draft() => Goal(
    id: _original?.id ?? 'draft',
    name: _name.text,
    targetAmount: tryParseKopecks(_target.text) ?? 0,
    deadlineDate: dateToText(_deadline),
    formula: _formula,
    archived: _archived,
  );

  Future<void> _save() async {
    if (_saving) return;
    final target = parseMoneyField(_target.text, 'Целевая сумма');
    if (target.error != null || target.kopecks == null) {
      setState(() => _error = target.error ?? 'Укажите целевую сумму');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final goal = _draft().copyWith(targetAmount: target.kopecks);
      if (_isNew) {
        await repo.createGoal(
          Goal(
            id: repo.newId(),
            name: goal.name,
            targetAmount: goal.targetAmount,
            deadlineDate: goal.deadlineDate,
            formula: goal.formula,
          ),
        );
      } else {
        await repo.updateGoal(goal);
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
      title: 'Удалить цель?',
      message: 'Цель уйдёт в корзину. Вернуть можно в течение 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(financeRepositoryProvider).deleteGoal(widget.goalId!);
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
          const SheetHeader(title: 'Цель'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Цель не найдена: возможно, её удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final data = ref.watch(financeDataProvider).value;
    final format = ref.watch(amountFormatProvider);
    final today = parseDate(moscowDay(ref.watch(clockProvider)().toUtc()))!;
    final overlap =
        _formula.any((x) => x.kind == GoalTermKind.allAccounts) &&
        _formula.any((x) => x.kind == GoalTermKind.accounts);
    GoalProgress? preview;
    final draft = _draft();
    if (data != null && draft.targetAmount > 0 && _formula.isNotEmpty) {
      preview = goalProgress(
        draft,
        accounts: data.accounts,
        transactions: data.transactions,
        checkpoints: data.checkpoints,
        debts: data.debts,
        repayments: data.repayments,
        projects: data.work.projects,
        changeRequests: data.work.changeRequests,
        allocations: data.work.allocations,
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новая цель' : 'Цель'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('goal-name'),
                      controller: _name,
                      autofocus: _isNew,
                      decoration: const InputDecoration(
                        hintText: 'Например, Подушка',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Цель',
                    child: MoneyTextField(
                      key: const Key('goal-target'),
                      controller: _target,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  FormBlock(
                    label: 'Срок',
                    child: DateChoiceRow(
                      keyPrefix: 'goal-deadline',
                      today: today,
                      value: _deadline,
                      allowNone: true,
                      noneLabel: 'Без срока',
                      onChanged: (d) => setState(() => _deadline = d),
                    ),
                  ),
                  const FieldLabel('Из чего складывается «Есть»'),
                  for (var i = 0; i < _formula.length; i++)
                    _TermEditor(
                      key: Key('goal-term-$i'),
                      index: i,
                      term: _formula[i],
                      data: data,
                      onChanged: (term) => _replace(i, term),
                      onRemove: () => _remove(i),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: PopupMenuButton<GoalTermKind>(
                      key: const Key('goal-add-term'),
                      tooltip: 'Добавить слагаемое',
                      onSelected: _addTerm,
                      itemBuilder: (_) => [
                        for (final k in GoalTermKind.values)
                          PopupMenuItem<GoalTermKind>(
                            key: Key('goal-add-term-${k.wire}'),
                            value: k,
                            child: Text(k.label),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.s2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.plus, size: 18, color: c.accent),
                            const SizedBox(width: 6),
                            Text(
                              'Добавить слагаемое',
                              style: t.label.copyWith(color: c.accent),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (overlap)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            LucideIcons.triangleAlert,
                            size: 16,
                            color: c.textPrimary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '«Все счета» и «Конкретные счета» могут учесть '
                              'один счёт дважды: слагаемые считаются '
                              'независимо.',
                              key: const Key('goal-overlap'),
                              style: t.caption.copyWith(color: c.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (preview != null) ...[
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      'Сейчас: есть ${format.full(preview.have)}',
                      key: const Key('goal-preview-have'),
                      style: t.body,
                    ),
                    Text(
                      preview.reached
                          ? 'Цель достигнута ${format.signed(preview.surplus)}'
                          : 'Не хватает ${format.full(preview.missing)}',
                      key: const Key('goal-preview-missing'),
                      style: t.bodyStrong,
                    ),
                  ],
                  if (!_isNew)
                    SwitchListTile(
                      key: const Key('goal-archived'),
                      contentPadding: EdgeInsets.zero,
                      title: Text('В архиве', style: t.body),
                      value: _archived,
                      onChanged: (v) => setState(() => _archived = v),
                    ),
                  const SizedBox(height: AppSpacing.s2),
                  if (_error != null)
                    FormError(_error!, key: const Key('goal-error')),
                ],
              ),
            ),
          ),
          EditorActions(
            saveKey: const Key('goal-save'),
            onSave: _save,
            saving: _saving,
            deleteKey: const Key('goal-delete'),
            onDelete: _isNew ? null : _delete,
          ),
        ],
      ),
    );
  }
}

/// Сумма поля в копейках или `null`.
int? tryParseKopecks(String text) => parseMoneyField(text, 'Сумма').kopecks;

/// Одно слагаемое формулы: знак, вид и параметры (счета / заказчики).
class _TermEditor extends StatelessWidget {
  const _TermEditor({
    required this.index,
    required this.term,
    required this.data,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  final int index;
  final GoalTerm term;
  final FinanceData? data;
  final ValueChanged<GoalTerm> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final accounts = data?.accounts ?? const <Account>[];
    final clients = [
      for (final p in data?.work.people ?? const <WorkPerson>[])
        if (!p.archived) p,
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s2),
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: AppRadii.borderM,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                key: Key('goal-term-sign-$index'),
                borderRadius: AppRadii.borderFull,
                onTap: () => onChanged(term.copyWith(plus: !term.plus)),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: term.plus ? c.surfaceInverse : c.surface3,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    term.plus ? '+' : '−',
                    style: t.numL.copyWith(
                      color: term.plus ? c.textOnInverse : c.textPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(child: Text(term.kind.label, style: t.bodyStrong)),
              IconButton(
                key: Key('goal-term-remove-$index'),
                tooltip: 'Убрать слагаемое',
                onPressed: onRemove,
                icon: const Icon(LucideIcons.x, size: 18),
              ),
            ],
          ),
          if (term.kind == GoalTermKind.accounts) ...[
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: [
                for (final a in accounts)
                  FilterPill(
                    key: Key('goal-term-$index-account-${a.id}'),
                    label: a.name,
                    selected: term.accountIds.contains(a.id),
                    check: true,
                    onTap: () => onChanged(
                      term.copyWith(
                        accountIds: term.accountIds.contains(a.id)
                            ? [
                                for (final id in term.accountIds)
                                  if (id != a.id) id,
                              ]
                            : [...term.accountIds, a.id],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (term.kind == GoalTermKind.receivables) ...[
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: [
                FilterPill(
                  key: Key('goal-term-$index-clients-all'),
                  label: 'Все заказчики',
                  selected: term.clientIds == null,
                  onTap: () => onChanged(term.copyWith(clientIds: null)),
                ),
                for (final p in clients)
                  FilterPill(
                    key: Key('goal-term-$index-client-${p.id}'),
                    label: p.name,
                    selected: term.clientIds?.contains(p.id) ?? false,
                    check: true,
                    onTap: () {
                      final current = term.clientIds ?? const <String>[];
                      final next = current.contains(p.id)
                          ? [
                              for (final id in current)
                                if (id != p.id) id,
                            ]
                          : [...current, p.id];
                      // Пустой выбор — снова «все заказчики».
                      onChanged(
                        term.copyWith(clientIds: next.isEmpty ? null : next),
                      );
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
