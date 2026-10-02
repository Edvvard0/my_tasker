import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';

/// Плашка «Офлайн» над содержимым экрана Финансов (02, 2.9.4): всё работает,
/// изменения лежат на устройстве. Без сети ничего не показывает «нет».
class FinanceOfflineNotice extends ConsumerWidget {
  const FinanceOfflineNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline =
        ref.watch(syncStatusProvider).indicator == SyncIndicatorKind.offline;
    if (!offline) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(bottom: AppSpacing.s3),
      child: NoticeCard(
        key: Key('finance-offline'),
        label: 'Офлайн',
        tone: StatusTone.neutral,
        text:
            'Всё сохраняется на устройстве и отправится, когда появится '
            'сеть.',
      ),
    );
  }
}

/// Ошибка чтения данных на устройстве: что случилось и что делать (02, 2.9.5).
class FinanceErrorNotice extends ConsumerWidget {
  const FinanceErrorNotice({this.text, super.key});

  final String? text;

  @override
  Widget build(BuildContext context, WidgetRef ref) => NoticeCard(
    key: const Key('finance-error'),
    label: 'Не загрузилось',
    tone: StatusTone.danger,
    text: text ?? 'Не удалось прочитать финансы на устройстве.',
    actions: [
      FilledButton(
        key: const Key('finance-retry'),
        onPressed: () => refreshFinance(ref),
        child: const Text('Повторить'),
      ),
    ],
  );
}
