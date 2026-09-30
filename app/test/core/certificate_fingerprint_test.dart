import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';

import '../support/pem.dart';

String wrap(String label, List<int> der, {String eol = '\n'}) {
  final b64 = base64.encode(der);
  final lines = [
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  return '-----BEGIN $label-----$eol${lines.join(eol)}$eol'
      '-----END $label-----$eol';
}

void main() {
  final der = fakeDer();
  final canonical = fakePem();

  test('ofDer считает SHA-256 (вектор для "abc")', () {
    expect(
      CertificateFingerprint.ofDer('abc'.codeUnits),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  group('строгий разбор PEM', () {
    test('канонический вход проходит и совпадает с собой', () {
      expect(CertificateFingerprint.pemToDer(canonical), der);
      expect(CertificateFingerprint.canonicalize(canonical), canonical);
      expect(CertificateFingerprint.isCanonical(canonical), isTrue);
      expect(CertificateFingerprint.ofPem(canonical), fakeFingerprint());
    });

    test('CRLF, пробелы вокруг и внутри принимаются и канонизируются', () {
      final crlf = wrap('CERTIFICATE', der, eol: '\r\n');
      expect(CertificateFingerprint.canonicalize(crlf), canonical);
      expect(CertificateFingerprint.isCanonical(crlf), isFalse);
      expect(
        CertificateFingerprint.canonicalize('  \n\t$canonical \r\n'),
        canonical,
      );
      expect(
        CertificateFingerprint.canonicalize(
          canonical.replaceFirst('MA4w', 'MA4 w'),
        ),
        canonical,
      );
    });

    test('длинный DER разбивается по 64 символа', () {
      // 300 байт содержимого во внутренней последовательности tbs.
      final body = List<int>.filled(300, 7);
      final tbs = [0x30, 0x82, 0x01, 0x2C, ...body];
      final tail = [0x30, 0x03, 0x06, 0x01, 0x2A, 0x03, 0x02, 0x00, 0x01];
      final inner = [...tbs, ...tail];
      final big = [
        0x30,
        0x82,
        inner.length >> 8,
        inner.length & 0xFF,
        ...inner,
      ];
      final pem = CertificateFingerprint.pemFromDer(big);
      expect(pem.split('\n').every((l) => l.length <= 64), isTrue);
      expect(CertificateFingerprint.canonicalize(pem), pem);
    });

    test('лишний блок X509 CERTIFICATE (обход сверки) отвергается', () {
      final evil = fakeDer(0x01);
      final bypass = canonical + wrap('X509 CERTIFICATE', evil);
      expect(CertificateFingerprint.pemToDer(bypass), isNull);
      expect(CertificateFingerprint.canonicalize(bypass), isNull);
      expect(CertificateFingerprint.ofPem(bypass), isNull);
      expect(CertificateFingerprint.isCanonical(bypass), isFalse);
    });

    test('метка TRUSTED CERTIFICATE и X509 CERTIFICATE сами по себе', () {
      expect(
        CertificateFingerprint.canonicalize(wrap('TRUSTED CERTIFICATE', der)),
        isNull,
      );
      expect(
        CertificateFingerprint.canonicalize(wrap('X509 CERTIFICATE', der)),
        isNull,
      );
      expect(
        CertificateFingerprint.canonicalize(wrap('PRIVATE KEY', der)),
        isNull,
      );
    });

    test('два блока CERTIFICATE отвергаются', () {
      expect(
        CertificateFingerprint.canonicalize(canonical + fakePem(0x02)),
        isNull,
      );
      expect(
        CertificateFingerprint.canonicalize(canonical + canonical),
        isNull,
      );
    });

    test('посторонний текст до, после и внутри отвергается', () {
      expect(CertificateFingerprint.canonicalize('junk\n$canonical'), isNull);
      expect(CertificateFingerprint.canonicalize('$canonical\njunk'), isNull);
      expect(CertificateFingerprint.canonicalize('$canonical-----'), isNull);
      expect(
        CertificateFingerprint.canonicalize(
          canonical.replaceFirst('MA4w', 'MA4*'),
        ),
        isNull,
      );
      expect(
        CertificateFingerprint.canonicalize('# comment\n$canonical'),
        isNull,
      );
    });

    test('не X.509 и битый base64 отвергаются', () {
      expect(CertificateFingerprint.canonicalize(''), isNull);
      expect(CertificateFingerprint.canonicalize('hello'), isNull);
      expect(
        CertificateFingerprint.canonicalize(
          '-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----',
        ),
        isNull,
      );
      // Валидный base64, но не структура сертификата.
      expect(
        CertificateFingerprint.canonicalize(wrap('CERTIFICATE', [1, 2, 3, 4])),
        isNull,
      );
      // Ошибка base64.
      expect(
        CertificateFingerprint.canonicalize(
          '-----BEGIN CERTIFICATE-----\nA=A=\n-----END CERTIFICATE-----',
        ),
        isNull,
      );
      // Ненормализованный хвост base64: те же байты, другая запись.
      final b64 = base64.encode(der);
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      final idx = b64.indexOf('=');
      final last = alphabet.indexOf(b64[idx - 1]);
      final tampered =
          b64.substring(0, idx - 1) + alphabet[last ^ 1] + b64.substring(idx);
      expect(
        CertificateFingerprint.canonicalize(
          '-----BEGIN CERTIFICATE-----\n$tampered\n-----END CERTIFICATE-----',
        ),
        isNull,
      );
    });

    test('структура DER: лишние байты, короткая длина, неверные теги', () {
      String pemOf(List<int> d) => wrap('CERTIFICATE', d);
      final good = fakeDer();
      expect(CertificateFingerprint.canonicalize(pemOf([...good, 0])), isNull);
      expect(
        CertificateFingerprint.canonicalize(pemOf(good.sublist(0, 10))),
        isNull,
      );
      // Внешний тег не SEQUENCE.
      expect(
        CertificateFingerprint.canonicalize(pemOf([0x31, ...good.sublist(1)])),
        isNull,
      );
      // Пустой tbsCertificate.
      expect(
        CertificateFingerprint.canonicalize(
          pemOf([0x30, 0x07, 0x30, 0x00, 0x30, 0x00, 0x03, 0x01, 0x00]),
        ),
        isNull,
      );
      // Третий элемент не BIT STRING.
      final wrongTag = [...good]..[12] = 0x04;
      expect(CertificateFingerprint.canonicalize(pemOf(wrongTag)), isNull);
      // Длинная форма длины с недопустимым числом байтов.
      expect(
        CertificateFingerprint.canonicalize(pemOf([0x30, 0x85, 1, 2, 3, 4, 5])),
        isNull,
      );
      expect(
        CertificateFingerprint.canonicalize(pemOf([0x30, 0x80, 0, 0])),
        isNull,
      );
      // Вложенный элемент выходит за пределы контейнера.
      expect(
        CertificateFingerprint.canonicalize(
          pemOf([
            0x30,
            0x0E,
            0x30,
            0x7F,
            0x02,
            0x01,
            0x01,
            0x30,
            0x03,
            0x06,
            0x01,
            0x2A,
            0x03,
            0x02,
            0x00,
            0xAB,
          ]),
        ),
        isNull,
      );
    });
  });

  test('format: AA:BB:… в верхнем регистре', () {
    expect(CertificateFingerprint.format('0aff10'), '0A:FF:10');
    expect(
      CertificateFingerprint.format(fakeFingerprint()).split(':'),
      hasLength(32),
    );
  });
}
