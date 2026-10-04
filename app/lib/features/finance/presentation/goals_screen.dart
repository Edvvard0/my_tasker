import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/finance/presentation/goal_editor.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';

/// «Цели»: «Есть» считается по настраиваемой формуле, «Не хватает» —
/// цель минус «Есть» (отрицательное — «цель достигнута, +X»).
class GoalsScreen extends ConsumerStatefulWidget {
  const GoalsScreen({super.key});

  @override
  ConsumerState<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends ConsumerState<GoalsScreen> {
  bool _archive = false;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      key: const Key('goals-screen'),
      title: 'Цели',
      parentLabel: 'Финансы',
      onBack: () => financeBack(context),
      actions: [
        IconButton(
          key: const Key('goals-add'),
          tooltip: 'Новая цель',
          onPressed: () => showGoalEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: FinanceBuilder(
        builder: (context, data) {
          final goals = [
            for (final g in data.goals)
              if (g.archived == _archive) g,
          ];
          final archived = data.goals.where((g) => g.archived).length;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (archived > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                  child: ChipRow(
                    children: [
                      FilterPill(
                        key: const Key('goals-filter-open'),
                        label: 'Текущие',
                        selected: !_archive,
                        onTap: () => setState(() => _archive = false),
                      ),
                      FilterPill(
                        key: const Key('goals-filter-archive'),
                        label: 'Архив · $archived',
                        selected: _archive,
                        onTap: () => setState(() => _archive = true),
                      ),
                    ],
                  ),
                ),
              if (goals.isEmpty)
                EmptyState(
                  key: const Key('goals-empty'),
                  icon: LucideIcons.target,
                  title: _archive ? 'Архив пуст' : 'Целей пока нет',
                  message: _archive
                      ? 'Сюда попадают завершённые цели.'
                      : 'Задайте цель и формулу «Есть»: по умолчанию в неё '
                            'входят все счета, долги вам и ожидаемые '
                            'поступления из «Работы».',
                  action: _archive
                      ? null
                      : FilledButton(
                          key: const Key('goals-empty-add'),
                          onPressed: () => showGoalEditor(context),
                          child: const Text('Добавить цель'),
                        ),
                )
              else
                for (final g in goals) ...[
                  GoalCard(data: data, goal: g, detailed: true),
                  const SizedBox(height: AppSpacing.s2),
                ],
            ],
          );
        },
      ),
    );
  }
}

/// Карточка цели: «Есть … из …», полоса прогресса, крупное «Не хватает» (или
/// «Цель достигнута +X»), процент, срок и разбор формулы.
class GoalCard extends ConsumerWidget {
  const GoalCard({
    required this.data,
    required this.goal,
    this.detailed = false,
    super.key,
  });

  final FinanceData data;
  final Goal goal;

  /// Показывать разбор слагаемых формулы.
  final bool detailed;

  String _termLabel(GoalTerm term) {
    switch (term.kind) {
      case GoalTermKind.accounts:
        final names = [for (final id in term.accountIds) data.accountName(id)];
        return names.isEmpty ? 'Счета' : 'Счета: ${names.join(', ')}';
      case GoalTermKind.receivables:
        final ids = term.clientIds;
        if (ids == null) return term.kind.label;
        final names = [
          for (final id in ids) data.work.personById[id]?.name ?? 'заказчик',
        ];
        return '${term.kind.label}: ${names.join(', ')}';
      case GoalTermKind.allAccounts ||
          GoalTermKind.debtsToMe ||
          GoalTermKind.myDebts:
        return term.kind.label;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final format = ref.watch(amountFormatProvider);
    final p = data.progressOf(goal);
    final headline = p.reached
        ? 'Цель достигнута ${format.signed(p.surplus)}'
        : 'Не хватает ${format.full(p.missing)}';
    return InkWell(
      key: Key('goal-${goal.id}'),
      borderRadius: AppRadii.borderL,
      onTap: () => showGoalEditor(context, goalId: goal.id),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.target, size: 16, color: c.textSecondary),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(
                    goal.name.toUpperCase(),
                    style: t.overline.copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(format.full(goal.targetAmount), style: t.numM),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            GoalBar(basisPoints: p.progressBp),
            const SizedBox(height: AppSpacing.s2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Есть ${format.full(p.have)} из ${format.full(p.target)}',
                    key: Key('goal-have-${goal.id}'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                ),
                Text(
                  formatPercentBp(p.progressBp),
                  key: Key('goal-percent-${goal.id}'),
                  style: t.caption.copyWith(color: c.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(headline, key: Key('goal-missing-${goal.id}'), style: t.h2),
            if (goal.deadlineDate != null)
              Text(
                'Срок ${formatDateText(goal.deadlineDate, data.now)}',
                style: t.caption.copyWith(color: c.textSecondary),
              ),
            if (detailed) ...[
              const SizedBox(height: AppSpacing.s3),
              for (var i = 0; i < goal.formula.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    key: Key('goal-term-${goal.id}-$i'),
                    children: [
                      SizedBox(
                        width: 16,
                        child: Text(
                          goal.formula[i].plus ? '+' : '−',
                          style: t.numM.copyWith(color: c.textSecondary),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          _termLabel(goal.formula[i]),
                          style: t.bodyS.copyWith(color: c.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (i < p.terms.length)
                        Text(
                          format.full(p.terms[i].value.abs()),
                          style: t.numS.copyWith(color: c.textSecondary),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
