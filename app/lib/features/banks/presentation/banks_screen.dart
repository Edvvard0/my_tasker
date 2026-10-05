import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/banks/application/bank_providers.dart';
import 'package:my_tasker/features/banks/application/setup_providers.dart';
import 'package:my_tasker/features/banks/platform/bank_platform.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show WorkLinkRow;

/// «Банки»: источники операций без банковского API — уведомления Android,
/// выписки и ручная сверка. Отсюда — черновики, «Требует проверки», импорт
/// выписки, сверка баланса и настройка доступа к уведомлениям.
class BanksScreen extends ConsumerWidget {
  const BanksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(bankPlatformProvider);
    final drafts =
        ref
            .watch(transactionsProvider)
            .value
            ?.where((t) => !t.isConfirmed)
            .length ??
        0;
    final review =
        (ref.watch(needsAccountNotificationsProvider).value?.length ?? 0) +
        (ref.watch(unrecognizedNotificationsProvider).value?.length ?? 0);
    final listener = platform.isSupported
        ? ref.watch(listenerEnabledProvider).value
        : null;
    return ScreenScaffold(
      key: const Key('banks-screen'),
      title: 'Банки',
      parentLabel: 'Финансы',
      onBack: () => financeBack(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!platform.isSupported)
            const NoticeCard(
              key: Key('banks-unsupported'),
              label: 'Только Android',
              tone: StatusTone.neutral,
              text:
                  'Уведомления банков читает только приложение на Android. '
                  'Здесь доступны импорт выписки, черновики и сверка баланса.',
            )
          else if (listener == false)
            NoticeCard(
              key: const Key('banks-needs-access'),
              label: 'Нужен доступ',
              tone: StatusTone.warning,
              text:
                  'Чтобы операции из уведомлений банков попадали в '
                  'черновики, выдайте доступ к уведомлениям и снимите '
                  'ограничения батареи.',
              actions: [
                FilledButton(
                  key: const Key('banks-open-setup'),
                  onPressed: () => context.push('/finance/banks/setup'),
                  child: const Text('Настроить'),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.s3),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                WorkLinkRow(
                  key: const Key('banks-link-drafts'),
                  icon: LucideIcons.clipboardCheck,
                  label: 'Черновики',
                  trailingText: drafts == 0 ? null : '$drafts',
                  onTap: () => context.push('/finance/banks/drafts'),
                ),
                WorkLinkRow(
                  key: const Key('banks-link-review'),
                  icon: LucideIcons.triangleAlert,
                  label: 'Требует проверки',
                  trailingText: review == 0 ? null : '$review',
                  onTap: () => context.push('/finance/banks/review'),
                ),
                WorkLinkRow(
                  key: const Key('banks-link-import'),
                  icon: LucideIcons.fileUp,
                  label: 'Импорт выписки',
                  onTap: () => context.push('/finance/banks/import'),
                ),
                WorkLinkRow(
                  key: const Key('banks-link-reconcile'),
                  icon: LucideIcons.scale,
                  label: 'Сверка с банком',
                  onTap: () => context.push('/finance/banks/reconcile'),
                ),
                WorkLinkRow(
                  key: const Key('banks-link-setup'),
                  icon: LucideIcons.bell,
                  label: 'Уведомления банков',
                  trailingText: platform.isSupported
                      ? (listener == true ? 'включены' : null)
                      : 'только Android',
                  onTap: () => context.push('/finance/banks/setup'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
