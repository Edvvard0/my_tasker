import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/auth/device_info_source.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_text_field.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/auth/presentation/login_error_text.dart';
import 'package:my_tasker/features/settings/application/server_connection_controller.dart';

/// Экран входа: пароль, код из приложения-аутентификатора, имя устройства.
///
/// Сервер должен быть настроен заранее (адрес и закреплённый сертификат из
/// «Настройки › Сервер»). После выхода или отзыва устройства локальные
/// данные остаются — вход возвращает к ним же.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _device = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  ApiException? _error;
  String? _passwordError;
  String? _codeError;
  String? _deviceError;

  @override
  void initState() {
    super.initState();
    _device.text = ref.read(deviceInfoSourceProvider).defaultName;
  }

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    _device.dispose();
    super.dispose();
  }

  bool _validate() {
    final name = _device.text.trim();
    setState(() {
      _passwordError = _password.text.isEmpty ? 'Введи пароль' : null;
      _codeError = RegExp(r'^\d{6}$').hasMatch(_code.text)
          ? null
          : 'Введи 6 цифр из приложения-аутентификатора';
      _deviceError = name.isEmpty || name.length > 64
          ? 'Название — от 1 до 64 символов'
          : null;
    });
    return _passwordError == null && _codeError == null && _deviceError == null;
  }

  Future<void> _submit() async {
    if (_busy || !_validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final info = ref.read(deviceInfoSourceProvider);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .login(
            password: _password.text,
            totpCode: _code.text,
            device: DeviceInfo(
              name: _device.text.trim(),
              platform: info.platform,
              appVersion: ref.read(appConfigProvider).appVersion,
            ),
          );
      // Роутер сам уводит с экрана входа, когда состояние стало SignedIn.
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          // Пароль и код после неудачи вводят заново (код одноразовый).
          _code.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(serverConnectionSettingsProvider);
    final auth = ref.watch(authControllerProvider);
    final configured = settings.value?.isConfigured ?? false;
    final loaded = settings.hasValue;
    return Scaffold(
      body: ScreenScaffold(
        title: 'Вход',
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: !loaded
                ? const SizedBox(height: 120)
                : !configured
                ? _NotConfigured(onSetup: () => context.go('/setup/server'))
                : _form(context, settings.requireValue.url!, auth),
          ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context, String url, AuthState auth) {
    final t = context.text;
    final c = context.colors;
    final reason = auth is SignedOut ? auth.reason : SignOutReason.none;
    final info = ref.watch(deviceInfoSourceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reason != SignOutReason.none) ...[
          _ReasonNotice(reason: reason),
          const SizedBox(height: AppSpacing.s4),
        ],
        if (_error != null) ...[
          NoticeCard(
            key: const Key('login-error'),
            label: _error!.isNetwork ? 'Нет сети' : 'Не удалось войти',
            tone: StatusTone.danger,
            text: loginErrorText(_error!),
            details: _error!.code,
          ),
          const SizedBox(height: AppSpacing.s4),
        ],
        AppCard(
          child: Row(
            children: [
              Icon(LucideIcons.server, size: 20, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Сервер',
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                    Text(
                      url,
                      key: const Key('login-server-url'),
                      style: t.numM,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('login-change-server'),
                onPressed: _busy ? null : () => context.go('/setup/server'),
                child: const Text('Изменить'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s6),
        _Labeled(
          label: 'Пароль',
          child: AppTextField(
            key: const Key('login-password'),
            controller: _password,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: !_showPassword,
            decoration: InputDecoration(
              errorText: _passwordError,
              suffixIcon: IconButton(
                key: const Key('login-toggle-password'),
                tooltip: _showPassword ? 'Скрыть пароль' : 'Показать пароль',
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword ? LucideIcons.eyeOff : LucideIcons.eye,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        _Labeled(
          label: 'Код из приложения-аутентификатора',
          child: AppTextField(
            key: const Key('login-code'),
            controller: _code,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            style: t.numM,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: InputDecoration(
              hintText: '000000',
              errorText: _codeError,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        _Labeled(
          label: 'Название устройства',
          hint: 'Платформа: ${info.platformLabel}',
          child: AppTextField(
            key: const Key('login-device'),
            controller: _device,
            decoration: InputDecoration(errorText: _deviceError),
          ),
        ),
        const SizedBox(height: AppSpacing.s6),
        FilledButton(
          key: const Key('login-submit'),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    key: const Key('login-progress'),
                    strokeWidth: 2,
                    color: c.textSecondary,
                  ),
                )
              : const Text('Войти'),
        ),
      ],
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured({required this.onSetup});

  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: LucideIcons.server,
    title: 'Сервер не настроен',
    message:
        'Чтобы войти, укажи адрес сервера и закрепи его сертификат — '
        'приложение будет доверять только ему.',
    action: FilledButton(
      key: const Key('login-setup-server'),
      onPressed: onSetup,
      child: const Text('Настроить сервер'),
    ),
  );
}

class _ReasonNotice extends StatelessWidget {
  const _ReasonNotice({required this.reason});

  final SignOutReason reason;

  @override
  Widget build(BuildContext context) {
    final (label, text) = switch (reason) {
      SignOutReason.revoked => (
        'Устройство отозвано',
        'Это устройство отозвали с другого устройства. Войди снова — '
            'данные на телефоне сохранены.',
      ),
      SignOutReason.refreshReuse => (
        'Сессия завершена',
        'Сервер увидел повторное использование ключа входа и на всякий '
            'случай завершил сессию. Войди снова — данные сохранены.',
      ),
      SignOutReason.expired => (
        'Сессия истекла',
        'Вход давно не обновлялся. Войди снова — данные сохранены.',
      ),
      SignOutReason.loggedOut => (
        'Вы вышли',
        'Локальные данные остались на устройстве и снова будут '
            'синхронизироваться после входа.',
      ),
      SignOutReason.none => ('', ''),
    };
    return NoticeCard(
      key: const Key('login-reason'),
      label: label,
      tone: StatusTone.warning,
      text: text,
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child, this.hint});

  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: t.bodyS.copyWith(color: c.textSecondary)),
        const SizedBox(height: AppSpacing.s1),
        child,
        if (hint != null) ...[
          const SizedBox(height: AppSpacing.s1),
          Text(hint!, style: t.caption.copyWith(color: c.textTertiary)),
        ],
      ],
    );
  }
}
