import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/sync/sync_providers_ui.dart';

/// Значение поля коротко и читаемо.
String describeValue(Object? value) {
  final text = value is String ? value : jsonEncode(value);
  return text.length > 80 ? '${text.substring(0, 79)}…' : text;
}

/// Что произошло, простым языком (spec 3.4, 3.9).
String describeConflict(SyncConflict c, String? field) => switch (c.kind) {
  ConflictKind.field =>
    'Поле «$field» изменили на двух устройствах. Осталась более поздняя '
        'правка.',
  ConflictKind.resurrected =>
    'Запись удалили на одном устройстве, а на другом изменили позже. '
        'Правка новее — запись осталась.',
  ConflictKind.editVsDelete =>
    'Запись меняли на одном устройстве и удалили на другом. Удаление '
        'новее: запись в корзине, правка сохранена.',
  ConflictKind.parentDeleted =>
    'Запись создали внутри удалённого объекта — она ушла в корзину вместе '
        'с ним.',
  ConflictKind.unknown => 'Правки на двух устройствах столкнулись.',
};

String _revertError(ApiException e) => switch (e.code) {
  'conflict_already_reverted' => 'Это значение уже возвращено',
  'row_not_found' => 'Записи больше нет на сервере',
  'not_revertable' => 'Для этого конфликта возврат не поддерживается',
  'revert_rejected' => 'Сервер не принял значение: оно больше не подходит',
  _ =>
    e.isNetwork
        ? 'Не удалось вернуть: нет соединения'
        : 'Не удалось вернуть значение',
};

/// «Журнал конфликтов»: что проиграло при автоматическом слиянии и кнопка
/// «Вернуть моё» (spec 3.9). Ручного выбора версии нет (04, 1.1).
class ConflictsScreen extends ConsumerWidget {
  const ConflictsScreen({super.key});

  Future<void> _revert(
    BuildContext context,
    WidgetRef ref,
    SyncConflict conflict,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(conflictsProvider.notifier).revert(conflict);
      messenger.showSnackBar(
        const SnackBar(content: Text('Вернули ваше значение')),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_revertError(e))));
      if (e.code == 'conflict_already_reverted' || e.code == 'row_not_found') {
        ref.invalidate(conflictsProvider);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(conflictsProvider);
    final Widget body;
    if (conflicts.isLoading && !conflicts.hasValue) {
      body = const ListSkeleton();
    } else if (conflicts.hasError && !conflicts.hasValue) {
      final error = conflicts.error;
      final offline = error is ApiException && error.isNetwork;
      body = NoticeCard(
        key: Key(offline ? 'conflicts-offline' : 'conflicts-error'),
        label: offline ? 'Офлайн' : 'Не загрузилось',
        tone: offline ? StatusTone.neutral : StatusTone.danger,
        text: offline
            ? 'Журнал конфликтов хранится на сервере, а связи с ним нет.'
            : 'Не удалось получить журнал конфликтов. Попробуй ещё раз.',
        actions: [
          FilledButton(
            key: const Key('conflicts-retry'),
            onPressed: () => ref.invalidate(conflictsProvider),
            child: const Text('Повторить'),
          ),
        ],
      );
    } else if (conflicts.requireValue.items.isEmpty) {
      body = const EmptyState(
        icon: LucideIcons.gitCompare,
        title: 'Конфликтов не было',
        message:
            'Когда одну запись изменят на двух устройствах, здесь '
            'появится, что осталось и что проиграло.',
      );
    } else {
      final state = conflicts.requireValue;
      body = Column(
        key: const Key('conflicts-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in state.items) ...[
            _ConflictTile(
              conflict: item,
              busy: state.revertingId == item.id,
              onRevert: () => _revert(context, ref, item),
            ),
            const SizedBox(height: AppSpacing.s2),
          ],
          if (state.nextBefore != null)
            Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton(
                key: const Key('conflicts-more'),
                onPressed: state.loadingMore
                    ? null
                    : () async {
                        try {
                          await ref.read(conflictsProvider.notifier).loadMore();
                        } on ApiException {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Не удалось загрузить ещё'),
                              ),
                            );
                          }
                        }
                      },
                child: const Text('Показать ещё'),
              ),
            ),
        ],
      );
    }
    return ScreenScaffold(
      title: 'Журнал конфликтов',
      parentLabel: 'Синхронизация',
      onBack: () => context.go('/settings/sync'),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: body,
        ),
      ),
    );
  }
}

class _ConflictTile extends ConsumerWidget {
  const _ConflictTile({
    required this.conflict,
    required this.busy,
    required this.onRevert,
  });

  final SyncConflict conflict;
  final bool busy;
  final VoidCallback onRevert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final now = ref.watch(clockProvider)();
    final registry = ref.watch(syncRegistryProvider);
    final label = registry.maybeSpec(conflict.table)?.label ?? conflict.table;
    final title = ref
        .watch(rowTitleProvider((table: conflict.table, id: conflict.rowId)))
        .value;
    final showValues =
        conflict.kind == ConflictKind.field ||
        conflict.kind == ConflictKind.editVsDelete;
    return AppCard(
      key: Key('conflict-${conflict.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title == null ? label : '$label · $title',
                  style: t.bodyStrong,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (conflict.isReverted)
                const StatusPill(label: 'Возвращено', tone: StatusTone.success),
            ],
          ),
          Text(
            formatMoment(conflict.createdAt, now),
            style: t.caption.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(describeConflict(conflict, conflict.field), style: t.bodyS),
          if (showValues) ...[
            const SizedBox(height: AppSpacing.s3),
            _ValueRow(
              label: 'Проиграло',
              value: describeValue(conflict.losingValue),
            ),
            const SizedBox(height: AppSpacing.s1),
            _ValueRow(
              label: 'Осталось',
              value: describeValue(conflict.winningValue),
            ),
          ],
          if (conflict.canRevert) ...[
            const SizedBox(height: AppSpacing.s3),
            ElevatedButton(
              key: Key('revert-${conflict.id}'),
              onPressed: busy ? null : onRevert,
              child: busy
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.textSecondary,
                      ),
                    )
                  : const Text('Вернуть моё'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(label, style: t.caption.copyWith(color: c.textTertiary)),
        ),
        Expanded(child: Text(value, style: t.numS)),
      ],
    );
  }
}
