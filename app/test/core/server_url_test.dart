import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/server_url.dart';

void main() {
  ServerUrlResult parse(String s, {bool debug = false}) =>
      parseServerUrl(s, allowInsecureLocalhost: debug);

  ServerUrlError? errorOf(String s, {bool debug = false}) {
    final r = parse(s, debug: debug);
    return r is InvalidServerUrl ? r.error : null;
  }

  test('https по IP принимается и нормализуется', () {
    final r = parse('  https://203.0.113.10/ ') as ValidServerUrl;
    expect(r.uri.toString(), 'https://203.0.113.10');
    expect(r.isHttps, isTrue);
    expect(r.toString(), 'https://203.0.113.10');
  });

  test('порт сохраняется, хост-имя допускается', () {
    final r = parse('https://example.test:8443') as ValidServerUrl;
    expect(r.uri.toString(), 'https://example.test:8443');
  });

  test('IPv6 в скобках', () {
    final r = parse('https://[2001:db8::1]:8443') as ValidServerUrl;
    expect(r.uri.host, '2001:db8::1');
    expect(r.uri.port, 8443);
  });

  test('пустой ввод', () {
    expect(errorOf(''), ServerUrlError.empty);
    expect(errorOf('   '), ServerUrlError.empty);
  });

  test('без схемы или с чужой схемой — invalid', () {
    expect(errorOf('203.0.113.10'), ServerUrlError.invalid);
    expect(errorOf('ftp://203.0.113.10'), ServerUrlError.invalid);
    expect(errorOf('https://'), ServerUrlError.invalid);
    expect(errorOf('https://[bad'), ServerUrlError.invalid);
  });

  test('plain http отклоняется', () {
    expect(errorOf('http://203.0.113.10'), ServerUrlError.insecureScheme);
    expect(errorOf('http://localhost'), ServerUrlError.insecureScheme);
    // В debug: только localhost, чужие хосты по-прежнему нельзя.
    expect(
      errorOf('http://203.0.113.10', debug: true),
      ServerUrlError.insecureScheme,
    );
  });

  test('http://localhost разрешён только в debug', () {
    for (final host in ['localhost', '127.0.0.1', '[::1]']) {
      final r = parse('http://$host:8080', debug: true);
      expect(r, isA<ValidServerUrl>(), reason: host);
      expect((r as ValidServerUrl).isHttps, isFalse);
    }
  });

  test('логин/пароль, путь, query и fragment не допускаются', () {
    expect(
      errorOf('https://user:pw@203.0.113.10'),
      ServerUrlError.credentialsNotAllowed,
    );
    expect(errorOf('https://203.0.113.10/api'), ServerUrlError.unexpectedPath);
    expect(errorOf('https://203.0.113.10?x=1'), ServerUrlError.unexpectedPath);
    expect(errorOf('https://203.0.113.10#top'), ServerUrlError.unexpectedPath);
  });
}
