import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Работа с корневым сертификатом (PEM) и его SHA-256 отпечатком.
///
/// Безопасность закрепления держится на одном правиле: то, что показано
/// пользователю для сверки, и то, чему клиент потом доверяет, — один и тот
/// же сертификат. Поэтому вход разбирается **строго**, а в БД и в
/// `SecurityContext` попадает только каноническая перекодировка.
abstract final class CertificateFingerprint {
  /// Ровно один блок `CERTIFICATE`, кроме пробелов вокруг — ничего.
  /// Блоки с другими метками (`X509 CERTIFICATE`, `TRUSTED CERTIFICATE`…)
  /// и любой посторонний текст не проходят.
  static final RegExp _strictPem = RegExp(
    r'^-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\t\r\n ]*)-----END CERTIFICATE-----$',
  );
  static final RegExp _pemWhitespace = RegExp(r'[ \t\r\n]');

  /// Разбирает [input] строго; возвращает DER или `null`.
  static Uint8List? pemToDer(String input) {
    final match = _strictPem.firstMatch(
      input.replaceAll(RegExp(r'^[ \t\r\n]+|[ \t\r\n]+$'), ''),
    );
    if (match == null) return null;
    final body = match.group(1)!.replaceAll(_pemWhitespace, '');
    final Uint8List der;
    try {
      der = base64.decode(body);
    } on FormatException {
      return null;
    }
    // Ровно та же строка при обратной перекодировке: без «мусорных» хвостов
    // и ненормализованных символов.
    if (base64.encode(der) != body) return null;
    return _looksLikeX509(der) ? der : null;
  }

  /// Каноническая запись: `BEGIN CERTIFICATE`, строки по 64 символа, `\n`,
  /// завершающий перевод строки.
  static String pemFromDer(List<int> der) {
    final b64 = base64.encode(der);
    final lines = [
      for (var i = 0; i < b64.length; i += 64)
        b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
    ];
    return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
        '-----END CERTIFICATE-----\n';
  }

  /// Строгий разбор + каноническая перекодировка; `null`, если вход не
  /// ровно один корректный сертификат. Только результат можно хранить и
  /// передавать в TLS-контекст.
  static String? canonicalize(String input) {
    final der = pemToDer(input);
    return der == null ? null : pemFromDer(der);
  }

  /// [pem] уже в каноническом виде (иначе ему доверять нельзя).
  static bool isCanonical(String pem) => canonicalize(pem) == pem;

  /// SHA-256 от DER-представления сертификата (строчный hex, 64 символа).
  static String ofDer(List<int> der) => sha256.convert(der).toString();

  /// Отпечаток PEM-сертификата или `null`, если PEM не проходит строгий разбор.
  static String? ofPem(String pem) {
    final der = pemToDer(pem);
    return der == null ? null : ofDer(der);
  }

  /// `AA:BB:…` для показа пользователю (как печатает `openssl`).
  static String format(String hex) {
    final upper = hex.toUpperCase();
    return [
      for (var i = 0; i + 2 <= upper.length; i += 2) upper.substring(i, i + 2),
    ].join(':');
  }

  // --- минимальная проверка структуры X.509 (DER) --------------------------

  /// `Certificate ::= SEQUENCE { tbsCertificate SEQUENCE, signatureAlgorithm
  /// SEQUENCE, signatureValue BIT STRING }` и ни байта лишнего.
  static bool _looksLikeX509(Uint8List der) {
    final outer = _readTlv(der, 0);
    if (outer == null || outer.tag != 0x30 || outer.end != der.length) {
      return false;
    }
    var offset = outer.contentStart;
    for (final tag in const [0x30, 0x30, 0x03]) {
      final tlv = _readTlv(der, offset);
      if (tlv == null || tlv.tag != tag || tlv.end > outer.end) return false;
      if (tag != 0x03 && tlv.end == tlv.contentStart) return false;
      offset = tlv.end;
    }
    return offset == outer.end;
  }

  static _Tlv? _readTlv(Uint8List bytes, int offset) {
    if (offset + 2 > bytes.length) return null;
    final tag = bytes[offset];
    final first = bytes[offset + 1];
    var contentStart = offset + 2;
    int length;
    if (first < 0x80) {
      length = first;
    } else {
      final count = first & 0x7F;
      if (count == 0 || count > 4 || contentStart + count > bytes.length) {
        return null;
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[contentStart + i];
      }
      contentStart += count;
    }
    final end = contentStart + length;
    if (end > bytes.length) return null;
    return _Tlv(tag, contentStart, end);
  }
}

class _Tlv {
  const _Tlv(this.tag, this.contentStart, this.end);

  final int tag;
  final int contentStart;
  final int end;
}
