import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/server_url.dart';
import 'package:my_tasker/features/settings/presentation/server_form_validation.dart';

void main() {
  ServerUrlValidation v(String url, {bool debug = false}) =>
      validateServerUrl(url, allowInsecureLocalhost: debug);

  test('корректный адрес нормализуется', () {
    final r = v(' https://203.0.113.10/ ');
    expect(r.isValid, isTrue);
    expect(r.url.toString(), 'https://203.0.113.10');
    expect(r.error, isNull);
  });

  test('пустой адрес', () {
    final r = v('');
    expect(r.isValid, isFalse);
    expect(r.error, serverUrlErrorText(ServerUrlError.empty));
  });

  test('http вне debug — ошибка про https', () {
    expect(
      v('http://localhost:8000').error,
      serverUrlErrorText(ServerUrlError.insecureScheme),
    );
  });

  test('http://localhost в debug принимается', () {
    expect(v('http://localhost:8000', debug: true).isValid, isTrue);
  });

  test('у каждой причины есть человеческий текст', () {
    for (final e in ServerUrlError.values) {
      expect(serverUrlErrorText(e), isNotEmpty, reason: e.name);
    }
    expect(pemInvalidText, contains('PEM'));
  });
}
