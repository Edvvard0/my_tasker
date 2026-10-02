import 'dart:io' show TlsException;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';
import 'package:my_tasker/core/network/pinned_http_client.dart';
import 'package:my_tasker/core/network/server_url.dart';
import 'package:my_tasker/features/settings/application/server_connection_controller.dart';

/// Фабрика адаптера с закреплением УЦ (в тестах подменяется).
final pinnedAdapterFactoryProvider = Provider<PinnedAdapterFactory>(
  (ref) => defaultPinnedAdapterFactory,
);

/// Адаптер для `http://localhost` в debug.
final plainAdapterFactoryProvider = Provider<HttpClientAdapter Function()>(
  (ref) => createPlainAdapter,
);

/// Делегирует запросы сессии входа. Ленивое чтение разрывает цикл
/// провайдеров: сессии нужен клиент (для refresh), клиенту — сессия.
class _LazyTokens implements AccessTokenProvider {
  _LazyTokens(this._ref);

  final Ref _ref;

  AccessTokenProvider get _auth => _ref.read(authControllerProvider.notifier);

  @override
  Future<String?> currentAccessToken() => _auth.currentAccessToken();

  @override
  Future<String?> refreshAfterUnauthorized(String? usedToken) =>
      _auth.refreshAfterUnauthorized(usedToken);

  @override
  Future<void> onDeviceRevoked(String code) => _auth.onDeviceRevoked(code);
}

/// Клиент API после загрузки настроек сервера.
///
/// [apiClientProvider] читает настройки синхронно (`.value`), а при холодном
/// старте (в том числе в фоновом изоляте WorkManager) они ещё грузятся из БД,
/// и клиент был бы `null`. Любой код, который может выполниться до первого
/// кадра интерфейса (синхронизация, refresh, SSE), берёт клиент отсюда:
/// сначала дожидается настроек. Сбой чтения настроек = сервер не настроен.
Future<ApiClient?> resolveApiClient(Ref ref) async {
  try {
    await ref.read(serverConnectionSettingsProvider.future);
  } on Object {
    return null;
  }
  final client = ref.read(apiClientProvider);
  return client;
}

/// [resolveApiClient] в виде провайдера: для кода вне провайдеров (тесты,
/// фоновый изолят).
final apiClientResolverProvider = Provider<Future<ApiClient?> Function()>(
  (ref) =>
      () => resolveApiClient(ref),
);

/// Клиент API для настроенного сервера или `null`, если адрес не задан,
/// некорректен либо для `https` нет закреплённого сертификата.
final apiClientProvider = Provider<ApiClient?>((ref) {
  final settings = ref.watch(serverConnectionSettingsProvider).value;
  final url = settings?.url;
  if (url == null) return null;
  final config = ref.watch(appConfigProvider);
  final parsed = parseServerUrl(
    url,
    allowInsecureLocalhost: config.allowInsecureLocalhost,
  );
  if (parsed is! ValidServerUrl) return null;
  final observer = PinObserver();
  final HttpClientAdapter adapter;
  if (parsed.isHttps) {
    final pem = settings?.caPem;
    if (pem == null || !CertificateFingerprint.isCanonical(pem)) return null;
    try {
      adapter = ref.watch(pinnedAdapterFactoryProvider)(pem, observer);
    } on TlsException {
      return null;
    }
  } else {
    adapter = ref.watch(plainAdapterFactoryProvider)();
  }
  final client = ApiClient(
    dio: ApiClient.createDio(baseUrl: parsed.uri, adapter: adapter),
    schemaVersion: config.clientSchemaVersion,
    tokens: _LazyTokens(ref),
    observer: observer,
  );
  ref.onDispose(client.close);
  return client;
});
