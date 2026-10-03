import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';
import 'package:my_tasker/features/finance/presentation/privacy/pin_entry.dart';

/// Охранник маршрутов `/finance/**`: пока замок закрыт (или ещё не прочитан),
/// вместо содержимого — экран ввода PIN. Работает и для глубоких ссылок:
/// маршрут открывается как обычно, но строит он этот виджет.
class FinanceGate extends ConsumerWidget {
  const FinanceGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = ref.watch(financeLockProvider.select((s) => s.loaded));
    final closed = ref.watch(financeLockProvider.select((s) => s.closed));
    if (!loaded) return const SizedBox.shrink();
    return closed ? const FinanceLockScreen() : child;
  }
}

/// Экран «Раздел заблокирован» с вводом PIN.
class FinanceLockScreen extends StatelessWidget {
  const FinanceLockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return ScreenScaffold(
      title: 'Финансы',
      child: Center(
        key: const Key('finance-lock-screen'),
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: c.surface3,
                  shape: BoxShape.circle,
                ),
                child: Icon(LucideIcons.lock, size: 26, color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                'Раздел заблокирован',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s4),
              const UnlockPanel(),
            ],
          ),
        ),
      ),
    );
  }
}

/// «mm:ss» оставшейся паузы.
String pauseText(Duration d) {
  final seconds = d.inSeconds < 0
      ? 0
      : d.inSeconds + (d.inMilliseconds % 1000 > 0 ? 1 : 0);
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Ввод PIN для разблокировки: проверка, счётчик неверных попыток, пауза с
/// обратным отсчётом, биометрия.
class UnlockPanel extends ConsumerStatefulWidget {
  const UnlockPanel({this.onUnlocked, super.key});

  /// Вызывается после успешной разблокировки (диалог закрывается).
  final VoidCallback? onUnlocked;

  @override
  ConsumerState<UnlockPanel> createState() => _UnlockPanelState();
}

class _UnlockPanelState extends ConsumerState<UnlockPanel> {
  Timer? _ticker;
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probeBiometric());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _probeBiometric() async {
    final lock = ref.read(financeLockProvider.notifier);
    await lock.ready;
    if (!mounted) return;
    final wanted = ref.read(financeLockProvider).biometric;
    if (!wanted) return;
    final available = await ref
        .read(biometricAuthenticatorProvider)
        .isAvailable();
    if (!mounted) return;
    setState(() => _bioAvailable = available);
    // Системный запрос сразу при показе; PIN остаётся запасным путём.
    if (available) await _biometric();
  }

  Future<void> _biometric() async {
    final ok = await ref
        .read(financeLockProvider.notifier)
        .unlockWithBiometric('Откройте раздел «Финансы»');
    if (ok && mounted) widget.onUnlocked?.call();
  }

  Duration? _remaining(FinanceLockState lock) {
    final until = lock.pausedUntil;
    if (until == null) return null;
    final left = until.difference(ref.read(clockProvider)());
    return left > Duration.zero ? left : null;
  }

  void _syncTicker(Duration? remaining) {
    if (remaining == null) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<String?> _submit(String pin) async {
    final result = await ref.read(financeLockProvider.notifier).unlock(pin);
    switch (result) {
      case PinAccepted():
        widget.onUnlocked?.call();
        return null;
      case PinRejected(:final attemptsLeft, :final pausedUntil):
        if (pausedUntil != null) return 'Слишком много попыток';
        return 'Неверный PIN. До паузы осталось попыток: $attemptsLeft';
      case PinPaused():
        return 'Слишком много попыток';
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(financeLockProvider);
    final remaining = _remaining(lock);
    // Тикер включается/выключается после кадра: setState в build нельзя.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTicker(_remaining(ref.read(financeLockProvider)));
    });
    return PinEntry(
      title: 'Введите PIN',
      length: lock.pinLength,
      enabled: remaining == null,
      message: remaining == null
          ? null
          : 'Слишком много попыток. Повторите через ${pauseText(remaining)}',
      messageIsError: remaining != null,
      onSubmit: _submit,
      onBiometric: lock.biometric && _bioAvailable ? _biometric : null,
    );
  }
}

/// Просит разблокировать «Финансы» перед действием из другого раздела (например,
/// создание операции из общего «+»). `true` — раздел открыт (замок выключен,
/// снят или только что снят PIN).
Future<bool> ensureFinanceUnlocked(BuildContext context) async {
  final container = ProviderScope.containerOf(context);
  await container.read(financeLockProvider.notifier).ready;
  if (!container.read(financeLockProvider).closed) return true;
  if (!context.mounted) return false;
  final unlocked = await showDialog<bool>(
    context: context,
    builder: (_) => const _UnlockDialog(),
  );
  return unlocked ?? false;
}

class _UnlockDialog extends StatelessWidget {
  const _UnlockDialog();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Dialog(
      key: const Key('finance-unlock-dialog'),
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderXl),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.lock, size: 20, color: c.textSecondary),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      'Раздел «Финансы» заблокирован',
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  ),
                  IconButton(
                    key: const Key('finance-unlock-cancel'),
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(LucideIcons.x, size: 22),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              UnlockPanel(onUnlocked: () => Navigator.of(context).pop(true)),
            ],
          ),
        ),
      ),
    );
  }
}
