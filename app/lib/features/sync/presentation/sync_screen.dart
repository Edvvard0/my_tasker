import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/sync/sync_providers_ui.dart';
import 'package:my_tasker/features/sync/sync_texts.dart';

/// «Настройки › Синхронизация»: состояние, размер очереди, времена
/// последнего обмена, ошибки и отклонённые операции, «Синхронизировать
/// сейчас» и «Полная пересинхронизация».
class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  Future<void> _fullResync(BuildContext context, WidgetRef ref) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Пересинхронизировать всё?',
      message:
          'Локальные данные будут заменены тем, что хранится на сервере. '
          'Неотправленные изменения не потеряются: они отправятся первыми и '
          'останутся поверх. Это может занять время.',
      confirmLabel: 'Пересинхронизировать',
    );
    if (!ok || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await ref.read(syncEngineProvider).fullResync();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome == SyncOutcome.success
              ? 'Данные загружены заново'
              : 'Не удалось пересинхронизировать: '
                    '${syncFailureText(ref.read(syncStatusProvider).run.failure?.kind ?? SyncFailureKind.unknown)}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final rejected = ref.watch(rejectedOpsProvider).value ?? const [];
    final cursor = ref.watch(syncCursorProvider).value;
    final now = ref.watch(clockProvider)();
    final run = status.run;
    final kind = status.indicator;

    final (label, tone) = switch (kind) {
      SyncIndicatorKind.synced => ('Синхронизировано', StatusTone.success),
      SyncIndicatorKind.syncing => (
        run.phase == SyncPhase.resyncing
            ? 'Загружаем данные'
            : 'Идёт синхронизация',
        StatusTone.info,
      ),
      SyncIndicatorKind.offline => ('Офлайн', StatusTone.neutral),
      SyncIndicatorKind.error => ('Не синхронизировано', StatusTone.danger),
      SyncIndicatorKind.blocked => ('Нужно обновить', StatusTone.warning),
    };
    final failure = run.failure;
    final text = switch (kind) {
      SyncIndicatorKind.synced => 'Все изменения отправлены и получены.',
      SyncIndicatorKind.blocked => syncFailureText(
        SyncFailureKind.clientTooOld,
      ),
      SyncIndicatorKind.syncing =>
        run.pulledRows > 0
            ? 'Загружено записей: ${run.pulledRows}.'
            : 'Обмениваемся данными с сервером…',
      _ =>
        failure != null
            ? syncFailureText(failure.kind)
            : status.outbox.rejected > 0
            ? 'Сервер не принял часть изменений — они перечислены ниже.'
            : 'Нет связи с сервером. Изменения сохраняются на устройстве.',
    };
    final busy = run.isBusy;

    return ScreenScaffold(
      title: 'Синхронизация',
      parentLabel: 'Настройки',
      onBack: () => context.go('/settings'),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NoticeCard(
                key: const Key('sync-status-card'),
                label: label,
                tone: tone,
                text: text,
                details: failure?.message,
                actions: [
                  if (kind != SyncIndicatorKind.synced &&
                      kind != SyncIndicatorKind.blocked &&
                      !busy)
                    FilledButton(
                      key: const Key('sync-retry'),
                      onPressed: () =>
                          ref.read(syncCoordinatorProvider).syncNow(),
                      child: const Text('Повторить'),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.s4),
              AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s4,
                  vertical: AppSpacing.s2,
                ),
                child: Column(
                  key: const Key('sync-metrics'),
                  children: [
                    _Metric(
                      'Ждут отправки',
                      '${status.outbox.pending + status.outbox.inFlight}',
                      keyName: 'metric-unsent',
                    ),
                    _Metric(
                      'Не принято сервером',
                      '${status.outbox.rejected}',
                      keyName: 'metric-rejected',
                    ),
                    _Metric(
                      'Последняя отправка',
                      run.lastPushAt == null
                          ? '—'
                          : formatMoment(run.lastPushAt!, now),
                      keyName: 'metric-push',
                    ),
                    _Metric(
                      'Последняя загрузка',
                      run.lastPullAt == null
                          ? '—'
                          : formatMoment(run.lastPullAt!, now),
                      keyName: 'metric-pull',
                    ),
                    _Metric(
                      'Версия данных',
                      cursor == null ? '—' : '$cursor',
                      keyName: 'metric-cursor',
                      last: true,
                    ),
                  ],
                ),
              ),
              if (rejected.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s6),
                Text('Не принято сервером', style: context.text.h3),
                const SizedBox(height: AppSpacing.s2),
                for (final op in rejected) ...[
                  _RejectedTile(op: op),
                  const SizedBox(height: AppSpacing.s2),
                ],
              ],
              const SizedBox(height: AppSpacing.s6),
              Wrap(
                spacing: AppSpacing.s3,
                runSpacing: AppSpacing.s2,
                children: [
                  FilledButton(
                    key: const Key('sync-now-button'),
                    onPressed: busy || run.isBlocked
                        ? null
                        : () => ref.read(syncCoordinatorProvider).syncNow(),
                    child: const Text('Синхронизировать сейчас'),
                  ),
                  ElevatedButton(
                    key: const Key('full-resync-button'),
                    onPressed: busy || run.isBlocked
                        ? null
                        : () => _fullResync(context, ref),
                    child: const Text('Полная пересинхронизация'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s6),
              _LinkTile(
                key: const Key('open-conflicts'),
                icon: LucideIcons.gitCompare,
                title: 'Журнал конфликтов',
                subtitle: 'Что и почему проиграло при слиянии правок',
                onTap: () => context.go('/settings/sync/conflicts'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(
    this.label,
    this.value, {
    required this.keyName,
    this.last = false,
  });

  final String label;
  final String value;
  final String keyName;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: t.body.copyWith(color: c.textSecondary),
                ),
              ),
              Text(value, key: Key(keyName), style: t.numM),
            ],
          ),
        ),
        if (!last) Divider(color: c.borderSubtle),
      ],
    );
  }
}

class _RejectedTile extends ConsumerWidget {
  const _RejectedTile({required this.op});

  final OutboxOp op;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final store = ref.watch(syncStoreProvider);
    final spec = store.registry.maybeSpec(op.table);
    return AppCard(
      key: Key('rejected-${op.opId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${opTypeLabel(op.type)} · ${spec?.label ?? op.table}',
            style: t.bodyStrong,
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            rejectCodeText(op.rejectCode),
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          Text(
            [
              ?op.rejectCode,
              if (op.rejectMessage != null) op.rejectMessage!,
            ].join(' · '),
            style: t.caption.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: AppSpacing.s3,
            runSpacing: AppSpacing.s2,
            children: [
              ElevatedButton(
                key: Key('retry-${op.opId}'),
                onPressed: () async {
                  await store.retryRejected(op.opId);
                  await ref.read(syncCoordinatorProvider).syncNow();
                },
                child: const Text('Повторить'),
              ),
              TextButton(
                key: Key('discard-${op.opId}'),
                onPressed: () async {
                  final ok = await showConfirmDialog(
                    context,
                    title: 'Отбросить изменение?',
                    message:
                        'Оно исчезнет из очереди, а запись вернётся к '
                        'версии с сервера после пересинхронизации.',
                    confirmLabel: 'Отбросить',
                  );
                  if (!ok) return;
                  await store.discardRejected(op.opId);
                  await ref.read(syncCoordinatorProvider).syncNow();
                },
                child: const Text('Отбросить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(24)),
      child: AppCard(
        child: Row(
          children: [
            Icon(icon, size: 20, color: c.textSecondary),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.body),
                  Text(
                    subtitle,
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}
