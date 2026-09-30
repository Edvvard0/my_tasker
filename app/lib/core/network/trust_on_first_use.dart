import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';

/// Корневой сертификат, полученный от сервера при первом знакомстве.
@immutable
class FetchedRootCa {
  const FetchedRootCa({required this.pem, required this.fingerprint});

  /// PEM с одним сертификатом.
  final String pem;

  /// SHA-256 от DER (строчный hex). Пользователь сверяет его с сервером.
  final String fingerprint;
}

enum RootCaFetchError {
  /// Нет соединения, таймаут, отказ.
  unreachable,

  /// Сервер ответил не 200 или слишком большим телом.
  badResponse,

  /// В ответе нет ровно одного корректного сертификата.
  invalidCertificate,
}

class RootCaFetchException implements Exception {
  const RootCaFetchException(this.error);

  final RootCaFetchError error;

  @override
  String toString() => 'RootCaFetchException($error)';
}

/// Получает корневой УЦ сервера: `GET <base>/ca/root.crt`.
typedef RootCaFetcher = Future<FetchedRootCa> Function(Uri baseUrl);

const int _maxBodyBytes = 64 * 1024;

/// **Единственное место в приложении, где проверка сертификата отключена.**
///
/// Trust-on-first-use: один запрос за корневым УЦ, пока доверять ещё нечему.
/// Ответу не верим: результат показывается пользователю вместе с
/// отпечатком, а сохраняется только после ручной сверки с отпечатком,
/// напечатанным на сервере. Все последующие запросы идут через
/// `createPinnedHttpClient` и этот клиент не используют.
Future<FetchedRootCa> fetchRootCaTrustOnFirstUse(
  Uri baseUrl, {
  Duration deadline = const Duration(seconds: 15),
}) async {
  final client = HttpClient()
    ..connectionTimeout = deadline
    // Осознанно: см. документацию функции.
    ..badCertificateCallback = (cert, host, port) => true;
  try {
    // Один общий дедлайн на весь обмен (соединение, заголовки, тело):
    // сервер, который отдаёт по байту в секунду, не удержит экран вечно.
    return await _download(client, baseUrl).timeout(deadline);
  } on RootCaFetchException {
    rethrow;
  } on Object {
    throw const RootCaFetchException(RootCaFetchError.unreachable);
  } finally {
    client.close(force: true);
  }
}

Future<FetchedRootCa> _download(HttpClient client, Uri baseUrl) async {
  final request = await client.getUrl(baseUrl.replace(path: '/ca/root.crt'));
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw const RootCaFetchException(RootCaFetchError.badResponse);
  }
  final bytes = <int>[];
  await for (final chunk in response) {
    bytes.addAll(chunk);
    if (bytes.length > _maxBodyBytes) {
      throw const RootCaFetchException(RootCaFetchError.badResponse);
    }
  }
  // Строгий разбор: только ровно один сертификат, сохраняем каноническую
  // перекодировку (см. CertificateFingerprint).
  final canonical = CertificateFingerprint.canonicalize(
    utf8.decode(bytes, allowMalformed: true),
  );
  if (canonical == null) {
    throw const RootCaFetchException(RootCaFetchError.invalidCertificate);
  }
  return FetchedRootCa(
    pem: canonical,
    fingerprint: CertificateFingerprint.ofPem(canonical)!,
  );
}

/// Способ получить корневой УЦ. В тестах подменяется.
final rootCaFetcherProvider = Provider<RootCaFetcher>(
  (ref) => fetchRootCaTrustOnFirstUse,
);
