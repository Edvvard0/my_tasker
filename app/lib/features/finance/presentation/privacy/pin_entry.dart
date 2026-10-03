import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_motion.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';

/// Ввод PIN: заголовок, точки, подсказка/ошибка и цифровая клавиатура.
///
/// Если [length] задана (экран разблокировки знает длину PIN), код уходит в
/// [onSubmit] сам, как только набрана последняя цифра. Иначе (создание PIN)
/// набирают 4–6 цифр и жмут «Далее». [onSubmit] возвращает текст ошибки
/// (`null` — принято): при ошибке точки трясутся, поле очищается.
class PinEntry extends StatefulWidget {
  const PinEntry({
    required this.title,
    required this.onSubmit,
    this.length,
    this.message,
    this.messageIsError = false,
    this.enabled = true,
    this.onBiometric,
    this.submitLabel = 'Далее',
    super.key,
  });

  final String title;

  /// Фиксированная длина PIN или `null` — 4–6 цифр с кнопкой [submitLabel].
  final int? length;

  /// Подсказка под точками (или ошибка, если [messageIsError]).
  final String? message;
  final bool messageIsError;

  /// Ввод разрешён (пауза после неверных попыток выключает).
  final bool enabled;
  final Future<String?> Function(String pin) onSubmit;

  /// Кнопка биометрии слева внизу клавиатуры; `null` — кнопки нет.
  final VoidCallback? onBiometric;
  final String submitLabel;

  @override
  State<PinEntry> createState() => _PinEntryState();
}

class _PinEntryState extends State<PinEntry>
    with SingleTickerProviderStateMixin {
  String _digits = '';
  String? _error;
  bool _busy = false;
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: AppMotion.enter,
  );

  int get _max => widget.length ?? pinMaxLength;

  @override
  void didUpdateWidget(PinEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Пауза кончилась: разовая ошибка о ней больше не актуальна.
    if (widget.enabled && !oldWidget.enabled) _error = null;
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  bool get _canType => widget.enabled && !_busy;

  void _digit(String d) {
    if (!_canType || _digits.length >= _max) return;
    setState(() {
      _digits += d;
      _error = null;
    });
    if (widget.length != null && _digits.length == widget.length) {
      unawaited(_submit());
    }
  }

  void _backspace() {
    if (!_canType || _digits.isEmpty) return;
    setState(() {
      _digits = _digits.substring(0, _digits.length - 1);
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (!_canType) return;
    final pin = _digits;
    if (widget.length == null && !isValidPin(pin)) return;
    setState(() => _busy = true);
    final error = await widget.onSubmit(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _digits = '';
      _error = error;
    });
    if (error != null) {
      await _shake.forward(from: 0);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final digit = _digitOf(key);
    if (digit != null) {
      _digit(digit);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (widget.length == null) unawaited(_submit());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static String? _digitOf(LogicalKeyboardKey key) {
    const row = [
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    const pad = [
      LogicalKeyboardKey.numpad0,
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7,
      LogicalKeyboardKey.numpad8,
      LogicalKeyboardKey.numpad9,
    ];
    final i = row.indexOf(key);
    if (i >= 0) return '$i';
    final j = pad.indexOf(key);
    return j >= 0 ? '$j' : null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    // Сообщение родителя (пауза с обратным отсчётом) важнее разовой ошибки.
    final message = widget.message ?? _error;
    final isError = widget.message != null
        ? widget.messageIsError
        : _error != null;
    final dots = widget.length ?? math.max(pinMinLength, _digits.length);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              key: const Key('pin-title'),
              textAlign: TextAlign.center,
              style: t.h3,
            ),
            const SizedBox(height: AppSpacing.s4),
            AnimatedBuilder(
              animation: _shake,
              builder: (_, child) => Transform.translate(
                offset: Offset(
                  math.sin(_shake.value * math.pi * 6) *
                      (1 - _shake.value) *
                      12,
                  0,
                ),
                child: child,
              ),
              child: Semantics(
                label: 'Введено цифр: ${_digits.length}',
                child: Row(
                  key: const Key('pin-dots'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < dots; i++)
                      Container(
                        key: Key('pin-dot-$i'),
                        width: 14,
                        height: 14,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _digits.length
                              ? (isError ? c.danger : c.textPrimary)
                              : Colors.transparent,
                          border: Border.all(
                            color: isError ? c.danger : c.borderStrong,
                            width: 1.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                child: message == null
                    ? null
                    : Semantics(
                        liveRegion: true,
                        child: Text(
                          message,
                          key: const Key('pin-message'),
                          textAlign: TextAlign.center,
                          style: t.bodyS.copyWith(
                            color: isError ? c.danger : c.textSecondary,
                          ),
                        ),
                      ),
              ),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [for (final d in row) _key(d)],
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.onBiometric != null)
                  _PadButton(
                    key: const Key('pin-biometric'),
                    semantic: 'Разблокировать биометрией',
                    onTap: widget.enabled ? widget.onBiometric : null,
                    child: Icon(
                      LucideIcons.fingerprintPattern,
                      size: 26,
                      color: c.textPrimary,
                    ),
                  )
                else
                  const SizedBox(width: _PadButton.size + 16),
                _key('0'),
                _PadButton(
                  key: const Key('pin-backspace'),
                  semantic: 'Стереть цифру',
                  onTap: _canType ? _backspace : null,
                  child: Icon(
                    LucideIcons.delete,
                    size: 26,
                    color: c.textPrimary,
                  ),
                ),
              ],
            ),
            if (widget.length == null) ...[
              const SizedBox(height: AppSpacing.s4),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('pin-submit'),
                  onPressed: _canType && isValidPin(_digits) ? _submit : null,
                  child: Text(widget.submitLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _key(String d) => _PadButton(
    key: Key('pin-key-$d'),
    semantic: d,
    onTap: _canType ? () => _digit(d) : null,
    child: Text(d, style: context.text.h2),
  );
}

class _PadButton extends StatelessWidget {
  const _PadButton({
    required this.child,
    required this.onTap,
    required this.semantic,
    super.key,
  });

  static const double size = 64;

  final Widget child;
  final VoidCallback? onTap;
  final String semantic;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s2),
      child: Semantics(
        button: true,
        label: semantic,
        excludeSemantics: true,
        child: Material(
          color: c.surface3,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            borderRadius: AppRadii.borderFull,
            onTap: onTap,
            child: Opacity(
              opacity: onTap == null ? 0.4 : 1,
              child: SizedBox(
                width: size,
                height: size,
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
