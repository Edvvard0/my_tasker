import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';

/// Замок раздела: пока PIN включён и раздел закрыт, вместо содержимого
/// показывается ввод PIN (или биометрия, если она включена). Раздел
/// закрывается снова, когда приложение уходит в фон.
class FinanceLockGate extends ConsumerStatefulWidget {
  const FinanceLockGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<FinanceLockGate> createState() => _FinanceLockGateState();
}

class _FinanceLockGateState extends ConsumerState<FinanceLockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      ref.read(financeLockProvider.notifier).lock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(financeLockProvider);
    if (!lock.loaded) {
      return const ScreenScaffold(
        key: Key('finance-lock-loading'),
        title: 'Финансы',
        scrollable: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (lock.locked) return const LockScreen();
    return widget.child;
  }
}

/// Экран ввода PIN.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pin = TextEditingController();
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _pin.text.isEmpty) return;
    setState(() => _busy = true);
    final result = await ref
        .read(financeLockProvider.notifier)
        .unlockWithPin(_pin.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pin.clear();
      _message = switch (result) {
        UnlockResult.unlocked => null,
        UnlockResult.wrong => 'Неверный PIN',
        UnlockResult.blocked => null,
      };
    });
  }

  Future<void> _biometric() async {
    final ok = await ref
        .read(financeLockProvider.notifier)
        .unlockWithBiometric();
    if (!ok && mounted) setState(() => _message = 'Не удалось подтвердить');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final lock = ref.watch(financeLockProvider);
    final now = ref.watch(clockProvider)();
    final until = lock.blockedUntil;
    final left = until == null ? 0 : until.difference(now.toUtc()).inSeconds;
    final blocked = left > 0;
    return ScreenScaffold(
      key: const Key('finance-lock'),
      title: 'Финансы',
      scrollable: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.lock, size: 32, color: c.textTertiary),
                const SizedBox(height: AppSpacing.s3),
                Text('Раздел закрыт', style: t.h3),
                const SizedBox(height: AppSpacing.s1),
                Text(
                  lock.error ?? 'Введите PIN, чтобы увидеть счета и суммы.',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.s4),
                if (lock.error == null) ...[
                  SizedBox(
                    width: 220,
                    child: AppTextField(
                      key: const Key('lock-pin'),
                      controller: _pin,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.number,
                      style: t.h2,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(
                          PinLockService.maxLength,
                        ),
                      ],
                      decoration: const InputDecoration(hintText: 'PIN'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  if (blocked)
                    Text(
                      'Слишком много попыток. Повторите через $left с.',
                      key: const Key('lock-blocked'),
                      style: t.bodyS.copyWith(color: c.danger),
                      textAlign: TextAlign.center,
                    )
                  else if (_message != null)
                    Text(
                      _message!,
                      key: const Key('lock-error'),
                      style: t.bodyS.copyWith(color: c.danger),
                    ),
                  const SizedBox(height: AppSpacing.s3),
                  FilledButton(
                    key: const Key('lock-submit'),
                    onPressed: _busy || blocked ? null : _submit,
                    child: const Text('Открыть'),
                  ),
                  if (lock.biometric) ...[
                    const SizedBox(height: AppSpacing.s2),
                    OutlinedButton.icon(
                      key: const Key('lock-biometric'),
                      onPressed: _biometric,
                      icon: const Icon(LucideIcons.fingerprint, size: 18),
                      label: const Text('Биометрия'),
                    ),
                  ],
                ] else
                  FilledButton(
                    key: const Key('lock-retry'),
                    onPressed: () => unawaited(
                      ref.read(financeLockProvider.notifier).load(),
                    ),
                    child: const Text('Повторить'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
