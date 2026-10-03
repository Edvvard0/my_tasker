import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';
import 'package:my_tasker/features/finance/presentation/privacy/finance_gate.dart';
import 'package:my_tasker/features/finance/presentation/privacy/pin_entry.dart';

/// Диалоги ввода PIN в настройках замка: придумать (дважды) и подтвердить
/// текущий.

Widget _frame(BuildContext context, Widget child) => Dialog(
  shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderXl),
  child: Padding(
    padding: const EdgeInsets.all(AppSpacing.s6),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: const Key('pin-dialog-cancel'),
              tooltip: 'Закрыть',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(LucideIcons.x, size: 22),
            ),
          ),
          child,
        ],
      ),
    ),
  ),
);

/// Просит придумать PIN и повторить его. Возвращает PIN или `null`, если
/// пользователь закрыл окно.
Future<String?> askNewPin(BuildContext context, {String? title}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NewPinDialog(title: title),
    );

class _NewPinDialog extends StatefulWidget {
  const _NewPinDialog({this.title});

  final String? title;

  @override
  State<_NewPinDialog> createState() => _NewPinDialogState();
}

class _NewPinDialogState extends State<_NewPinDialog> {
  String? _first;
  String? _mismatch;

  Future<String?> _submit(String pin) async {
    final first = _first;
    if (first == null) {
      setState(() {
        _first = pin;
        _mismatch = null;
      });
      return null;
    }
    if (first != pin) {
      setState(() {
        _first = null;
        _mismatch = 'PIN не совпал. Попробуйте ещё раз.';
      });
      return null;
    }
    Navigator.of(context).pop(pin);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final repeat = _first != null;
    return _frame(
      context,
      PinEntry(
        key: ValueKey(repeat),
        title: repeat ? 'Повторите PIN' : (widget.title ?? 'Придумайте PIN'),
        message: repeat ? null : (_mismatch ?? 'От 4 до 6 цифр'),
        messageIsError: !repeat && _mismatch != null,
        onSubmit: _submit,
      ),
    );
  }
}

/// Просит ввести текущий PIN и проверяет его. Возвращает проверенный PIN или
/// `null`, если пользователь закрыл окно.
Future<String?> askCurrentPin(BuildContext context, {String? title}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _CurrentPinDialog(title: title),
    );

class _CurrentPinDialog extends ConsumerWidget {
  const _CurrentPinDialog({this.title});

  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final length = ref.watch(financeLockProvider.select((s) => s.pinLength));
    return _frame(
      context,
      PinEntry(
        title: title ?? 'Введите текущий PIN',
        length: length,
        onSubmit: (pin) async {
          final check = await ref
              .read(financeLockProvider.notifier)
              .verifyPin(pin);
          switch (check) {
            case PinAccepted():
              if (context.mounted) Navigator.of(context).pop(pin);
              return null;
            case PinRejected(:final attemptsLeft, :final pausedUntil):
              if (pausedUntil != null) {
                return _pauseMessage(ref, pausedUntil);
              }
              return 'Неверный PIN. До паузы осталось попыток: $attemptsLeft';
            case PinPaused(:final until):
              return _pauseMessage(ref, until);
          }
        },
      ),
    );
  }

  String _pauseMessage(WidgetRef ref, DateTime until) {
    final left = until.difference(ref.read(clockProvider)());
    return 'Слишком много попыток. Повторите через ${pauseText(left)}';
  }
}
