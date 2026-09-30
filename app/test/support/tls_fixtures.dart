import 'dart:async';
import 'dart:io';

import 'package:my_tasker/core/network/certificate_fingerprint.dart';

/// Тестовый корневой УЦ, созданный `openssl` во временном каталоге.
/// Закрытые ключи в репозиторий не попадают.
class TestCa {
  TestCa._(this.dir, this.name, this.pem);

  final Directory dir;
  final String name;

  /// PEM корневого сертификата.
  final String pem;

  String get fingerprint => CertificateFingerprint.ofPem(pem)!;

  static Future<bool> get opensslAvailable async {
    try {
      return (await Process.run('openssl', ['version'])).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  static Future<void> _run(List<String> args) async {
    final r = await Process.run('openssl', args);
    if (r.exitCode != 0) throw StateError('openssl ${args.first}: ${r.stderr}');
  }

  static Future<TestCa> create(Directory dir, String name) async {
    await _run([
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:prime256v1', //
      '-nodes',
      '-keyout',
      '${dir.path}/$name.key',
      '-out',
      '${dir.path}/$name.pem',
      '-days', '2', '-subj', '/CN=Test CA $name',
      '-addext', 'basicConstraints=critical,CA:TRUE',
      '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
    ]);
    final raw = File('${dir.path}/$name.pem').readAsStringSync();
    return TestCa._(dir, name, CertificateFingerprint.canonicalize(raw)!);
  }

  /// Выпускает листовой сертификат с заданными SAN (например `IP:127.0.0.1`).
  Future<TestLeaf> issueLeaf(String id, String san) async {
    final base = '${dir.path}/$name-$id';
    File('$base.ext').writeAsStringSync(
      'subjectAltName=$san\nbasicConstraints=CA:FALSE\n'
      'keyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n',
    );
    await _run([
      'req', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', //
      '-nodes',
      '-keyout',
      '$base.key',
      '-out',
      '$base.csr',
      '-subj',
      '/CN=leaf-$id',
    ]);
    await _run([
      'x509', '-req', '-in', '$base.csr', '-CA', '${dir.path}/$name.pem', //
      '-CAkey', '${dir.path}/$name.key', '-CAcreateserial', '-out', '$base.pem',
      '-days', '2', '-extfile', '$base.ext',
    ]);
    return TestLeaf('$base.pem', '$base.key');
  }
}

class TestLeaf {
  const TestLeaf(this.certPath, this.keyPath);

  final String certPath;
  final String keyPath;
}

/// HTTPS-сервер бэкенда: `/health/ready`, `/version`, `/ca/root.crt`.
class TestTlsServer {
  TestTlsServer._(this.server);

  final HttpServer server;
  int get port => server.port;
  Uri get url => Uri.parse('https://127.0.0.1:$port');

  static Future<TestTlsServer> start(
    TestLeaf leaf, {
    required String caPem,
    int caStatus = 200,
    String? caBody,
    bool slowDrip = false,
  }) async {
    final context = SecurityContext()
      ..useCertificateChain(leaf.certPath)
      ..usePrivateKey(leaf.keyPath);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    unawaited(
      server.forEach((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/health/ready':
            response
              ..headers.contentType = ContentType.json
              ..write('{"status":"ok"}');
          case '/version':
            response
              ..headers.contentType = ContentType.json
              ..write(
                '{"app_version":"9.9.9","api_schema_version":1,'
                '"min_client_schema_version":1}',
              );
          case '/ca/root.crt' when slowDrip:
            // По байту каждые 30 мс, пока клиент не оборвёт соединение.
            try {
              while (true) {
                response.write('-');
                await response.flush();
                await Future<void>.delayed(const Duration(milliseconds: 30));
              }
            } on Object {
              return;
            }
          case '/ca/root.crt':
            response
              ..statusCode = caStatus
              ..headers.contentType = ContentType(
                'application',
                'x-x509-ca-cert',
              )
              ..write(caBody ?? caPem);
          default:
            response.statusCode = 404;
        }
        await response.close();
      }),
    );
    return TestTlsServer._(server);
  }

  Future<void> close() => server.close(force: true);
}
