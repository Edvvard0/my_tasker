import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';
import 'package:my_tasker/features/finance/presentation/goal_editor.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';
import 'package:my_tasker/features/finance/presentation/widgets/goal_tiles.dart';

/// «Цели» (02, 5.3.2): карточки целей с полосой прогресса, «Есть» и «Не
/// хватает» (либо «Цель достигнута, +X»), сроком; архивные — свёрнуты. Тап —
/// карточка цели.
class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(goalsOverviewProvider);
    final Widget body;
    if (overview.hasError && !overview.hasValue) {
      body = const SingleChildScrollView(child: FinanceErrorNotice());
    } else if (!overview.hasValue) {
      body = const SingleChildScrollView(child: ListSkeleton());
    } else if (overview.requireValue.isEmpty) {
      body = EmptyState(
        key: const Key('goals-empty'),
        icon: LucideIcons.target,
        title: 'Целей пока нет',
        message:
            'Поставь цель — например, накопить сумму к сроку. «Есть» '
            'посчитается из счетов и долгов, а «Не хватает» покажет, сколько '
            'осталось.',
        action: FilledButton(
          key: const Key('goals-empty-add'),
          onPressed: () => unawaited(showGoalEditor(context)),
          child: const Text('Добавить цель'),
        ),
      );
    } else {
      body = _GoalsBody(
        overview: overview.requireValue,
        today: ref.watch(moscowTodayProvider),
      );
    }
    return ScreenScaffold(
      title: 'Цели',
      parentLabel: 'Финансы',
      onBack: () => context.go('/finance'),
      scrollable: false,
      actions: [
        IconButton(
          key: const Key('goals-add'),
          tooltip: 'Новая цель',
          onPressed: () => unawaited(showGoalEditor(context)),
          icon: const Icon(LucideIcons.plus, size: 22),
        ),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
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

class _GoalsBody extends StatefulWidget {
  const _GoalsBody({required this.overview, required this.today});

  final GoalsOverview overview;
  final String today;

  @override
  State<_GoalsBody> createState() => _GoalsBodyState();
}

class _GoalsBodyState extends State<_GoalsBody> {
  bool _showArchived = false;

  Widget _tile(GoalState s) => GoalTile(
    state: s,
    today: widget.today,
    onTap: () => context.go('/finance/goals/${s.goal.id}'),
  );

  /// Карточки: на телефоне в столбик, на десктопе в две колонки.
  Widget _grid(List<GoalState> goals) {
    if (context.windowClass.isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in goals)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s3),
              child: _tile(s),
            ),
        ],
      );
    }
    // Две независимые колонки: карточки разной высоты не оставляют дыр.
    Widget column(int start) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = start; i < goals.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s4),
              child: _tile(goals[i]),
            ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        column(0),
        const SizedBox(width: AppSpacing.s4),
        column(1),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final active = widget.overview.active;
    final archived = widget.overview.archived;
    final bottom = MediaQuery.paddingOf(context).bottom + AppSpacing.s6;
    return ListView(
      key: const Key('goals-list'),
      padding: EdgeInsets.only(bottom: bottom),
      children: [
        if (active.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s2),
            child: Text(
              'Все цели в архиве.',
              key: const Key('goals-none-active'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          )
        else
          _grid(active),
        if (archived.isNotEmpty) ...[
          InkWell(
            key: const Key('goals-archive-toggle'),
            onTap: () => setState(() => _showArchived = !_showArchived),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s2),
              child: Row(
                children: [
                  Icon(
                    _showArchived
                        ? LucideIcons.chevronDown
                        : LucideIcons.chevronRight,
                    size: 14,
                    color: c.textTertiary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'АРХИВ · ${archived.length}',
                    style: t.overline.copyWith(color: c.textTertiary),
                  ),
                ],
              ),
            ),
          ),
          if (_showArchived) _grid(archived),
        ],
      ],
    );
  }
}
