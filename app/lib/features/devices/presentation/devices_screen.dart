import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/devices/devices_providers.dart';

IconData _platformIcon(DevicePlatform p) => switch (p) {
  DevicePlatform.android || DevicePlatform.ios => LucideIcons.smartphone,
  DevicePlatform.windows ||
  DevicePlatform.linux ||
  DevicePlatform.macos => LucideIcons.monitor,
  DevicePlatform.web => LucideIcons.globe,
  DevicePlatform.other => LucideIcons.laptop,
};

String _platformName(DevicePlatform p) => switch (p) {
  DevicePlatform.android => 'Android',
  DevicePlatform.windows => 'Windows',
  DevicePlatform.linux => 'Linux',
  DevicePlatform.macos => 'macOS',
  DevicePlatform.ios => 'iOS',
  DevicePlatform.web => 'Веб',
  DevicePlatform.other => 'Устройство',
};

/// «Настройки › Мои устройства»: список, текущее помечено, чужие можно
/// отозвать (подтверждение), выход из аккаунта.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    RegisteredDevice device,
  ) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Отозвать «${device.name}»?',
      message:
          'Устройство сразу выйдет из аккаунта и больше не сможет '
          'синхронизироваться. Данные на нём останутся, войти снова можно '
          'по паролю и коду.',
      confirmLabel: 'Отозвать',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(authApiProvider)!.revokeDevice(device.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Устройство «${device.name}» отозвано')),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'device_not_found'
                ? 'Устройства уже нет в списке'
                : e.isNetwork
                ? 'Не удалось отозвать: нет соединения'
                : 'Не удалось отозвать устройство',
          ),
        ),
      );
    }
    ref.invalidate(devicesProvider);
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final unsent = ref.read(syncStatusProvider).outbox.unsent;
    final ok = await showConfirmDialog(
      context,
      title: 'Выйти из аккаунта?',
      message: unsent > 0
          ? 'Не отправлено на сервер: $unsent. Эти изменения останутся на '
                'устройстве и отправятся после следующего входа.'
          : 'Данные на устройстве останутся. Чтобы синхронизироваться '
                'снова, войди по паролю и коду.',
      confirmLabel: 'Выйти',
    );
    if (!ok) return;
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final showRevoked = ref.watch(showRevokedDevicesProvider);
    final now = ref.watch(clockProvider)();
    final c = context.colors;
    final t = context.text;

    final Widget body;
    if (devices.isLoading && !devices.hasValue) {
      body = const ListSkeleton();
    } else if (devices.hasError && !devices.hasValue) {
      final error = devices.error;
      final offline = error is ApiException && error.isNetwork;
      body = NoticeCard(
        key: Key(offline ? 'devices-offline' : 'devices-error'),
        label: offline ? 'Офлайн' : 'Не загрузилось',
        tone: offline ? StatusTone.neutral : StatusTone.danger,
        text: offline
            ? 'Список устройств хранится на сервере, а связи с ним нет. '
                  'Всё остальное работает.'
            : 'Не удалось получить список устройств. Попробуй ещё раз.',
        actions: [
          FilledButton(
            key: const Key('devices-retry'),
            onPressed: () => ref.invalidate(devicesProvider),
            child: const Text('Повторить'),
          ),
        ],
      );
    } else if (devices.requireValue.isEmpty) {
      body = const EmptyState(
        icon: LucideIcons.smartphone,
        title: 'Устройств нет',
        message: 'Здесь появятся телефон и компьютеры после входа.',
      );
    } else {
      body = Column(
        key: const Key('devices-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final d in devices.requireValue) ...[
            _DeviceTile(
              device: d,
              now: now,
              onRevoke: () => _revoke(context, ref, d),
            ),
            const SizedBox(height: AppSpacing.s2),
          ],
        ],
      );
    }

    return ScreenScaffold(
      title: 'Мои устройства',
      parentLabel: 'Настройки',
      onBack: () => context.go('/settings'),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              body,
              const SizedBox(height: AppSpacing.s4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Показывать отозванные',
                      style: t.body.copyWith(color: c.textSecondary),
                    ),
                  ),
                  Switch(
                    key: const Key('devices-show-revoked'),
                    value: showRevoked,
                    onChanged: (v) => ref
                        .read(showRevokedDevicesProvider.notifier)
                        .set(value: v),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s6),
              ElevatedButton.icon(
                key: const Key('devices-logout'),
                onPressed: () => _logout(context, ref),
                icon: const Icon(LucideIcons.logOut, size: 18),
                label: const Text('Выйти из аккаунта'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.now,
    required this.onRevoke,
  });

  final RegisteredDevice device;
  final DateTime now;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final meta = [
      _platformName(device.platform),
      if (device.appVersion != null) device.appVersion!,
    ].join(' · ');
    final seen = device.isCurrent
        ? 'Активно сейчас'
        : device.lastSeenAt == null
        ? 'Ещё не заходило'
        : 'Заходило ${formatMoment(device.lastSeenAt!, now)}';
    return AppCard(
      key: Key('device-${device.id}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.surface3,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _platformIcon(device.platform),
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
                  device.name,
                  style: t.bodyStrong,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(meta, style: t.bodyS.copyWith(color: c.textSecondary)),
                Text(
                  device.isRevoked
                      ? 'Отозвано ${formatMoment(device.revokedAt!, now)}'
                      : seen,
                  style: t.caption.copyWith(color: c.textTertiary),
                ),
                if (device.isCurrent || device.isRevoked) ...[
                  const SizedBox(height: AppSpacing.s2),
                  StatusPill(
                    label: device.isCurrent ? 'Это устройство' : 'Отозвано',
                    tone: device.isCurrent
                        ? StatusTone.success
                        : StatusTone.neutral,
                  ),
                ],
              ],
            ),
          ),
          if (!device.isCurrent && !device.isRevoked) ...[
            const SizedBox(width: AppSpacing.s2),
            ElevatedButton(
              key: Key('revoke-${device.id}'),
              onPressed: onRevoke,
              child: const Text('Отозвать'),
            ),
          ],
        ],
      ),
    );
  }
}
