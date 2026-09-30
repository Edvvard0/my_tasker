@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/core/network/pinned_http_client.dart';
import 'package:my_tasker/core/network/trust_on_first_use.dart';

import '../support/pem.dart';
import '../support/tls_fixtures.dart';

/// Настоящий TLS: openssl-CA, листья с IP SAN 127.0.0.1, локальный сервер.
/// Без `openssl` тесты пропускаются (в CI он есть).
void main() {
  late Directory dir;
  var hasOpenssl = false;
  late TestCa ca;
  late TestCa otherCa;
  late TestLeaf leafA;
  late TestLeaf leafB;
  late TestLeaf wrongSan;
  late TestLeaf otherCaLeaf;

  setUpAll(() async {
    // TestWidgetsFlutterBinding подменяет HttpClient заглушкой (400).
    HttpOverrides.global = null;
    hasOpenssl = await TestCa.opensslAvailable;
    if (!hasOpenssl) return;
    dir = await Directory.systemTemp.createTemp('pin_test');
    ca = await TestCa.create(dir, 'ca');
    otherCa = await TestCa.create(dir, 'other');
    leafA = await ca.issueLeaf('a', 'IP:127.0.0.1');
    leafB = await ca.issueLeaf('b', 'IP:127.0.0.1,DNS:localhost');
    wrongSan = await ca.issueLeaf('wrong', 'IP:10.0.0.1');
    otherCaLeaf = await otherCa.issueLeaf('x', 'IP:127.0.0.1');
  });

  tearDownAll(() async {
    if (hasOpenssl) await dir.delete(recursive: true);
  });

  ConnectionChecker checker() => ConnectionChecker(
    config: const AppConfig(allowInsecureLocalhost: false),
    timeout: const Duration(seconds: 5),
  );

  Future<ConnectionResult> checkAgainst(
    TestLeaf leaf,
    String pinnedPem, {
    String? servedCa,
  }) async {
    final server = await TestTlsServer.start(leaf, caPem: servedCa ?? ca.pem);
    addTearDown(server.close);
    return await checker().check(url: server.url.toString(), caPem: pinnedPem);
  }

  group('закрепление корневого УЦ (настоящий TLS)', () {
    test('лист выпущен закреплённым УЦ -> ok и версия сервера', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final r = await checkAgainst(leafA, ca.pem);
      expect(r.outcome, ConnectionOutcome.ok);
      expect(r.serverVersion?.appVersion, '9.9.9');
    });

    test('ротация листа: два разных листа одного УЦ проходят', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      expect((await checkAgainst(leafA, ca.pem)).outcome, ConnectionOutcome.ok);
      expect((await checkAgainst(leafB, ca.pem)).outcome, ConnectionOutcome.ok);
    });

    test('другой УЦ выпустил лист -> certMismatch', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final r = await checkAgainst(otherCaLeaf, ca.pem);
      expect(r.outcome, ConnectionOutcome.certMismatch);
    });

    test('лист нашего УЦ, но SAN не на 127.0.0.1 -> certMismatch', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final r = await checkAgainst(wrongSan, ca.pem);
      expect(r.outcome, ConnectionOutcome.certMismatch);
    });

    test('закреплён чужой УЦ, сервер от нашего -> certMismatch', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final r = await checkAgainst(leafA, otherCa.pem);
      expect(r.outcome, ConnectionOutcome.certMismatch);
    });

    test(
      'наблюдатель фиксирует отвергнутый сертификат, колбэк всегда false',
      () async {
        if (!hasOpenssl) return markTestSkipped('нет openssl');
        final server = await TestTlsServer.start(otherCaLeaf, caPem: ca.pem);
        addTearDown(server.close);
        final observer = PinObserver();
        final client = createPinnedHttpClient(ca.pem, observer: observer);
        addTearDown(client.close);
        await expectLater(
          client.getUrl(server.url.replace(path: '/version')),
          throwsA(isA<HandshakeException>()),
        );
        expect(observer.mismatchDetected, isTrue);
        expect(observer.lastSeenFingerprint, hasLength(64));
      },
    );

    test('порт без сервера -> unreachable (не certMismatch)', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final r = await checker().check(
        url: 'https://127.0.0.1:$port',
        caPem: ca.pem,
      );
      expect(r.outcome, ConnectionOutcome.unreachable);
    });

    test('без закреплённого УЦ или с мусором -> invalidSettings', () async {
      final noPin = await checker().check(
        url: 'https://127.0.0.1:1',
        caPem: null,
      );
      expect(noPin.outcome, ConnectionOutcome.invalidSettings);
      expect(noPin.caInvalid, isTrue);
      final junk = await checker().check(
        url: 'https://127.0.0.1:1',
        caPem: 'not a pem',
      );
      expect(junk.caInvalid, isTrue);
    });

    test('структурно валидный, но не настоящий сертификат -> ошибка', () async {
      expect(
        () => createPinnedHttpClient(fakePem()),
        throwsA(isA<TlsException>()),
      );
      final r = await checker().check(
        url: 'https://127.0.0.1:1',
        caPem: fakePem(),
      );
      expect(r.isOk, isFalse);
    });

    test('неканоническая запись не принимается клиентом', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final crlf = ca.pem.replaceAll('\n', '\r\n');
      expect(() => createPinnedHttpClient(crlf), throwsA(isA<ArgumentError>()));
      final r = await checkAgainst(leafA, crlf);
      expect(r.outcome, ConnectionOutcome.invalidSettings);
      expect(r.caInvalid, isTrue);
    });

    test('обход сверки: доп. блок X509 CERTIFICATE не доверяется', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      // В БД лежит настоящий УЦ + чужой УЦ под другой меткой. Показанный
      // отпечаток был бы настоящим, а доверялось бы и чужому.
      final evilBlock = otherCa.pem.replaceAll(
        'CERTIFICATE',
        'X509 CERTIFICATE',
      );
      final combined = ca.pem + evilBlock;
      expect(CertificateFingerprint.canonicalize(combined), isNull);
      final r = await checkAgainst(otherCaLeaf, combined);
      expect(r.outcome, ConnectionOutcome.invalidSettings);
    });

    test('два сертификата в одном файле отвергаются при вставке', () {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      expect(CertificateFingerprint.canonicalize(ca.pem + otherCa.pem), isNull);
      expect(
        CertificateFingerprint.canonicalize(
          ca.pem.replaceAll('CERTIFICATE', 'TRUSTED CERTIFICATE'),
        ),
        isNull,
      );
    });
  });

  group('trust-on-first-use: fetchRootCaTrustOnFirstUse', () {
    test('получает PEM и считает отпечаток (сервер с любым листом)', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      // Лист чужого УЦ: TOFU не проверяет цепочку.
      final server = await TestTlsServer.start(otherCaLeaf, caPem: ca.pem);
      addTearDown(server.close);
      final fetched = await fetchRootCaTrustOnFirstUse(server.url);
      expect(fetched.fingerprint, ca.fingerprint);
      expect(fetched.pem.trim(), ca.pem.trim());
    });

    test('полученный УЦ затем закрепляет соединение', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final server = await TestTlsServer.start(leafA, caPem: ca.pem);
      addTearDown(server.close);
      final fetched = await fetchRootCaTrustOnFirstUse(server.url);
      final r = await checker().check(
        url: server.url.toString(),
        caPem: fetched.pem,
      );
      expect(r.outcome, ConnectionOutcome.ok);
    });

    test('404 -> badResponse', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final server = await TestTlsServer.start(
        leafA,
        caPem: ca.pem,
        caStatus: 404,
      );
      addTearDown(server.close);
      await expectLater(
        fetchRootCaTrustOnFirstUse(server.url),
        throwsA(
          isA<RootCaFetchException>().having(
            (e) => e.error,
            'error',
            RootCaFetchError.badResponse,
          ),
        ),
      );
    });

    test('мусор вместо PEM -> invalidCertificate', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final server = await TestTlsServer.start(
        leafA,
        caPem: ca.pem,
        caBody: 'hello',
      );
      addTearDown(server.close);
      await expectLater(
        fetchRootCaTrustOnFirstUse(server.url),
        throwsA(
          isA<RootCaFetchException>().having(
            (e) => e.error,
            'error',
            RootCaFetchError.invalidCertificate,
          ),
        ),
      );
    });

    test('слишком большое тело -> badResponse', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final server = await TestTlsServer.start(
        leafA,
        caPem: ca.pem,
        caBody: 'A' * (70 * 1024),
      );
      addTearDown(server.close);
      await expectLater(
        fetchRootCaTrustOnFirstUse(server.url),
        throwsA(isA<RootCaFetchException>()),
      );
    });

    test('медленный сервер: общий дедлайн, а не по событиям', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final server = await TestTlsServer.start(
        leafA,
        caPem: ca.pem,
        slowDrip: true,
      );
      addTearDown(server.close);
      final watch = Stopwatch()..start();
      await expectLater(
        fetchRootCaTrustOnFirstUse(
          server.url,
          deadline: const Duration(milliseconds: 800),
        ),
        throwsA(
          isA<RootCaFetchException>().having(
            (e) => e.error,
            'error',
            RootCaFetchError.unreachable,
          ),
        ),
      );
      expect(watch.elapsedMilliseconds, lessThan(3000));
    });

    test('лишний блок в ответе сервера -> invalidCertificate', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final server = await TestTlsServer.start(
        leafA,
        caPem: ca.pem,
        caBody:
            ca.pem + otherCa.pem.replaceAll('CERTIFICATE', 'X509 CERTIFICATE'),
      );
      addTearDown(server.close);
      await expectLater(
        fetchRootCaTrustOnFirstUse(server.url),
        throwsA(
          isA<RootCaFetchException>().having(
            (e) => e.error,
            'error',
            RootCaFetchError.invalidCertificate,
          ),
        ),
      );
    });

    test('CRLF в ответе канонизируется', () async {
      if (!hasOpenssl) return markTestSkipped('нет openssl');
      final server = await TestTlsServer.start(
        leafA,
        caPem: ca.pem,
        caBody: ca.pem.replaceAll('\n', '\r\n'),
      );
      addTearDown(server.close);
      final fetched = await fetchRootCaTrustOnFirstUse(server.url);
      expect(fetched.pem, ca.pem);
    });

    test('порт без сервера -> unreachable', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      await expectLater(
        fetchRootCaTrustOnFirstUse(Uri.parse('https://127.0.0.1:$port')),
        throwsA(
          isA<RootCaFetchException>().having(
            (e) => e.error,
            'error',
            RootCaFetchError.unreachable,
          ),
        ),
      );
      expect(
        const RootCaFetchException(RootCaFetchError.unreachable).toString(),
        contains('unreachable'),
      );
    });
  });

  test('createPlainAdapter и defaultPinnedAdapterFactory создаются', () async {
    if (!hasOpenssl) return markTestSkipped('нет openssl');
    expect(createPlainAdapter(), isNotNull);
    expect(defaultPinnedAdapterFactory(ca.pem, PinObserver()), isNotNull);
  });
}
