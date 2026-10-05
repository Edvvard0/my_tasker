import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_text_field.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';

/// Замок раздела: пока PIN включён и раздел закрыт, вместо содержимого
/// показывается ввод PIN (или биометрия, если она включена). Раздел
/// закрывается снова, когда приложение уходит в фон; при закрытии замок
/// убирает и открытые поверх раздела окна (листы, диалоги), чтобы форма долга
/// или сверки не пережила блокировку. Пока раздел открыт, экран защищён от
/// снимков (`FLAG_SECURE`).
class FinanceLockGate extends ConsumerStatefulWidget {
  const FinanceLockGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<FinanceLockGate> createState() => _FinanceLockGateState();
}

class _FinanceLockGateState extends ConsumerState<FinanceLockGate>
    with WidgetsBindingObserver {
  late final SecureScreenNotifier _secure = ref.read(
    secureScreenProvider.notifier,
  );
  late final String _secureReason = 'finance_open:${identityHashCode(this)}';
  bool _secureOn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_secureOn) {
      // Провайдеры нельзя менять, пока дерево виджетов разбирается.
      final secure = _secure;
      final reason = _secureReason;
      scheduleMicrotask(() {
        try {
          secure.setReason(reason, on: false);
        } on Object {
          // Контейнер уже закрыт (конец теста или приложения).
        }
      });
    }
    super.dispose();
  }

  void _syncSecure({required bool open}) {
    if (open == _secureOn) return;
    _secureOn = open;
    scheduleMicrotask(() {
      if (!mounted && open) return;
      try {
        _secure.setReason(_secureReason, on: open);
      } on Object {
        // Контейнер закрыт.
      }
    });
  }

  /// Закрывает окна поверх раздела (листы, диалоги, меню). Страницы не
  /// трогает. Скрытый раздел (другая вкладка оболочки) чужих окон не
  /// закрывает.
  void _closeModals() {
    if (!mounted || !TickerMode.valuesOf(context).enabled) return;
    bool isModal(Route<dynamic> route) => route is PopupRoute;
    final nearest = Navigator.of(context);
    final root = Navigator.of(context, rootNavigator: true);
    nearest.popUntil((route) => !isModal(route));
    if (!identical(nearest, root)) root.popUntil((route) => !isModal(route));
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
    ref.listen<FinanceLockState>(financeLockProvider, (previous, next) {
      if (next.locked && previous != null && !previous.locked) _closeModals();
    });
    _syncSecure(open: lock.loaded && !lock.locked);
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
class LockScreen extends StatelessWidget {
  const LockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      key: const Key('finance-lock'),
      title: 'Финансы',
      scrollable: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: const SingleChildScrollView(child: FinanceUnlockForm()),
        ),
      ),
    );
  }
}

/// Форма разблокировки: PIN, биометрия, «Забыл PIN». Общая для экрана замка
/// и для диалога разблокировки в других разделах ([ensureFinanceUnlocked]).
class FinanceUnlockForm extends ConsumerStatefulWidget {
  const FinanceUnlockForm({this.showHeader = true, this.hint, super.key});

  /// Значок и заголовок «Раздел закрыт» (в диалоге заголовок свой).
  final bool showHeader;

  /// Пояснение под заголовком; по умолчанию — про счета и суммы.
  final String? hint;

  @override
  ConsumerState<FinanceUnlockForm> createState() => _FinanceUnlockFormState();
}

class _FinanceUnlockFormState extends ConsumerState<FinanceUnlockForm> {
  final _pin = TextEditingController();
  String? _message;
  bool _busy = false;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    _pin.dispose();
    super.dispose();
  }

  /// Раз в секунду перерисовывает обратный отсчёт блокировки и сам
  /// останавливается, когда блокировка закончилась: поле и кнопка снова
  /// оживают без нажатий.
  void _syncTicker({required bool blocked}) {
    if (blocked && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final until = ref.read(financeLockProvider).blockedUntil;
        final stillBlocked =
            until != null && until.isAfter(ref.read(clockProvider)().toUtc());
        if (!stillBlocked) {
          _ticker?.cancel();
          _ticker = null;
        }
        setState(() {});
      });
    } else if (!blocked && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
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

  /// «Забыл PIN»: сброс замка с явным подтверждением. Данные раздела не
  /// удаляются. Если на устройстве есть биометрия, сначала подтверждается
  /// владелец устройства.
  Future<void> _forgot({required bool storageBroken}) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Сбросить замок раздела?',
      message: storageBroken
          ? 'Защищённое хранилище PIN не читается. Замок будет снят на '
                'этом устройстве, данные раздела останутся. Новый PIN можно '
                'задать в настройках раздела.'
          : 'PIN будет удалён, замок снят на этом устройстве. Данные раздела '
                'не пропадут. Новый PIN можно задать в настройках раздела.',
      confirmLabel: 'Сбросить замок',
      danger: true,
    );
    if (!ok || !mounted) return;
    final biometric = ref.read(biometricProvider);
    if (await biometric.isAvailable()) {
      final proven = await biometric.authenticate(
        reason: 'Подтвердите, что это вы, чтобы сбросить замок',
      );
      if (!proven) {
        if (mounted) setState(() => _message = 'Не удалось подтвердить');
        return;
      }
    }
    await ref.read(financeLockProvider.notifier).resetLock();
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
    _syncTicker(blocked: blocked);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showHeader) ...[
          Icon(LucideIcons.lock, size: 32, color: c.textTertiary),
          const SizedBox(height: AppSpacing.s3),
          Text('Раздел закрыт', style: t.h3),
          const SizedBox(height: AppSpacing.s1),
        ],
        Text(
          lock.error ??
              widget.hint ??
              'Введите PIN, чтобы увидеть счета и суммы.',
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
                LengthLimitingTextInputFormatter(PinLockService.maxLength),
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
              onPressed: blocked ? null : _biometric,
              icon: const Icon(LucideIcons.fingerprint, size: 18),
              label: const Text('Биометрия'),
            ),
          ],
          const SizedBox(height: AppSpacing.s2),
          TextButton(
            key: const Key('lock-forgot'),
            onPressed: () => unawaited(_forgot(storageBroken: false)),
            child: const Text('Забыл PIN'),
          ),
        ] else ...[
          FilledButton(
            key: const Key('lock-retry'),
            onPressed: () =>
                unawaited(ref.read(financeLockProvider.notifier).load()),
            child: const Text('Повторить'),
          ),
          const SizedBox(height: AppSpacing.s2),
          TextButton(
            key: const Key('lock-reset'),
            onPressed: () => unawaited(_forgot(storageBroken: true)),
            child: const Text('Сбросить замок'),
          ),
        ],
      ],
    );
  }
}

/// Убеждается, что раздел «Финансы» открыт: если замок включён и закрыт,
/// показывает диалог ввода PIN (или биометрии). `true` — раздел открыт.
/// Нужен местам вне раздела, которые показывают или отдают финансовые
/// данные: быстрый ввод операции, превью контекста ИИ, согласие на
/// финансовые инструменты ИИ.
Future<bool> ensureFinanceUnlocked(
  BuildContext context,
  WidgetRef ref, {
  String? hint,
}) async {
  final notifier = ref.read(financeLockProvider.notifier);
  if (!ref.read(financeLockProvider).loaded) await notifier.load();
  if (!ref.read(financeLockProvider).locked) return true;
  if (!context.mounted) return false;
  final opened = await showDialog<bool>(
    context: context,
    builder: (_) => _UnlockDialog(hint: hint),
  );
  return (opened ?? false) && !ref.read(financeLockProvider).locked;
}

class _UnlockDialog extends ConsumerWidget {
  const _UnlockDialog({this.hint});

  final String? hint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<FinanceLockState>(financeLockProvider, (previous, next) {
      if (next.loaded && !next.locked && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    });
    return AlertDialog(
      key: const Key('finance-unlock-dialog'),
      title: Text('Раздел «Финансы» закрыт', style: context.text.h3),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: FinanceUnlockForm(showHeader: false, hint: hint),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('finance-unlock-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}
