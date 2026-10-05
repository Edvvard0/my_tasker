import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';

/// Корзина: удалённые не более 30 суток назад строки всех синхронизируемых
/// таблиц (только «корневые»: потомки удалённого родителя скрыты).
final StreamProvider<List<TrashItem>> trashProvider =
    StreamProvider.autoDispose<List<TrashItem>>(
      (ref) => ref.watch(syncStoreProvider).watchTrash(),
    );

/// Таблицы раздела «Финансы»: пока раздел закрыт замком, их заголовки в
/// корзине скрыты (имя счёта, контрагент долга, название цели).
const Set<String> financeTrashTables = {
  FinanceRepository.accountsTable,
  FinanceRepository.categoriesTable,
  FinanceRepository.transactionsTable,
  FinanceRepository.checkpointsTable,
  FinanceRepository.debtsTable,
  FinanceRepository.repaymentsTable,
  FinanceRepository.goalsTable,
};

/// Заголовок записи финансовой таблицы вместо скрытого.
const String hiddenFinanceTitle = 'Запись раздела «Финансы»';

/// «Настройки › Корзина»: список с «удалится через N дней» и «Восстановить».
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    TrashItem item,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final lock = ref.read(financeLockProvider);
    final hidden =
        (!lock.loaded || lock.locked) &&
        financeTrashTables.contains(item.table);
    await ref.read(syncStoreProvider).restore(item.table, item.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '«${hidden ? hiddenFinanceTitle : item.title}» восстановлено',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trash = ref.watch(trashProvider);
    final offline =
        ref.watch(syncStatusProvider).indicator == SyncIndicatorKind.offline;
    final now = ref.watch(clockProvider)();
    final lock = ref.watch(financeLockProvider);
    final financeHidden = !lock.loaded || lock.locked;
    final t = context.text;
    final c = context.colors;

    final Widget body;
    if (trash.isLoading && !trash.hasValue) {
      body = const ListSkeleton();
    } else if (trash.hasError && !trash.hasValue) {
      body = NoticeCard(
        key: const Key('trash-error'),
        label: 'Не загрузилось',
        tone: StatusTone.danger,
        text: 'Не удалось прочитать корзину на устройстве.',
        actions: [
          FilledButton(
            key: const Key('trash-retry'),
            onPressed: () => ref.invalidate(trashProvider),
            child: const Text('Повторить'),
          ),
        ],
      );
    } else if (trash.requireValue.isEmpty) {
      body = const EmptyState(
        icon: LucideIcons.trash2,
        title: 'Корзина пуста',
        message:
            'Удалённое хранится здесь 30 дней, потом исчезает навсегда. '
            'Пока можно вернуть любую запись.',
      );
    } else {
      body = Column(
        key: const Key('trash-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            child: Text(
              'Удалённое хранится 30 дней.',
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
          for (final item in trash.requireValue) ...[
            _TrashTile(
              item: item,
              now: now,
              hideTitle:
                  financeHidden && financeTrashTables.contains(item.table),
              onRestore: () => _restore(context, ref, item),
            ),
            const SizedBox(height: AppSpacing.s2),
          ],
        ],
      );
    }

    return ScreenScaffold(
      title: 'Корзина',
      parentLabel: 'Настройки',
      onBack: () => context.go('/settings'),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (offline) ...[
                const NoticeCard(
                  key: Key('trash-offline'),
                  label: 'Офлайн',
                  tone: StatusTone.neutral,
                  text:
                      'Восстановление сохранится на устройстве и отправится, '
                      'когда появится сеть.',
                ),
                const SizedBox(height: AppSpacing.s3),
              ],
              body,
            ],
          ),
        ),
      ),
    );
  }
}

class _TrashTile extends StatelessWidget {
  const _TrashTile({
    required this.item,
    required this.now,
    required this.onRestore,
    this.hideTitle = false,
  });

  final TrashItem item;
  final DateTime now;
  final bool hideTitle;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return AppCard(
      key: Key('trash-${item.table}-${item.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.surface3,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  LucideIcons.trash2,
                  size: 20,
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hideTitle ? hiddenFinanceTitle : item.title,
                      key: hideTitle ? Key('trash-hidden-${item.id}') : null,
                      style: t.bodyStrong,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${item.label} · удалено '
                      '${formatMoment(item.deletedAt, now)}',
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Expanded(
                child: Text(
                  formatDaysLeft(item.daysLeft),
                  key: Key('trash-left-${item.id}'),
                  style: t.caption.copyWith(color: c.textTertiary),
                ),
              ),
              ElevatedButton(
                key: Key('restore-${item.id}'),
                onPressed: onRestore,
                child: const Text('Восстановить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
