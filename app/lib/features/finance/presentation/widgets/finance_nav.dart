import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';

/// Пункт навигации по разделу «Финансы».
class FinanceNavItem {
  const FinanceNavItem({
    required this.keyName,
    required this.label,
    required this.icon,
    required this.location,
    this.resetFilter = false,
  });

  /// Ключ виджета (`finance-open-<keyName>`).
  final String keyName;
  final String label;
  final IconData icon;
  final String location;

  /// Перед переходом сбросить фильтр ленты (операции открываются «с нуля»).
  final bool resetFilter;
}

/// Единый блок навигации «Операции · Долги · Цели · Аналитика · Категории»
/// (вместо иконок без подписей в шапке и карточках).
const List<FinanceNavItem> financeNavItems = [
  FinanceNavItem(
    keyName: 'transactions',
    label: 'Операции',
    icon: LucideIcons.receipt,
    location: '/finance/transactions',
    resetFilter: true,
  ),
  FinanceNavItem(
    keyName: 'debts',
    label: 'Долги',
    icon: LucideIcons.handCoins,
    location: '/finance/debts',
  ),
  FinanceNavItem(
    keyName: 'goals',
    label: 'Цели',
    icon: LucideIcons.target,
    location: '/finance/goals',
  ),
  FinanceNavItem(
    keyName: 'analytics',
    label: 'Аналитика',
    icon: LucideIcons.chartColumn,
    location: '/finance/analytics',
  ),
  FinanceNavItem(
    keyName: 'categories',
    label: 'Категории',
    icon: LucideIcons.tags,
    location: '/finance/categories',
  ),
];

void _open(BuildContext context, WidgetRef ref, FinanceNavItem item) {
  if (item.resetFilter) ref.read(transactionFilterProvider.notifier).reset();
  context.go(item.location);
}

/// Телефон: горизонтальная прокручиваемая лента подписанных плиток.
class FinanceNavStrip extends ConsumerWidget {
  const FinanceNavStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    return SingleChildScrollView(
      key: const Key('finance-nav'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, item) in financeNavItems.indexed) ...[
            if (i > 0) const SizedBox(width: AppSpacing.s2),
            Semantics(
              button: true,
              label: item.label,
              excludeSemantics: true,
              child: Material(
                color: c.surface1,
                borderRadius: AppRadii.borderM,
                child: InkWell(
                  key: Key('finance-open-${item.keyName}'),
                  borderRadius: AppRadii.borderM,
                  onTap: () => _open(context, ref, item),
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(item.icon, size: 20, color: c.textSecondary),
                        const SizedBox(width: AppSpacing.s2),
                        Text(item.label, style: t.label),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Десктоп: вертикальный список в левой панели под счетами.
class FinanceNavList extends ConsumerWidget {
  const FinanceNavList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    return Column(
      key: const Key('finance-nav'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: AppSpacing.s4, color: c.borderDefault),
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.s2,
            bottom: AppSpacing.s1,
          ),
          child: Text(
            'РАЗДЕЛЫ',
            style: t.overline.copyWith(color: c.textTertiary),
          ),
        ),
        for (final item in financeNavItems)
          InkWell(
            key: Key('finance-open-${item.keyName}'),
            borderRadius: AppRadii.borderS,
            onTap: () => _open(context, ref, item),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s2,
                vertical: AppSpacing.s3,
              ),
              child: Row(
                children: [
                  Icon(item.icon, size: 20, color: c.textSecondary),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(child: Text(item.label, style: t.body)),
                  Icon(
                    LucideIcons.chevronRight,
                    size: 16,
                    color: c.textTertiary,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
