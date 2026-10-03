import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/domain/debt_views.dart';
import 'package:my_tasker/features/finance/presentation/debt_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';

/// Круг 40 с инициалом контрагента (02, 5.4.3: аватар-инициалы `surface/3`).
class DebtAvatar extends StatelessWidget {
  const DebtAvatar(this.initial, {super.key});

  final String initial;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.surface3, shape: BoxShape.circle),
      child: Text(
        initial,
        style: context.text.bodyStrong.copyWith(color: c.textSecondary),
      ),
    );
  }
}

/// Строка долга: инициал, имя, «срок / вернули», остаток справа и статус.
/// Просрочка — словом и иконкой «часы», без красного (02, 2.2).
class DebtTile extends StatelessWidget {
  const DebtTile({
    required this.state,
    required this.today,
    required this.onTap,
    super.key,
  });

  final DebtState state;
  final String today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final debt = state.debt;
    final amount = state.isClosed ? debt.amount : state.remaining;
    final subtitle = debtSubtitle(state, today);
    return Semantics(
      button: true,
      label:
          '${debt.who}, ${debt.direction.label}, ${moneyText(amount)}, '
          '$subtitle${state.overdue ? ', просрочен' : ''}',
      excludeSemantics: true,
      child: InkWell(
        key: Key('debt-row-${debt.id}'),
        borderRadius: AppRadii.borderM,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
          child: Row(
            children: [
              DebtAvatar(debtInitial(debt)),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      debt.who,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyStrong,
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                    if (state.overdue)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          key: Key('debt-overdue-${debt.id}'),
                          children: [
                            Icon(
                              LucideIcons.clock,
                              size: 14,
                              color: c.textPrimary,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                overdueText(state.overdueDays),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodyS.copyWith(
                                  color: c.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    moneyText(amount),
                    key: Key('debt-amount-${debt.id}'),
                    style: t.numM.copyWith(
                      fontWeight: FontWeight.w600,
                      color: state.isClosed ? c.textSecondary : c.textPrimary,
                    ),
                  ),
                  Text(
                    state.status.label,
                    key: Key('debt-status-${debt.id}'),
                    style: t.caption.copyWith(color: c.textTertiary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Полоса «возвращено» (02, прогресс-бар): заполнено — синий акцент, доля
/// обрезается на 100 %.
class DebtProgressBar extends StatelessWidget {
  const DebtProgressBar({required this.state, super.key});

  final DebtState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final amount = state.debt.amount;
    final fraction = amount <= 0
        ? 0.0
        : (state.repaid / amount).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: AppRadii.borderFull,
      child: SizedBox(
        width: double.infinity,
        height: 12,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: c.borderStrong)),
            FractionallySizedBox(
              widthFactor: fraction,
              child: ColoredBox(
                key: const Key('debt-progress-fill'),
                color: c.accent,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
