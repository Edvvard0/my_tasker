import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/finance_money.dart';
import 'package:my_tasker/features/finance/presentation/goal_actions.dart';
import 'package:my_tasker/features/finance/presentation/goal_editor.dart';
import 'package:my_tasker/features/finance/presentation/goal_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';
import 'package:my_tasker/features/finance/presentation/widgets/goal_tiles.dart';

/// «Цель»: «Есть» и «Не хватает» крупно, полоса прогресса, срок и таблица
/// разбора слагаемых формулы. Правка — карандаш, архив и удаление — меню.
class GoalScreen extends ConsumerWidget {
  const GoalScreen({required this.goalId, super.key});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(goalDetailProvider(goalId));
    final goal = detail.value?.goal;
    final Widget body;
    if (detail.hasError && !detail.hasValue) {
      body = const SingleChildScrollView(child: FinanceErrorNotice());
    } else if (!detail.hasValue) {
      body = const SingleChildScrollView(child: ListSkeleton());
    } else if (detail.requireValue == null) {
      body = EmptyState(
        key: const Key('goal-not-found'),
        icon: LucideIcons.target,
        title: 'Цель не найдена',
        message: 'Возможно, её удалили на другом устройстве.',
        action: ElevatedButton(
          onPressed: () => context.go('/finance/goals'),
          child: const Text('К целям'),
        ),
      );
    } else {
      body = _GoalBody(state: detail.requireValue!);
    }
    return ScreenScaffold(
      title: goal?.name ?? 'Цель',
      parentLabel: 'Цели',
      onBack: () => context.go('/finance/goals'),
      scrollable: false,
      actions: [
        if (goal != null)
          IconButton(
            key: const Key('goal-edit'),
            tooltip: 'Изменить цель',
            onPressed: () =>
                unawaited(showGoalEditor(context, goalId: goal.id)),
            icon: const Icon(LucideIcons.pencil, size: 22),
          ),
        if (goal != null) _GoalMenu(goal: goal),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FinanceOfflineNotice(),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalMenu extends ConsumerWidget {
  const _GoalMenu({required this.goal});

  final Goal goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
    key: const Key('goal-menu'),
    tooltip: 'Ещё',
    color: context.colors.surface2,
    icon: const Icon(LucideIcons.ellipsis, size: 22),
    onSelected: (action) async {
      if (action == 'archive') {
        await archiveGoalWithToast(
          context,
          ref,
          goal,
          archived: !goal.archived,
        );
      } else if (action == 'delete' &&
          await deleteGoalWithConfirm(context, ref, goal) &&
          context.mounted) {
        context.go('/finance/goals');
      }
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        key: const Key('goal-menu-archive'),
        value: 'archive',
        child: Text(goal.archived ? 'Вернуть из архива' : 'В архив'),
      ),
      const PopupMenuItem(
        key: Key('goal-menu-delete'),
        value: 'delete',
        child: Text('Удалить'),
      ),
    ],
  );
}

class _GoalBody extends ConsumerWidget {
  const _GoalBody({required this.state});

  final GoalState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final goal = state.goal;
    final p = state.progress;
    final today = ref.watch(moscowTodayProvider);
    final lookups = ref.watch(financeLookupsProvider).value;
    final workConnected = ref.watch(workDataProvider).connected;
    final deadline = goalDeadlineText(goal, today, reached: p.reached);
    final bottom = MediaQuery.paddingOf(context).bottom + AppSpacing.s6;
    return ListView(
      key: const Key('goal-scroll'),
      padding: EdgeInsets.only(bottom: bottom),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.target, size: 18, color: c.textSecondary),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      'Цель ${context.money(goal.targetAmount)}',
                      key: const Key('goal-target-line'),
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ),
                  if (goal.archived)
                    const StatusPill(
                      key: Key('goal-archived-pill'),
                      label: 'В архиве',
                      tone: StatusTone.neutral,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              Text('ЕСТЬ', style: t.overline.copyWith(color: c.textTertiary)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  context.money(p.have),
                  key: const Key('goal-have'),
                  style: t.display,
                ),
              ),
              const SizedBox(height: AppSpacing.s2),
              Text(
                '${p.percentText} % от ${context.money(goal.targetAmount)}',
                key: const Key('goal-percent'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s2),
              GoalProgressBar(progress: p),
              const SizedBox(height: AppSpacing.s4),
              Text(
                p.reached ? 'ЦЕЛЬ' : 'НЕ ХВАТАЕТ',
                style: t.overline.copyWith(color: c.textTertiary),
              ),
              Text(
                p.reached
                    ? goalMissingText(p, money: context.money)
                    : context.money(p.missing),
                key: const Key('goal-missing'),
                style: t.numL.copyWith(fontWeight: FontWeight.w700),
              ),
              if (deadline != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s3),
                  child: Text(
                    deadline,
                    key: const Key('goal-deadline'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                ),
              if (goal.hasReceivables)
                const ReceivablesNote(top: AppSpacing.s4),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        AppCard(
          key: const Key('goal-terms'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.s2),
                child: Text(
                  'ИЗ ЧЕГО СКЛАДЫВАЕТСЯ «ЕСТЬ»',
                  style: t.overline.copyWith(color: c.textTertiary),
                ),
              ),
              const SizedBox(height: AppSpacing.s1),
              for (var i = 0; i < p.terms.length; i++)
                _TermLine(
                  index: i,
                  value: p.terms[i],
                  lookups: lookups,
                  workConnected: workConnected,
                ),
              Divider(color: c.borderSubtle),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s2,
                  vertical: AppSpacing.s2,
                ),
                child: Row(
                  children: [
                    Expanded(child: Text('Есть', style: t.bodyStrong)),
                    Text(
                      context.money(p.have),
                      key: const Key('goal-terms-total'),
                      style: t.numM.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Строка таблицы разбора: знак, подпись слагаемого, значение со знаком.
class _TermLine extends StatelessWidget {
  const _TermLine({
    required this.index,
    required this.value,
    required this.lookups,
    required this.workConnected,
  });

  final int index;
  final GoalTermValue value;
  final FinanceLookups? lookups;
  final bool workConnected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final term = value.term;
    final unavailable = term.kind == GoalTermKind.receivables && !workConnected;
    return Container(
      key: Key('goal-term-$index'),
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: AppSpacing.s2,
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surface3,
              shape: BoxShape.circle,
            ),
            child: Text(
              term.sign.label,
              style: t.bodyStrong.copyWith(color: c.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(goalTermLabel(term, lookups), style: t.body),
                if (unavailable)
                  Text(
                    'Раздел «Работа» не подключён',
                    style: t.caption.copyWith(color: c.textTertiary),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          Text(
            context.money(value.value, signed: true),
            key: Key('goal-term-value-$index'),
            style: t.numM.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
