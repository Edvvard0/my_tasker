import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';

String pemOf(List<int> der) {
  final b64 = base64.encode(der);
  final lines = [
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
      '-----END CERTIFICATE-----\n';
}

void main() {
  // SHA-256("abc") — стандартный тестовый вектор.
  const abcHash =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
  final abc = 'abc'.codeUnits;

  test('ofDer считает SHA-256', () {
    expect(CertificateFingerprint.ofDer(abc), abcHash);
  });

  group('PEM', () {
    test('pemToDer и ofPem', () {
      final pem = pemOf(abc);
      expect(CertificateFingerprint.pemToDer(pem), abc);
      expect(CertificateFingerprint.ofPem(pem), abcHash);
    });

    test('переносы строк Windows и пробелы допустимы', () {
      final pem = pemOf(abc).replaceAll('\n', '\r\n');
      expect(CertificateFingerprint.ofPem(pem), abcHash);
      expect(CertificateFingerprint.ofPem('  \n${pemOf(abc)}  '), abcHash);
    });

    test('некорректный ввод -> null', () {
      expect(CertificateFingerprint.pemToDer(''), isNull);
      expect(CertificateFingerprint.pemToDer('hello'), isNull);
      expect(
        CertificateFingerprint.pemToDer(
          '-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----',
        ),
        isNull,
      );
      // Ошибка base64 (некорректное дополнение).
      expect(
        CertificateFingerprint.pemToDer(
          '-----BEGIN CERTIFICATE-----\nA=A=\n-----END CERTIFICATE-----',
        ),
        isNull,
      );
      expect(CertificateFingerprint.ofPem('x'), isNull);
    });

    test('два сертификата в одном PEM отвергаются', () {
      expect(CertificateFingerprint.pemToDer(pemOf(abc) + pemOf(abc)), isNull);
    });
  });

  test('format: AA:BB:… в верхнем регистре', () {
    expect(CertificateFingerprint.format('0aff10'), '0A:FF:10');
    expect(CertificateFingerprint.format(abcHash).split(':'), hasLength(32));
  });
}
