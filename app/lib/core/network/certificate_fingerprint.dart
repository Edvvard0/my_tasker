import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Работа с корневым сертификатом (PEM) и его SHA-256 отпечатком.
abstract final class CertificateFingerprint {
  static final RegExp _pemBlock = RegExp(
    r'-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+?)-----END CERTIFICATE-----',
  );

  /// Достаёт DER из PEM с **ровно одним** сертификатом; иначе `null`.
  static Uint8List? pemToDer(String pem) {
    final blocks = _pemBlock.allMatches(pem).toList();
    if (blocks.length != 1) return null;
    try {
      final der = base64.decode(
        blocks.single.group(1)!.replaceAll(RegExp(r'\s'), ''),
      );
      return der.isEmpty ? null : Uint8List.fromList(der);
    } on FormatException {
      return null;
    }
  }

  /// SHA-256 от DER-представления сертификата (строчный hex, 64 символа).
  static String ofDer(List<int> der) => sha256.convert(der).toString();

  /// Отпечаток PEM-сертификата или `null`, если PEM некорректен.
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
}
