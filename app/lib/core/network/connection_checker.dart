import 'dart:io' show TlsException;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';
import 'package:my_tasker/core/network/pinned_http_client.dart';
import 'package:my_tasker/core/network/server_api.dart';
import 'package:my_tasker/core/network/server_url.dart';

/// Итог проверки соединения с сервером.
enum ConnectionOutcome {
  /// `GET /health/ready` вернул 200.
  ok,

  /// Сервер не отвечает (нет сети, таймаут, отказ соединения).
  unreachable,

  /// Сервер отвечает, но не готов (503 и т. п.).
  notReady,

  /// Сервер предъявил цепочку, не выпущенную закреплённым корневым УЦ.
  certMismatch,

  /// Адрес или сертификат УЦ некорректны — запрос не выполнялся.
  invalidSettings,
}

@immutable
class ConnectionResult {
  const ConnectionResult(
    this.outcome, {
    this.serverVersion,
    this.clientOutdated = false,
    this.urlError,
    this.caInvalid = false,
  });

  final ConnectionOutcome outcome;

  /// Версия сервера (если `GET /version` удался).
  final ServerVersion? serverVersion;

  /// Сервер требует более новую схему клиента (`min_client_schema_version`).
  final bool clientOutdated;

  /// Ошибка адреса при [ConnectionOutcome.invalidSettings].
  final ServerUrlError? urlError;

  /// PEM закреплённого УЦ не разобран при [ConnectionOutcome.invalidSettings].
  final bool caInvalid;

  bool get isOk => outcome == ConnectionOutcome.ok;
}

/// Проверяет соединение с сервером: `GET /health/ready` с доверием только
/// закреплённому корневому УЦ, затем `GET /version` (необязательно).
class ConnectionChecker {
  ConnectionChecker({
    required this.config,
    this.adapterFactory = defaultPinnedAdapterFactory,
    this.plainAdapterFactory = createPlainAdapter,
    this.timeout = const Duration(seconds: 6),
  });

  final AppConfig config;
  final PinnedAdapterFactory adapterFactory;
  final HttpClientAdapter Function() plainAdapterFactory;
  final Duration timeout;

  Future<ConnectionResult> check({
    required String url,
    required String? caPem,
  }) async {
    final parsed = parseServerUrl(
      url,
      allowInsecureLocalhost: config.allowInsecureLocalhost,
    );
    if (parsed is InvalidServerUrl) {
      return ConnectionResult(
        ConnectionOutcome.invalidSettings,
        urlError: parsed.error,
      );
    }
    final serverUrl = parsed as ValidServerUrl;

    final observer = PinObserver();
    late final HttpClientAdapter adapter;
    if (serverUrl.isHttps) {
      final pem = caPem;
      if (pem == null || !CertificateFingerprint.isCanonical(pem)) {
        return const ConnectionResult(
          ConnectionOutcome.invalidSettings,
          caInvalid: true,
        );
      }
      try {
        adapter = adapterFactory(pem, observer);
      } on TlsException {
        return const ConnectionResult(
          ConnectionOutcome.invalidSettings,
          caInvalid: true,
        );
      }
    } else {
      // http://localhost в debug: закреплять нечего.
      adapter = plainAdapterFactory();
    }

    final api = ServerApi.create(
      baseUrl: serverUrl.uri,
      adapter: adapter,
      timeout: timeout,
    );
    try {
      final ready = await api.isReady();
      if (!ready) return const ConnectionResult(ConnectionOutcome.notReady);
      return await _withVersion(api);
    } on DioException {
      return ConnectionResult(
        observer.mismatchDetected
            ? ConnectionOutcome.certMismatch
            : ConnectionOutcome.unreachable,
      );
    } finally {
      api.close();
    }
  }

  Future<ConnectionResult> _withVersion(ServerApi api) async {
    try {
      final version = await api.version();
      return ConnectionResult(
        ConnectionOutcome.ok,
        serverVersion: version,
        clientOutdated:
            version.minClientSchemaVersion > config.clientSchemaVersion,
      );
    } on Object {
      // Версия — справочная информация; готовность сервера уже подтверждена.
      return const ConnectionResult(ConnectionOutcome.ok);
    }
  }
}

final connectionCheckerProvider = Provider<ConnectionChecker>(
  (ref) => ConnectionChecker(config: ref.watch(appConfigProvider)),
);
