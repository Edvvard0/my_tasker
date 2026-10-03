import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/debt_editor.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/debt_tiles.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';

/// «Долги» (02, 5.4.3, личные долги): две секции «Мне должны» и «Я должен» с
/// итогом открытых остатков, списком (остаток, статус, срок, просрочка) и
/// свёрнутыми закрытыми долгами. Тап по строке — карточка долга.
class DebtsScreen extends ConsumerWidget {
  const DebtsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(debtsOverviewProvider);
    final Widget body;
    if (overview.hasError && !overview.hasValue) {
      body = const SingleChildScrollView(child: FinanceErrorNotice());
    } else if (!overview.hasValue) {
      body = const SingleChildScrollView(child: ListSkeleton(rows: 4));
    } else if (overview.requireValue.isEmpty) {
      body = EmptyState(
        key: const Key('debts-empty'),
        icon: LucideIcons.handCoins,
        title: 'Никто ничего не должен',
        message:
            'Когда появится личный долг — он будет здесь. Запиши, кто и '
            'сколько должен тебе или ты.',
        action: FilledButton(
          key: const Key('debts-empty-add'),
          onPressed: () => unawaited(showDebtEditor(context)),
          child: const Text('Добавить долг'),
        ),
      );
    } else {
      body = _DebtsBody(
        overview: overview.requireValue,
        today: ref.watch(moscowTodayProvider),
      );
    }
    return ScreenScaffold(
      title: 'Долги',
      parentLabel: 'Финансы',
      onBack: () => context.go('/finance'),
      scrollable: false,
      actions: [
        IconButton(
          key: const Key('debts-add'),
          tooltip: 'Новый долг',
          onPressed: () => unawaited(showDebtEditor(context)),
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

class _DebtsBody extends StatelessWidget {
  const _DebtsBody({required this.overview, required this.today});

  final DebtsOverview overview;
  final String today;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom + AppSpacing.s6;
    final sections = [
      _DebtSection(
        direction: DebtDirection.owedToMe,
        overview: overview,
        today: today,
      ),
      _DebtSection(
        direction: DebtDirection.iOwe,
        overview: overview,
        today: today,
      ),
    ];
    if (context.windowClass.isCompact) {
      return ListView(
        key: const Key('debts-list'),
        padding: EdgeInsets.only(bottom: bottom),
        children: [
          sections[0],
          const SizedBox(height: AppSpacing.s3),
          sections[1],
        ],
      );
    }
    return SingleChildScrollView(
      key: const Key('debts-list'),
      padding: EdgeInsets.only(bottom: bottom),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: sections[0]),
          const SizedBox(width: AppSpacing.s4),
          Expanded(child: sections[1]),
        ],
      ),
    );
  }
}

/// Одна секция направления: заголовок с итогом, открытые долги, закрытые
/// под раскрывашкой.
class _DebtSection extends StatefulWidget {
  const _DebtSection({
    required this.direction,
    required this.overview,
    required this.today,
  });

  final DebtDirection direction;
  final DebtsOverview overview;
  final String today;

  @override
  State<_DebtSection> createState() => _DebtSectionState();
}

class _DebtSectionState extends State<_DebtSection> {
  bool _showClosed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final direction = widget.direction;
    final name = direction.wire;
    final owed = direction == DebtDirection.owedToMe;
    final open = widget.overview.of(direction, closed: false);
    final closed = widget.overview.of(direction, closed: true);
    final total = owed ? widget.overview.owedToMe : widget.overview.iOwe;
    Widget tile(DebtState s) => DebtTile(
      state: s,
      today: widget.today,
      onTap: () => context.go('/finance/debts/${s.debt.id}'),
    );
    return AppCard(
      key: Key('debts-section-$name'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.s2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    direction.label.toUpperCase(),
                    style: t.overline.copyWith(color: c.textTertiary),
                  ),
                ),
                Text(
                  moneyText(total),
                  key: Key('debts-total-$name'),
                  style: t.numL.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: AppSpacing.s2),
              ],
            ),
          ),
          if (open.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s2),
              child: Text(
                owed ? 'Тебе никто не должен.' : 'Ты никому не должен.',
                key: Key('debts-none-$name'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            )
          else
            for (final s in open) tile(s),
          if (closed.isNotEmpty) ...[
            InkWell(
              key: Key('debts-closed-toggle-$name'),
              onTap: () => setState(() => _showClosed = !_showClosed),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s2),
                child: Row(
                  children: [
                    Icon(
                      _showClosed
                          ? LucideIcons.chevronDown
                          : LucideIcons.chevronRight,
                      size: 14,
                      color: c.textTertiary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'ЗАКРЫТЫЕ · ${closed.length}',
                      style: t.overline.copyWith(color: c.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
            if (_showClosed)
              for (final s in closed) tile(s),
          ],
        ],
      ),
    );
  }
}
