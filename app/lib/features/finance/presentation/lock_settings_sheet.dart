import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_text_field.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/pin_lock_service.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Приватность раздела: «Скрыть суммы» и замок PIN (+ биометрия, если она
/// доступна). Только клиент: сервер ничего об этом не знает.
Future<void> showLockSettings(BuildContext context) =>
    showEditorSheet<void>(context, builder: (_) => const LockSettingsSheet());

enum _Mode { menu, set, change, remove }

class LockSettingsSheet extends ConsumerStatefulWidget {
  const LockSettingsSheet({super.key});

  @override
  ConsumerState<LockSettingsSheet> createState() => _LockSettingsSheetState();
}

class _LockSettingsSheetState extends ConsumerState<LockSettingsSheet> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  _Mode _mode = _Mode.menu;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _go(_Mode mode) => setState(() {
    _mode = mode;
    _error = null;
    _current.clear();
    _next.clear();
    _repeat.clear();
  });

  String? _newPinProblem() {
    final bad = PinLockService.problem(_next.text);
    if (bad != null) return bad;
    if (_next.text != _repeat.text) return 'PIN-коды не совпадают';
    return null;
  }

  String _unlockMessage(UnlockResult result) => switch (result) {
    UnlockResult.wrong => 'Неверный текущий PIN',
    UnlockResult.blocked => 'Слишком много попыток: подождите и повторите',
    UnlockResult.unlocked => '',
  };

  Future<void> _apply() async {
    if (_busy) return;
    final notifier = ref.read(financeLockProvider.notifier);
    final bad = _mode == _Mode.remove ? null : _newPinProblem();
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    switch (_mode) {
      case _Mode.set:
        await notifier.setPin(_next.text);
        if (mounted) _go(_Mode.menu);
      case _Mode.change:
        final r = await notifier.changePin(_current.text, _next.text);
        if (!mounted) return;
        if (r == UnlockResult.unlocked) {
          _go(_Mode.menu);
        } else {
          setState(() => _error = _unlockMessage(r));
        }
      case _Mode.remove:
        final r = await notifier.removePin(_current.text);
        if (!mounted) return;
        if (r == UnlockResult.unlocked) {
          _go(_Mode.menu);
        } else {
          setState(() => _error = _unlockMessage(r));
        }
      case _Mode.menu:
        break;
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _pinField(String key, TextEditingController controller, String hint) =>
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.s2),
        child: AppTextField(
          key: Key(key),
          controller: controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(PinLockService.maxLength),
          ],
          decoration: InputDecoration(hintText: hint),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final lock = ref.watch(financeLockProvider);
    final hidden = ref.watch(hideAmountsProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Приватность раздела'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: _mode == _Mode.menu
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchListTile(
                          key: const Key('privacy-hide'),
                          contentPadding: EdgeInsets.zero,
                          title: Text('Скрыть суммы', style: t.body),
                          subtitle: Text(
                            'Суммы показываются как «•••». Только на этом '
                            'устройстве.',
                            style: t.caption.copyWith(color: c.textSecondary),
                          ),
                          value: hidden,
                          onChanged: (v) => ref
                              .read(hideAmountsProvider.notifier)
                              .set(hidden: v),
                        ),
                        const Divider(),
                        if (!lock.hasPin)
                          ListTile(
                            key: const Key('privacy-enable'),
                            contentPadding: EdgeInsets.zero,
                            title: Text('Включить PIN-замок', style: t.body),
                            subtitle: Text(
                              'Раздел закрывается при выходе из приложения.',
                              style: t.caption.copyWith(color: c.textSecondary),
                            ),
                            onTap: () => _go(_Mode.set),
                          )
                        else ...[
                          ListTile(
                            key: const Key('privacy-change'),
                            contentPadding: EdgeInsets.zero,
                            title: Text('Сменить PIN', style: t.body),
                            onTap: () => _go(_Mode.change),
                          ),
                          if (lock.biometricAvailable)
                            SwitchListTile(
                              key: const Key('privacy-biometric'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                'Открывать биометрией',
                                style: t.body,
                              ),
                              value: lock.biometric,
                              onChanged: (v) => ref
                                  .read(financeLockProvider.notifier)
                                  .setBiometric(enabled: v),
                            ),
                          ListTile(
                            key: const Key('privacy-disable'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Отключить замок',
                              style: t.body.copyWith(color: c.danger),
                            ),
                            onTap: () => _go(_Mode.remove),
                          ),
                          ListTile(
                            key: const Key('privacy-lock-now'),
                            contentPadding: EdgeInsets.zero,
                            title: Text('Закрыть раздел сейчас', style: t.body),
                            onTap: () {
                              // Сначала закрываем свой лист: замок сам
                              // закрывает окна поверх раздела.
                              Navigator.of(context).pop();
                              ref.read(financeLockProvider.notifier).lock();
                            },
                          ),
                        ],
                        const SizedBox(height: AppSpacing.s4),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(switch (_mode) {
                          _Mode.set => 'Придумайте PIN: от 4 до 8 цифр.',
                          _Mode.change => 'Введите текущий и новый PIN.',
                          _ => 'Введите текущий PIN, чтобы отключить замок.',
                        }, style: t.bodyS.copyWith(color: c.textSecondary)),
                        const SizedBox(height: AppSpacing.s3),
                        if (_mode != _Mode.set)
                          _pinField('privacy-current', _current, 'Текущий PIN'),
                        if (_mode != _Mode.remove) ...[
                          _pinField('privacy-new', _next, 'Новый PIN'),
                          _pinField('privacy-repeat', _repeat, 'Повторите PIN'),
                        ],
                        if (_error != null)
                          FormError(_error!, key: const Key('privacy-error')),
                        Row(
                          children: [
                            TextButton(
                              key: const Key('privacy-back'),
                              onPressed: () => _go(_Mode.menu),
                              child: const Text('Назад'),
                            ),
                            const Spacer(),
                            FilledButton(
                              key: const Key('privacy-apply'),
                              onPressed: _busy ? null : _apply,
                              child: const Text('Готово'),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.s4),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
