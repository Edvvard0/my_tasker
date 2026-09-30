import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/core/network/server_url.dart';
import 'package:my_tasker/core/network/trust_on_first_use.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_text_field.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/settings/application/server_connection_controller.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';
import 'package:my_tasker/features/settings/presentation/server_form_validation.dart';

/// «Настройки › Сервер»: адрес API и закреплённый корневой сертификат УЦ.
///
/// Порядок первой настройки: ввести адрес -> «Получить сертификат сервера»
/// (один запрос без проверки, trust-on-first-use) -> сверить показанный
/// отпечаток с тем, что напечатан на сервере -> «Доверять». Только после
/// подтверждения PEM сохраняется. Смена адреса сбрасывает закрепление.
class ServerConnectionScreen extends ConsumerStatefulWidget {
  const ServerConnectionScreen({this.backLocation = '/settings', super.key});

  /// Куда ведёт стрелка «назад» (с экрана входа — `/login`).
  final String backLocation;

  @override
  ConsumerState<ServerConnectionScreen> createState() =>
      _ServerConnectionScreenState();
}

class _ServerConnectionScreenState
    extends ConsumerState<ServerConnectionScreen> {
  final _url = TextEditingController();
  final _pem = TextEditingController();

  /// Закреплённый УЦ и адрес, к которому он относится.
  String? _pinnedPem;
  String? _pinnedUrl;

  /// Полученный, но ещё не подтверждённый сертификат и его адрес.
  FetchedRootCa? _pending;
  String? _pendingUrl;
  bool _fetching = false;
  RootCaFetchError? _fetchError;
  bool _manual = false;
  String? _urlError;
  String? _pemError;
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    _url.addListener(_syncPin);
    ref.listenManual(serverConnectionSettingsProvider, (_, next) {
      final saved = next.value;
      if (saved == null || _prefilled) return;
      _prefilled = true;
      _pinnedUrl = saved.url;
      // Не каноническая запись в БД — недоверенная: считаем, что УЦ не задан.
      final pem = saved.caPem;
      _pinnedPem = pem != null && CertificateFingerprint.isCanonical(pem)
          ? pem
          : null;
      _url.text = saved.url ?? '';
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _url
      ..removeListener(_syncPin)
      ..dispose();
    _pem.dispose();
    super.dispose();
  }

  bool get _allowHttp => ref.read(appConfigProvider).allowInsecureLocalhost;

  String? _normalizedUrl() {
    final parsed = parseServerUrl(
      _url.text,
      allowInsecureLocalhost: _allowHttp,
    );
    return parsed is ValidServerUrl ? parsed.toString() : null;
  }

  /// Смена адреса сбрасывает закреплённый и ожидающий сертификаты.
  void _syncPin() {
    final url = _normalizedUrl();
    final dropPin = _pinnedPem != null && url != _pinnedUrl;
    final dropPending = _pending != null && url != _pendingUrl;
    if (dropPin || dropPending) {
      setState(() {
        if (dropPin) {
          _pinnedPem = null;
          _pinnedUrl = null;
        }
        if (dropPending) {
          _pending = null;
          _pendingUrl = null;
        }
      });
      ref.read(connectionCheckProvider.notifier).reset();
    }
  }

  ValidServerUrl? _validUrl() {
    final result = validateServerUrl(
      _url.text,
      allowInsecureLocalhost: _allowHttp,
    );
    setState(() => _urlError = result.error);
    return result.url;
  }

  Future<void> _fetchCa() async {
    final url = _validUrl();
    if (url == null) return;
    setState(() {
      _fetching = true;
      _fetchError = null;
      _pending = null;
      _pemError = null;
    });
    try {
      final fetched = await ref.read(rootCaFetcherProvider)(url.uri);
      if (!mounted) return;
      setState(() {
        _pending = fetched;
        _pendingUrl = url.toString();
      });
    } on RootCaFetchException catch (e) {
      if (mounted) setState(() => _fetchError = e.error);
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  void _usePastedPem() {
    final url = _validUrl();
    if (url == null) return;
    // Строго: ровно один сертификат; сохраняется каноническая запись.
    final canonical = CertificateFingerprint.canonicalize(_pem.text);
    if (canonical == null) {
      setState(() => _pemError = pemInvalidText);
      return;
    }
    setState(() {
      _pemError = null;
      _fetchError = null;
      _pending = FetchedRootCa(
        pem: canonical,
        fingerprint: CertificateFingerprint.ofPem(canonical)!,
      );
      _pendingUrl = url.toString();
    });
  }

  Future<void> _confirm() async {
    final pending = _pending;
    final url = _validUrl();
    if (pending == null || url == null) return;
    await ref
        .read(serverConnectionRepositoryProvider)
        .save(
          ServerConnectionSettings(url: url.toString(), caPem: pending.pem),
        );
    ref.invalidate(serverConnectionSettingsProvider);
    if (!mounted) return;
    setState(() {
      _pinnedPem = pending.pem;
      _pinnedUrl = url.toString();
      _pending = null;
      _pendingUrl = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Сертификат сервера закреплён')),
    );
  }

  /// Отмена не трогает уже закреплённый УЦ: он заменяется только
  /// подтверждением нового.
  void _cancelPending() => setState(() {
    _pending = null;
    _pendingUrl = null;
  });

  Future<void> _save() async {
    final url = _validUrl();
    if (url == null) return;
    final keepPin = _pinnedUrl == url.toString() ? _pinnedPem : null;
    await ref
        .read(serverConnectionRepositoryProvider)
        .save(ServerConnectionSettings(url: url.toString(), caPem: keepPin));
    ref.invalidate(serverConnectionSettingsProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Настройки сервера сохранены')),
    );
  }

  Future<void> _check() async {
    final url = _validUrl();
    if (url == null) return;
    await ref
        .read(connectionCheckProvider.notifier)
        .check(
          url: url.toString(),
          caPem: _pinnedUrl == url.toString() ? _pinnedPem : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    final saved = ref.watch(serverConnectionSettingsProvider);
    final check = ref.watch(connectionCheckProvider);
    final checking = check is ConnectionChecking;

    return ScreenScaffold(
      title: 'Сервер',
      parentLabel: widget.backLocation == '/settings' ? 'Настройки' : 'Вход',
      onBack: () => context.go(widget.backLocation),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(
                check: check,
                fetching: _fetching,
                fetchError: _fetchError,
                pending: _pending,
                pinnedPem: _pinnedPem,
                notConfigured:
                    saved.hasValue && !saved.requireValue.isConfigured,
                onConfirm: _confirm,
                onCancel: _cancelPending,
              ),
              const SizedBox(height: AppSpacing.s6),
              _LabeledField(
                label: 'Адрес сервера',
                child: AppTextField(
                  key: const Key('server-url-field'),
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: t.numM,
                  decoration: InputDecoration(
                    hintText: 'https://203.0.113.10',
                    errorText: _urlError,
                    errorMaxLines: 3,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              Wrap(
                spacing: AppSpacing.s3,
                runSpacing: AppSpacing.s2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton(
                    key: const Key('fetch-ca-button'),
                    onPressed: _fetching || checking ? null : _fetchCa,
                    child: const Text('Получить сертификат сервера'),
                  ),
                  TextButton(
                    key: const Key('manual-pem-toggle'),
                    onPressed: () => setState(() => _manual = !_manual),
                    child: Text(
                      _manual ? 'Скрыть ввод PEM' : 'Вставить PEM вручную',
                    ),
                  ),
                ],
              ),
              if (_manual) ...[
                const SizedBox(height: AppSpacing.s3),
                _LabeledField(
                  label: 'Корневой сертификат (PEM)',
                  hint: 'Файл root.crt с сервера целиком',
                  child: AppTextField(
                    key: const Key('pem-field'),
                    controller: _pem,
                    autocorrect: false,
                    enableSuggestions: false,
                    minLines: 4,
                    maxLines: 8,
                    style: t.numS,
                    decoration: InputDecoration(
                      hintText: '-----BEGIN CERTIFICATE-----',
                      errorText: _pemError,
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ElevatedButton(
                    key: const Key('use-pem-button'),
                    onPressed: _usePastedPem,
                    child: const Text('Показать отпечаток'),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.s6),
              Wrap(
                spacing: AppSpacing.s3,
                runSpacing: AppSpacing.s3,
                children: [
                  FilledButton(
                    key: const Key('save-button'),
                    onPressed: checking ? null : _save,
                    child: const Text('Сохранить адрес'),
                  ),
                  ElevatedButton(
                    key: const Key('check-button'),
                    onPressed: checking ? null : _check,
                    child: checking
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              key: const Key('check-progress'),
                              strokeWidth: 2,
                              color: c.textSecondary,
                            ),
                          )
                        : const Text('Проверить соединение'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child, this.hint});

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

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.check,
    required this.fetching,
    required this.fetchError,
    required this.pending,
    required this.pinnedPem,
    required this.notConfigured,
    required this.onConfirm,
    required this.onCancel,
  });

  final ConnectionCheckState check;
  final bool fetching;
  final RootCaFetchError? fetchError;
  final FetchedRootCa? pending;
  final String? pinnedPem;
  final bool notConfigured;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final Widget content;
    if (fetching) {
      content = const _Message(
        pill: StatusPill(label: 'Получаем сертификат', tone: StatusTone.info),
        text: 'Запрашиваем корневой сертификат у сервера…',
      );
    } else if (pending != null) {
      content = _PendingCa(
        ca: pending!,
        onConfirm: onConfirm,
        onCancel: onCancel,
      );
    } else if (fetchError != null) {
      content = _fetchErrorMessage(fetchError!);
    } else if (check is ConnectionDone) {
      content = _resultMessage((check as ConnectionDone).result);
    } else if (check is ConnectionChecking) {
      content = const _Message(
        pill: StatusPill(label: 'Проверяем', tone: StatusTone.info),
        text: 'Обращаемся к серверу…',
      );
    } else if (pinnedPem != null) {
      content = _Message(
        pill: const StatusPill(
          label: 'Сертификат закреплён',
          tone: StatusTone.success,
        ),
        text:
            'Приложение доверяет только этому корневому сертификату. '
            'Нажми «Проверить соединение», чтобы убедиться, что сервер '
            'отвечает.',
        fingerprint: CertificateFingerprint.ofPem(pinnedPem!),
      );
    } else if (notConfigured) {
      content = const EmptyState(
        icon: LucideIcons.server,
        title: 'Сервер не настроен',
        message:
            'Укажи адрес сервера и получи его сертификат: приложение будет '
            'доверять только ему.',
      );
    } else {
      content = const _Message(
        pill: StatusPill(label: 'Не закреплён', tone: StatusTone.neutral),
        text: 'Получи сертификат сервера и подтверди его отпечаток.',
      );
    }

    return Container(
      key: const Key('connection-status'),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: AppRadii.borderL,
      ),
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: content,
    );
  }

  Widget _fetchErrorMessage(RootCaFetchError error) => switch (error) {
    RootCaFetchError.unreachable => const _Message(
      pill: StatusPill(label: 'Сервер недоступен', tone: StatusTone.danger),
      text:
          'Не удалось получить сертификат. Проверь адрес и что сервер '
          'запущен и доступен из сети.',
    ),
    RootCaFetchError.badResponse => const _Message(
      pill: StatusPill(label: 'Нет сертификата', tone: StatusTone.danger),
      text:
          'Сервер не отдал корневой сертификат. Вставь его вручную из файла '
          'root.crt на сервере.',
    ),
    RootCaFetchError.invalidCertificate => const _Message(
      pill: StatusPill(
        label: 'Сертификат не разобран',
        tone: StatusTone.danger,
      ),
      text:
          'В ответе нет корректного сертификата. Вставь его вручную из '
          'файла root.crt на сервере.',
    ),
  };

  Widget _resultMessage(ConnectionResult result) => switch (result.outcome) {
    ConnectionOutcome.ok => _Message(
      pill: const StatusPill(
        label: 'Соединение установлено',
        tone: StatusTone.success,
      ),
      text: [
        if (result.serverVersion != null)
          'Сервер отвечает, версия ${result.serverVersion!.appVersion}.'
        else
          'Сервер отвечает.',
        if (result.clientOutdated)
          'Сервер требует более новую версию приложения — обнови его.',
      ].join(' '),
      warning: result.clientOutdated,
    ),
    ConnectionOutcome.unreachable => const _Message(
      pill: StatusPill(label: 'Сервер недоступен', tone: StatusTone.danger),
      text:
          'Не удалось подключиться. Проверь адрес и что сервер запущен и '
          'доступен из сети.',
    ),
    ConnectionOutcome.notReady => const _Message(
      pill: StatusPill(label: 'Сервер не готов', tone: StatusTone.warning),
      text: 'Сервер отвечает, но пока не готов к работе. Попробуй позже.',
    ),
    ConnectionOutcome.certMismatch => const _Message(
      pill: StatusPill(label: 'Сертификат не совпал', tone: StatusTone.danger),
      text:
          'Сервер предъявил сертификат, выпущенный не закреплённым '
          'корневым УЦ. Если сервер переустанавливали, получи сертификат '
          'заново и сверь отпечаток.',
    ),
    ConnectionOutcome.invalidSettings => _Message(
      pill: const StatusPill(label: 'Не проверено', tone: StatusTone.neutral),
      text: result.caInvalid
          ? 'Сначала закрепи сертификат сервера: получи его и подтверди '
                'отпечаток.'
          : 'Исправь адрес и проверь снова.',
    ),
  };
}

class _PendingCa extends StatelessWidget {
  const _PendingCa({
    required this.ca,
    required this.onConfirm,
    required this.onCancel,
  });

  final FetchedRootCa ca;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StatusPill(label: 'Сверь отпечаток', tone: StatusTone.warning),
        const SizedBox(height: AppSpacing.s2),
        Text(
          'Сравни отпечаток с тем, что выводит команда из deploy/README.md '
          'на сервере. Если хоть один символ отличается — не доверяй.',
          style: t.body.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s3),
        SelectableText(
          CertificateFingerprint.format(ca.fingerprint),
          key: const Key('ca-fingerprint'),
          style: t.numS,
        ),
        const SizedBox(height: AppSpacing.s4),
        Wrap(
          spacing: AppSpacing.s3,
          runSpacing: AppSpacing.s2,
          children: [
            FilledButton(
              key: const Key('confirm-ca-button'),
              onPressed: onConfirm,
              child: const Text('Отпечаток совпадает — доверять'),
            ),
            TextButton(
              key: const Key('cancel-ca-button'),
              onPressed: onCancel,
              child: const Text('Отмена'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.pill,
    required this.text,
    this.warning = false,
    this.fingerprint,
  });

  final StatusPill pill;
  final String text;
  final bool warning;
  final String? fingerprint;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(alignment: Alignment.centerLeft, child: pill),
        const SizedBox(height: AppSpacing.s2),
        Text(
          text,
          style: t.body.copyWith(
            color: warning ? c.textPrimary : c.textSecondary,
          ),
        ),
        if (fingerprint != null) ...[
          const SizedBox(height: AppSpacing.s2),
          SelectableText(
            CertificateFingerprint.format(fingerprint!),
            key: const Key('pinned-fingerprint'),
            style: t.numS.copyWith(color: c.textTertiary),
          ),
        ],
      ],
    );
  }
}
