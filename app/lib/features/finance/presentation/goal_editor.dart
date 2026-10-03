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
import 'package:my_tasker/features/finance/domain/goal_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/amount_field.dart';
import 'package:my_tasker/features/finance/presentation/widgets/formula_builder.dart';

/// Открывает редактор цели: [goalId] — правка, иначе создание с формулой по
/// умолчанию (spec 6.2).
Future<void> showGoalEditor(BuildContext context, {String? goalId}) =>
    showEditorSheet<void>(context, builder: (_) => GoalEditor(goalId: goalId));

/// Редактор цели (02, 5.3.2): название, сумма, срок и конструктор формулы
/// «Есть». Формула проверяется как на сервере; слагаемое «ожидаемые
/// поступления» сохраняется и синхронизируется как есть.
class GoalEditor extends ConsumerStatefulWidget {
  const GoalEditor({this.goalId, super.key});

  final String? goalId;

  @override
  ConsumerState<GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends ConsumerState<GoalEditor> {
  final _name = TextEditingController();
  final _target = TextEditingController();

  Goal? _original;
  DateTime? _deadline;
  List<GoalTerm> _terms = defaultGoalFormula();
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

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
      _target.text = amountInputText(goal.targetAmount);
      _deadline = goal.deadlineDate == null
          ? null
          : parseDate(goal.deadlineDate!);
      _terms = [...goal.formula];
    });
  }

  DateTime _today() => parseDate(ref.read(moscowTodayProvider))!;

  Future<void> _save() async {
    if (_saving) return;
    final target = parseAmountField(_target.text);
    if (target == null || target < 1) {
      setState(() => _error = 'Введи сумму цели больше нуля');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final original = _original;
      final goal = Goal(
        id: original?.id ?? repo.newId(),
        name: _name.text,
        targetAmount: target,
        deadlineDate: _deadline == null ? null : formatDate(_deadline!),
        formula: _terms,
        archived: original?.archived ?? false,
      );
      if (original == null) {
        await repo.createGoal(goal);
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

  Widget _errorRow(String text) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        key: const Key('goal-error'),
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
    final title = _isNew ? 'Новая цель' : 'Цель';
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
              'Цель не найдена: возможно, её удалили на другом устройстве.',
              key: const Key('goal-editor-missing'),
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final accounts = ref.watch(accountsProvider).value ?? const [];
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
                      key: const Key('goal-name'),
                      controller: _name,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Например, отпуск',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Сумма цели',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AmountField(
                          key: const Key('goal-target'),
                          controller: _target,
                        ),
                        const SizedBox(height: AppSpacing.s2),
                        AmountChips(
                          controller: _target,
                          keyPrefix: 'goal-chip',
                        ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Срок',
                    child: DateChoiceRow(
                      keyPrefix: 'goal-deadline',
                      today: _today(),
                      value: _deadline,
                      allowNone: true,
                      noneLabel: 'Без срока',
                      onChanged: (d) => setState(() => _deadline = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Формула «Есть»',
                    child: FormulaBuilder(
                      terms: _terms,
                      accounts: accounts,
                      onChanged: (terms) => setState(() => _terms = terms),
                    ),
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
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const Key('goal-save'),
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
