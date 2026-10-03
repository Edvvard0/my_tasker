import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';

/// Круг 40 с иконкой слева в строках (02, 4.10).
class LeadingIcon extends StatelessWidget {
  const LeadingIcon(this.icon, {this.color, super.key});

  final IconData icon;

  /// Цвет категории (необязательный акцент на иконке).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: c.surface3, shape: BoxShape.circle),
      child: Icon(icon, size: 20, color: color ?? c.textSecondary),
    );
  }
}

/// Строка счёта: иконка вида, название, «банк · •• 1234» и баланс справа.
class AccountTile extends StatelessWidget {
  const AccountTile({
    required this.account,
    required this.balance,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  final Account account;
  final int balance;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Semantics(
      button: onTap != null,
      label:
          '${account.name}, ${accountSubtitle(account)}, '
          '${moneyText(balance)}',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: AppRadii.borderM,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s2,
            vertical: AppSpacing.s2,
          ),
          decoration: BoxDecoration(
            color: selected ? c.surface3 : Colors.transparent,
            borderRadius: AppRadii.borderM,
          ),
          child: Row(
            children: [
              LeadingIcon(accountKindIcon(account.kind)),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyStrong,
                    ),
                    Text(
                      accountSubtitle(account),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    moneyText(balance),
                    key: Key('account-balance-${account.id}'),
                    style: t.numM.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (!account.includeInTotal)
                    Text(
                      'вне общего',
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

/// Строка операции: иконка категории (или вида), заголовок, подпись и сумма
/// справа с табличными цифрами. Доход — со знаком «+», расход — «−».
class TransactionTile extends StatelessWidget {
  const TransactionTile({
    required this.transaction,
    required this.lookups,
    required this.when,
    required this.onTap,
    this.menu,
    this.showAccount = true,
    super.key,
  });

  final FinanceTransaction transaction;
  final FinanceLookups lookups;

  /// Готовая подпись момента («Сегодня, 14:02»).
  final String when;
  final VoidCallback onTap;

  /// Показывать название счёта в подписи (на экране самого счёта — нет).
  final bool showAccount;

  /// Меню действий справа (десктоп: наведение/клик; на телефоне — свайп).
  final Widget? menu;

  String get _title {
    final t = transaction;
    final merchant = t.merchant;
    if (merchant != null && merchant.isNotEmpty) return merchant;
    if (t.isTransfer) return 'Перевод';
    if (t.debtId != null) return 'Долг';
    return lookups.category(t.categoryId)?.name ?? t.kind.label;
  }

  String get _subtitle {
    final t = transaction;
    final parts = <String>[];
    if (t.isTransfer) {
      parts.add(
        '${lookups.accountName(t.accountId)} → '
        '${lookups.accountName(t.toAccountId)}',
      );
    } else {
      final category = lookups.category(t.categoryId);
      final merchant = t.merchant;
      if (category != null && merchant != null && merchant.isNotEmpty) {
        parts.add(category.name);
      }
      if (t.debtId != null && merchant != null && merchant.isNotEmpty) {
        parts.add('Долг');
      }
      if (showAccount) parts.add(lookups.accountName(t.accountId));
    }
    parts.add(when);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final tx = transaction;
    final category = lookups.category(tx.categoryId);
    return Semantics(
      button: true,
      label: '$_title, ${transactionAmountText(tx)}, $_subtitle',
      excludeSemantics: true,
      child: InkWell(
        key: Key('tx-row-${tx.id}'),
        borderRadius: AppRadii.borderM,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
          child: Row(
            children: [
              LeadingIcon(
                tx.isTransfer
                    ? LucideIcons.arrowRightLeft
                    : category == null
                    ? transactionKindIcon(tx.kind)
                    : categoryIcon(category.icon),
                color: parseHexColor(category?.color),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyStrong,
                    ),
                    Text(
                      _subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(
                transactionAmountText(tx),
                style: t.numM.copyWith(
                  fontWeight: FontWeight.w600,
                  color: tx.isTransfer ? c.textSecondary : c.textPrimary,
                ),
              ),
              ?menu,
            ],
          ),
        ),
      ),
    );
  }
}
