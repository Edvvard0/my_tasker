import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/sync/sync_texts.dart';

/// Индикатор синхронизации в верхней панели (02, 2.9.4 и 4.12): тишина, пока
/// всё хорошо; вращающийся значок при обмене; пилюля «Офлайн» / «Не
/// синхронизировано» / «Нужно обновить». Тап открывает сводку.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final c = context.colors;
    final t = context.text;
    final kind = status.indicator;
    if (kind == SyncIndicatorKind.synced) return const SizedBox.shrink();

    final Widget child;
    if (kind == SyncIndicatorKind.syncing) {
      child = const _SpinningIcon();
    } else {
      final danger = kind == SyncIndicatorKind.error;
      final icon = switch (kind) {
        SyncIndicatorKind.offline => LucideIcons.cloudOff,
        SyncIndicatorKind.error => LucideIcons.cloudAlert,
        _ => LucideIcons.triangleAlert,
      };
      final fg = danger ? c.danger : c.textSecondary;
      final compact = context.windowClass.isCompact;
      final label = indicatorLabel(status, compact: compact)!;
      child = Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: danger ? c.dangerMuted : c.surface3,
          borderRadius: AppRadii.borderFull,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(
                label,
                key: const Key('sync-indicator-label'),
                style: t.bodyS.copyWith(color: fg),
              ),
            ],
          ],
        ),
      );
    }
    return Semantics(
      button: true,
      label: 'Состояние синхронизации: ${indicatorLabel(status)}',
      child: InkWell(
        key: const Key('sync-indicator'),
        borderRadius: AppRadii.borderFull,
        onTap: () => showSyncSheet(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: child,
        ),
      ),
    );
  }
}

class _SpinningIcon extends StatefulWidget {
  const _SpinningIcon();

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    key: const Key('sync-spinner'),
    turns: _controller,
    child: Icon(
      LucideIcons.refreshCw,
      size: 20,
      color: context.colors.textSecondary,
    ),
  );
}

/// Баннеры под верхней панелью: приложению нужно обновление (`426`) и
/// «часы устройства спешат» (`hlc_in_future`).
class SyncBanner extends ConsumerWidget {
  const SyncBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(syncStatusProvider.select((s) => s.run));
    final String? text;
    final IconData icon;
    if (run.isBlocked) {
      text =
          'Нужно обновить приложение. Оно продолжает работать офлайн, но '
          'синхронизация выключена, пока версия не обновится.';
      icon = LucideIcons.triangleAlert;
    } else if (run.clockSkew) {
      text =
          'Проверьте время на устройстве: часы спешат, и сервер не принимает '
          'изменения. Они останутся на устройстве и отправятся позже.';
      icon = LucideIcons.clock;
    } else {
      return const SizedBox.shrink();
    }
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.windowClass.gutter,
        0,
        context.windowClass.gutter,
        AppSpacing.s2,
      ),
      child: Container(
        key: Key(run.isBlocked ? 'banner-update' : 'banner-clock'),
        padding: const EdgeInsets.all(AppSpacing.s3),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: AppRadii.borderM,
          border: Border.all(color: c.borderStrong),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: c.textPrimary),
            const SizedBox(width: AppSpacing.s3),
            Expanded(child: Text(text, style: context.text.bodyS)),
          ],
        ),
      ),
    );
  }
}

/// Сводка по 4.12: статус, что не отправлено, время последней
/// синхронизации, «Синхронизировать сейчас».
class SyncSummaryPanel extends ConsumerWidget {
  const SyncSummaryPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final now = ref.watch(clockProvider)();
    final c = context.colors;
    final t = context.text;
    final run = status.run;
    final unsent = status.outbox.unsent;
    final (icon, headline) = switch (status.indicator) {
      SyncIndicatorKind.synced => (
        LucideIcons.cloudCheck,
        'Всё синхронизировано',
      ),
      SyncIndicatorKind.syncing => (
        LucideIcons.refreshCw,
        'Идёт синхронизация…',
      ),
      SyncIndicatorKind.offline => (LucideIcons.cloudOff, 'Офлайн'),
      SyncIndicatorKind.error => (
        LucideIcons.cloudAlert,
        'Не синхронизировано',
      ),
      SyncIndicatorKind.blocked => (
        LucideIcons.triangleAlert,
        'Нужно обновить приложение',
      ),
    };
    final failure = run.failure;
    return Column(
      key: const Key('sync-summary'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Синхронизация', style: t.h3),
        const SizedBox(height: AppSpacing.s3),
        Row(
          children: [
            Icon(icon, size: 20, color: c.textPrimary),
            const SizedBox(width: AppSpacing.s2),
            Text(headline, style: t.bodyStrong),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        // Офлайн с очередью: как на макете 4.12 — только «сохранено N изменений».
        if (failure != null &&
            !(failure.kind == SyncFailureKind.offline && unsent > 0))
          Text(
            syncFailureText(failure.kind),
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
        if (unsent > 0)
          Text(
            'На устройстве сохранено ${changesCount(unsent)}. Отправим, как '
            'только появится сеть.',
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
        if (status.outbox.rejected > 0) ...[
          const SizedBox(height: AppSpacing.s1),
          Text(
            'Сервер не принял: ${status.outbox.rejected}.',
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
        ],
        const SizedBox(height: AppSpacing.s4),
        _Row(
          'Последняя синхронизация',
          run.lastSuccessAt == null
              ? 'ещё не было'
              : formatMoment(run.lastSuccessAt!, now),
        ),
        const SizedBox(height: AppSpacing.s4),
        Wrap(
          spacing: AppSpacing.s3,
          runSpacing: AppSpacing.s2,
          children: [
            FilledButton(
              key: const Key('sync-now'),
              onPressed: run.isBusy || run.isBlocked
                  ? null
                  : () => ref.read(syncCoordinatorProvider).syncNow(),
              child: const Text('Синхронизировать сейчас'),
            ),
            TextButton(
              key: const Key('sync-details'),
              onPressed: () {
                Navigator.of(context).pop();
                context.go('/settings/sync');
              },
              child: const Text('Подробнее'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Row(
      children: [
        Expanded(
          child: Text(label, style: t.bodyS.copyWith(color: c.textSecondary)),
        ),
        Text(value, style: t.bodyS),
      ],
    );
  }
}

/// Сводка: bottom sheet на телефоне, компактное окно на десктопе.
Future<void> showSyncSheet(BuildContext context) {
  if (context.windowClass.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => const Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.s4,
          0,
          AppSpacing.s4,
          AppSpacing.s6,
        ),
        child: SyncSummaryPanel(),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.s6),
          child: SyncSummaryPanel(),
        ),
      ),
    ),
  );
}
