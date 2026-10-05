import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/banks/application/bank_providers.dart';
import 'package:my_tasker/features/banks/data/bank_pipeline.dart';
import 'package:my_tasker/features/banks/data/notification_store.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/domain/notification_guess.dart';
import 'package:my_tasker/features/banks/presentation/banks_widgets.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';

/// «Требует проверки»: уведомления банков, которые приложение не смогло
/// превратить в операцию. Два случая: разобрано, но счёт не найден (выбрать
/// счёт), и не разобрано совсем (исходный текст; можно создать операцию
/// вручную). Сырой текст хранится только на устройстве, 30 дней.
class NeedsReviewScreen extends ConsumerWidget {
  const NeedsReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('needs-review-screen'),
      title: 'Требует проверки',
      parentLabel: 'Банки',
      onBack: () => financeBack(context),
      child: const _Body(),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsAccount = ref.watch(needsAccountNotificationsProvider);
    final unrecognized = ref.watch(unrecognizedNotificationsProvider);
    final rules = ref.watch(bankDataProvider).value?.notifications;
    if (needsAccount.isLoading || unrecognized.isLoading || rules == null) {
      return const ListSkeleton();
    }
    final accountItems = needsAccount.value ?? const <BankNotification>[];
    final unrecognizedItems = unrecognized.value ?? const <BankNotification>[];
    if (accountItems.isEmpty && unrecognizedItems.isEmpty) {
      return const EmptyState(
        key: Key('review-empty'),
        icon: LucideIcons.circleCheck,
        title: 'Всё разобрано',
        message:
            'Здесь появятся уведомления банков, которые не удалось '
            'превратить в операцию: нет подходящего счёта или формат '
            'уведомления неизвестен.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (accountItems.isNotEmpty) ...[
          const FinanceSection(title: 'Нужен счёт'),
          for (final n in accountItems) ...[
            _NeedsAccountCard(notification: n, rules: rules),
            const SizedBox(height: AppSpacing.s2),
          ],
        ],
        if (unrecognizedItems.isNotEmpty) ...[
          const FinanceSection(title: 'Не распознано'),
          for (final n in unrecognizedItems) ...[
            _UnrecognizedCard(notification: n, rules: rules),
            const SizedBox(height: AppSpacing.s2),
          ],
        ],
      ],
    );
  }
}

class _OriginalText extends ConsumerWidget {
  const _OriginalText({required this.notification, required this.rules});

  final BankNotification notification;
  final NotificationRules rules;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final now = ref.watch(clockProvider)();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${bankNameOfPackage(rules, notification.package)} · '
          '${momentText(notification.postedAt, now)}',
          style: t.caption.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s1),
        if (notification.title.isNotEmpty)
          Text(notification.title, style: t.bodyStrong),
        Text(notification.body, style: t.bodyS),
      ],
    );
  }
}

class _NeedsAccountCard extends ConsumerWidget {
  const _NeedsAccountCard({required this.notification, required this.rules});

  final BankNotification notification;
  final NotificationRules rules;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parsed = notification.parsed;
    return AppCard(
      key: Key('review-account-${notification.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusPill(
            label: reviewReasonLabel(notification.reason),
            tone: StatusTone.warning,
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            reviewReasonText(notification.reason),
            key: Key('review-reason-${notification.id}'),
            style: context.text.caption.copyWith(
              color: context.colors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s1),
          if (parsed != null)
            Text(
              '${parsed.kind == 'income' ? 'Доход' : 'Расход'} '
              '${formatAmount(parsed.amount ?? 0)}'
              '${parsed.merchant == null ? '' : ' · ${parsed.merchant}'}'
              '${parsed.cardLast4 == null ? '' : ' · карта •••• ${parsed.cardLast4}'}',
              style: context.text.bodyStrong,
            ),
          const SizedBox(height: AppSpacing.s1),
          _OriginalText(notification: notification, rules: rules),
          const SizedBox(height: AppSpacing.s3),
          Text(
            'На какой счёт записать?',
            style: context.text.caption.copyWith(
              color: context.colors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s1),
          FinanceBuilder(
            builder: (context, data) => AccountChips(
              accounts: data.activeAccounts,
              selectedId: null,
              keyPrefix: 'review-pick-${notification.id}',
              onSelect: (id) {
                if (id == null) return;
                unawaited(
                  ref
                      .read(bankPipelineProvider)
                      .assignAccount(notification, id),
                );
              },
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: Key('review-dismiss-${notification.id}'),
              onPressed: () => unawaited(
                ref
                    .read(notificationStoreProvider)
                    .markDismissed(notification.id),
              ),
              child: const Text('Убрать'),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnrecognizedCard extends ConsumerWidget {
  const _UnrecognizedCard({required this.notification, required this.rules});

  final BankNotification notification;
  final NotificationRules rules;

  void _create(BuildContext context, WidgetRef ref) {
    final guess = guessFromNotification(notification.title, notification.body);
    final store = ref.read(notificationStoreProvider);
    unawaited(
      showTransactionEditor(
        context,
        kind: guess.isIncome ? TxKind.income : TxKind.expense,
        prefill: TransactionPrefill(
          amount: guess.amount,
          comment: 'Из уведомления: ${notification.body}',
          date: notification.postedAt,
        ),
        onSaved: (txId) =>
            unawaited(store.markProcessed(notification.id, txId: txId)),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      key: Key('review-unrecognized-${notification.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusPill(
            label: reviewReasonLabel(notification.reason),
            tone: StatusTone.warning,
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            reviewReasonText(notification.reason),
            key: Key('review-reason-${notification.id}'),
            style: context.text.caption.copyWith(
              color: context.colors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s1),
          _OriginalText(notification: notification, rules: rules),
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: AppSpacing.s2,
            children: [
              FilledButton(
                key: Key('review-create-${notification.id}'),
                onPressed: () => _create(context, ref),
                child: const Text('Создать операцию'),
              ),
              TextButton(
                key: Key('review-dismiss-${notification.id}'),
                onPressed: () => unawaited(
                  ref
                      .read(notificationStoreProvider)
                      .markDismissed(notification.id),
                ),
                child: const Text('Убрать'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
