import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/core/network/server_url.dart';

import '../support/fake_adapter.dart';

void main() {
  // Структурно корректный PEM (содержимое не важно: сеть подменена).
  const pem =
      '-----BEGIN CERTIFICATE-----\nAAECAwQ=\n-----END CERTIFICATE-----\n';
  const versionJson = {
    'app_version': '0.1.0',
    'api_schema_version': 1,
    'min_client_schema_version': 1,
  };

  ConnectionChecker checkerWith(
    FakeAdapter adapter, {
    bool debug = false,
    int clientSchema = 1,
    void Function(String pem)? onPin,
  }) => ConnectionChecker(
    config: AppConfig(
      allowInsecureLocalhost: debug,
      clientSchemaVersion: clientSchema,
    ),
    adapterFactory: (p, observer) {
      onPin?.call(p);
      return adapter;
    },
    plainAdapterFactory: () => adapter,
  );

  test('200 + /version -> ok с версией сервера', () async {
    final adapter = FakeAdapter({
      'GET /health/ready': const FakeResponse(200, {'status': 'ok'}),
      'GET /version': const FakeResponse(200, versionJson),
    });
    String? usedPem;
    final result = await checkerWith(
      adapter,
      onPin: (p) => usedPem = p,
    ).check(url: 'https://203.0.113.10', caPem: pem);

    expect(result.outcome, ConnectionOutcome.ok);
    expect(result.isOk, isTrue);
    expect(result.serverVersion?.appVersion, '0.1.0');
    expect(result.serverVersion?.apiSchemaVersion, 1);
    expect(result.clientOutdated, isFalse);
    expect(usedPem, pem);
    expect(adapter.requested, ['GET /health/ready', 'GET /version']);
  });

  test('сервер требует более новую схему клиента -> clientOutdated', () async {
    final adapter = FakeAdapter({
      'GET /health/ready': const FakeResponse(200, {'status': 'ok'}),
      'GET /version': const FakeResponse(200, {
        'app_version': '0.1.0',
        'api_schema_version': 2,
        'min_client_schema_version': 2,
      }),
    });
    final result = await checkerWith(adapter)
        .check(url: 'https://203.0.113.10', caPem: pem);
    expect(result.outcome, ConnectionOutcome.ok);
    expect(result.clientOutdated, isTrue);
  });

  test('ready=200, но /version недоступен -> всё равно ok', () async {
    final adapter = FakeAdapter({
      'GET /health/ready': const FakeResponse(200, {'status': 'ok'}),
      'GET /version': const FakeResponse(500),
    });
    final result = await checkerWith(adapter)
        .check(url: 'https://203.0.113.10', caPem: pem);
    expect(result.outcome, ConnectionOutcome.ok);
    expect(result.serverVersion, isNull);
  });

  test('/version с мусором -> ok без версии', () async {
    final adapter = FakeAdapter({
      'GET /health/ready': const FakeResponse(200, {'status': 'ok'}),
      'GET /version': const FakeResponse(200, {'oops': true}),
    });
    final result = await checkerWith(adapter)
        .check(url: 'https://203.0.113.10', caPem: pem);
    expect(result.outcome, ConnectionOutcome.ok);
    expect(result.serverVersion, isNull);
  });

  test('503 -> notReady', () async {
    final adapter = FakeAdapter({
      'GET /health/ready': const FakeResponse(503, {
        'status': 'unavailable',
        'reason': 'db',
      }),
    });
    final result = await checkerWith(adapter)
        .check(url: 'https://203.0.113.10', caPem: pem);
    expect(result.outcome, ConnectionOutcome.notReady);
    expect(adapter.requested, ['GET /health/ready']);
  });

  test('обрыв соединения -> unreachable', () async {
    final adapter = FakeAdapter({}, error: connectionError);
    final result = await checkerWith(adapter)
        .check(url: 'https://203.0.113.10', caPem: pem);
    expect(result.outcome, ConnectionOutcome.unreachable);
  });

  test('таймаут -> unreachable', () async {
    final adapter = FakeAdapter(
      {},
      error: (o) => DioException.connectionTimeout(
        timeout: const Duration(seconds: 1),
        requestOptions: o,
      ),
    );
    final result = await checkerWith(adapter)
        .check(url: 'https://203.0.113.10', caPem: pem);
    expect(result.outcome, ConnectionOutcome.unreachable);
  });

  test('отметка mismatch от адаптера -> certMismatch', () async {
    late final ConnectionChecker checker;
    final adapter = FakeAdapter({}, error: connectionError);
    checker = ConnectionChecker(
      config: const AppConfig(allowInsecureLocalhost: false),
      adapterFactory: (p, observer) {
        return FakeAdapter(
          {},
          error: connectionError,
          beforeError: () => observer.mismatchDetected = true,
        );
      },
    );
    final result = await checker.check(url: 'https://203.0.113.10', caPem: pem);
    expect(result.outcome, ConnectionOutcome.certMismatch);
    expect(adapter.requested, isEmpty);
  });

  test('некорректный адрес -> invalidSettings, сеть не трогаем', () async {
    final adapter = FakeAdapter({});
    final result = await checkerWith(adapter)
        .check(url: 'http://203.0.113.10', caPem: pem);
    expect(result.outcome, ConnectionOutcome.invalidSettings);
    expect(result.urlError, ServerUrlError.insecureScheme);
    expect(adapter.requested, isEmpty);
  });

  test('некорректный отпечаток для https -> invalidSettings', () async {
    final adapter = FakeAdapter({});
    final result = await checkerWith(adapter)
        .check(url: 'https://203.0.113.10', caPem: 'nope');
    expect(result.outcome, ConnectionOutcome.invalidSettings);
    expect(result.caInvalid, isTrue);
    expect(adapter.requested, isEmpty);
  });

  test('http://localhost в debug идёт без закрепления', () async {
    final adapter = FakeAdapter({
      'GET /health/ready': const FakeResponse(200, {'status': 'ok'}),
      'GET /version': const FakeResponse(200, versionJson),
    });
    var pinnedUsed = false;
    final result = await checkerWith(
      adapter,
      debug: true,
      onPin: (_) => pinnedUsed = true,
    ).check(url: 'http://localhost:8000', caPem: null);
    expect(result.outcome, ConnectionOutcome.ok);
    expect(pinnedUsed, isFalse);
  });

  test('AppConfig.forBuild: в тестах (debug) http://localhost разрешён', () {
    expect(AppConfig.forBuild().allowInsecureLocalhost, isTrue);
  });
}
