import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/goal_format.dart';

/// Полоса прогресса цели (02, 5.3.2): 12 px, радиус full; заполнено — синий
/// акцент, доля обрезается на 100 %.
class GoalProgressBar extends StatelessWidget {
  const GoalProgressBar({required this.progress, super.key});

  final GoalProgress progress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: 'Прогресс цели ${progress.percentText} процентов',
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: AppRadii.borderFull,
        child: SizedBox(
          width: double.infinity,
          height: 12,
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: c.borderStrong)),
              FractionallySizedBox(
                widthFactor: progress.barFraction,
                child: ColoredBox(
                  key: const Key('goal-progress-fill'),
                  color: c.accent,
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Честная пометка о слагаемом «ожидаемые поступления»: пока клиента
/// «Работы» нет, оно считается как 0 (формула при этом не меняется).
///
/// Показывается, только пока данные Работы заглушка (`WorkData.connected`
/// ложно); отступ сверху [top] входит в виджет, чтобы без пометки не
/// оставалось пустого места.
class ReceivablesNote extends ConsumerWidget {
  const ReceivablesNote({super.key, this.compact = false, this.top = 0});

  /// В списке целей — мелкая подпись без рамки.
  final bool compact;
  final double top;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(workDataProvider).connected) return const SizedBox.shrink();
    final c = context.colors;
    final t = context.text;
    final text = Text(
      goalReceivablesNote,
      style: (compact ? t.caption : t.bodyS).copyWith(
        color: compact ? c.textTertiary : c.textSecondary,
      ),
    );
    final icon = Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Icon(
        LucideIcons.info,
        size: compact ? 14 : 16,
        color: c.textTertiary,
      ),
    );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        icon,
        const SizedBox(width: AppSpacing.s2),
        Expanded(child: text),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: compact
          ? row
          : Container(
              key: const Key('goal-receivables-note'),
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: c.surface3,
                borderRadius: AppRadii.borderM,
              ),
              child: row,
            ),
    );
  }
}

/// Карточка цели в списке: название, срок, процент, полоса, «Есть» и «Не
/// хватает» (либо «Цель достигнута, +X»).
class GoalTile extends StatelessWidget {
  const GoalTile({
    required this.state,
    required this.today,
    required this.onTap,
    super.key,
  });

  final GoalState state;
  final String today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final goal = state.goal;
    final p = state.progress;
    final deadline = goalDeadlineText(goal, today, reached: p.reached);
    return Semantics(
      button: true,
      label:
          '${goal.name}, ${p.percentText} процентов, '
          '${goalMissingText(p)}',
      excludeSemantics: true,
      child: Material(
        color: c.surface1,
        borderRadius: AppRadii.borderL,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('goal-row-${goal.id}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        goal.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodyStrong,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Text(
                      '${p.percentText} %',
                      key: Key('goal-percent-${goal.id}'),
                      style: t.numM.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                if (deadline != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      deadline,
                      key: Key('goal-deadline-${goal.id}'),
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ),
                const SizedBox(height: AppSpacing.s3),
                GoalProgressBar(progress: p),
                const SizedBox(height: AppSpacing.s3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ЕСТЬ',
                          style: t.overline.copyWith(color: c.textTertiary),
                        ),
                        Text(
                          moneyText(p.have),
                          key: Key('goal-have-${goal.id}'),
                          style: t.numM.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            p.reached ? 'ЦЕЛЬ' : 'НЕ ХВАТАЕТ',
                            style: t.overline.copyWith(color: c.textTertiary),
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              p.reached
                                  ? goalMissingText(p)
                                  : moneyText(p.missing),
                              key: Key('goal-missing-${goal.id}'),
                              maxLines: 1,
                              style: t.numM.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (goal.hasReceivables)
                  const ReceivablesNote(compact: true, top: AppSpacing.s3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
