import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';
import 'package:my_tasker/features/finance/presentation/privacy/pin_dialogs.dart';

/// «Приватность»: скрыть суммы, замок раздела (включить, сменить PIN,
/// отключить, когда блокировать, биометрия). Только на этом устройстве.
class FinancePrivacyScreen extends ConsumerStatefulWidget {
  const FinancePrivacyScreen({super.key});

  @override
  ConsumerState<FinancePrivacyScreen> createState() =>
      _FinancePrivacyScreenState();
}

class _FinancePrivacyScreenState extends ConsumerState<FinancePrivacyScreen> {
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final available = await ref
        .read(biometricAuthenticatorProvider)
        .isAvailable();
    if (mounted) setState(() => _bioAvailable = available);
  }

  Future<void> _toggleLock({required bool on}) async {
    final lock = ref.read(financeLockProvider.notifier);
    if (on) {
      final pin = await askNewPin(context);
      if (pin == null) return;
      await lock.enable(pin);
    } else {
      final pin = await askCurrentPin(
        context,
        title: 'Введите PIN, чтобы отключить замок',
      );
      if (pin == null) return;
      await lock.disable(pin);
    }
  }

  Future<void> _changePin() async {
    final lock = ref.read(financeLockProvider.notifier);
    final current = await askCurrentPin(context);
    if (current == null || !mounted) return;
    final next = await askNewPin(context, title: 'Новый PIN');
    if (next == null) return;
    final result = await lock.changePin(current, next);
    if (!mounted) return;
    if (result is PinAccepted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('PIN изменён')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final lock = ref.watch(financeLockProvider);
    final hidden = ref.watch(hideAmountsProvider.select((s) => s.hidden));
    return ScreenScaffold(
      title: 'Приватность',
      parentLabel: 'Финансы',
      onBack: () => context.go('/finance'),
      child: Column(
        key: const Key('privacy-screen'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            padding: EdgeInsets.zero,
            child: _SwitchRow(
              key: const Key('privacy-hide-switch'),
              icon: hidden ? LucideIcons.eyeOff : LucideIcons.eye,
              title: 'Скрывать суммы',
              subtitle:
                  'Вместо сумм показывать •••• ₽ на всех экранах Финансов',
              value: hidden,
              onChanged: (v) => unawaited(
                ref.read(hideAmountsProvider.notifier).set(hidden: v),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SwitchRow(
                  key: const Key('privacy-lock-switch'),
                  icon: lock.enabled ? LucideIcons.lock : LucideIcons.lockOpen,
                  title: 'Замок раздела',
                  subtitle: lock.enabled
                      ? 'Раздел закрыт PIN-кодом'
                      : 'Закрыть «Финансы» PIN-кодом (4–6 цифр)',
                  value: lock.enabled,
                  onChanged: lock.loaded
                      ? (v) => unawaited(_toggleLock(on: v))
                      : null,
                ),
                if (lock.enabled) ...[
                  const _Divider(),
                  InkWell(
                    key: const Key('privacy-change-pin'),
                    onTap: () => unawaited(_changePin()),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s4,
                        vertical: AppSpacing.s3,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.keyRound,
                            size: 20,
                            color: c.textSecondary,
                          ),
                          const SizedBox(width: AppSpacing.s3),
                          Expanded(child: Text('Сменить PIN', style: t.body)),
                          Icon(
                            LucideIcons.chevronRight,
                            size: 16,
                            color: c.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const _Divider(),
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.s4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Блокировать', style: t.body),
                        const SizedBox(height: AppSpacing.s1),
                        Text(
                          'Когда вы вышли из раздела или свернули приложение',
                          style: t.bodyS.copyWith(color: c.textSecondary),
                        ),
                        const SizedBox(height: AppSpacing.s3),
                        Wrap(
                          spacing: AppSpacing.s2,
                          runSpacing: AppSpacing.s2,
                          children: [
                            for (final timing in LockTiming.values)
                              FilterPill(
                                key: Key('privacy-timing-${timing.wire}'),
                                label: timing.label,
                                selected: lock.timing == timing,
                                onTap: () => unawaited(
                                  ref
                                      .read(financeLockProvider.notifier)
                                      .setTiming(timing),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_bioAvailable) ...[
                    const _Divider(),
                    _SwitchRow(
                      key: const Key('privacy-biometric-switch'),
                      icon: LucideIcons.fingerprintPattern,
                      title: 'Биометрия',
                      subtitle:
                          'Открывать отпечатком или лицом; PIN остаётся '
                          'запасным',
                      value: lock.biometric,
                      onChanged: (v) => unawaited(
                        ref
                            .read(financeLockProvider.notifier)
                            .setBiometric(value: v),
                      ),
                    ),
                  ],
                  const _Divider(),
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.s4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ElevatedButton.icon(
                        key: const Key('privacy-lock-now'),
                        onPressed: () {
                          ref.read(financeLockProvider.notifier).lockNow();
                        },
                        icon: const Icon(LucideIcons.lock, size: 18),
                        label: const Text('Заблокировать сейчас'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'Замок и скрытие сумм работают только на этом устройстве: '
            'на сервер и в синхронизацию они не попадают. Если забыть PIN, '
            'раздел на этом устройстве не открыть.',
            key: const Key('privacy-note'),
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    color: context.colors.borderDefault,
    indent: AppSpacing.s4,
    endIndent: AppSpacing.s4,
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return InkWell(
      borderRadius: AppRadii.borderL,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
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
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}
