import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:my_tasker/core/network/certificate_fingerprint.dart';

/// Наблюдатель за проверкой сертификата: позволяет отличить «сертификат не
/// совпал» от обычной сетевой ошибки (Dio в обоих случаях бросает
/// `connectionError`).
class PinObserver {
  /// Сервер предъявил цепочку, не выпущенную закреплённым корневым УЦ
  /// (или с неверным IP/именем).
  bool mismatchDetected = false;

  /// Отпечаток последнего отвергнутого сертификата (для диагностики).
  String? lastSeenFingerprint;
}

/// Создаёт `HttpClient`, доверяющий **только** закреплённому корневому УЦ.
///
/// * Системные корни не подключены (`SecurityContext()` создаётся без
///   доверенных корней), доверенным задан лишь [rootCaPem]: обычная проверка цепочки,
///   срока и IP/имени в сертификате остаётся включённой.
/// * `badCertificateCallback` всегда возвращает `false`: обходного пути
///   принять чужой сертификат нет, он лишь фиксирует факт в [observer].
///
/// Бросает [TlsException], если [rootCaPem] не разбирается.
HttpClient createPinnedHttpClient(String rootCaPem, {PinObserver? observer}) {
  final context = SecurityContext()
    ..setTrustedCertificatesBytes(utf8.encode(rootCaPem));
  return HttpClient(context: context)
    ..badCertificateCallback = (cert, host, port) {
      observer
        ?..mismatchDetected = true
        ..lastSeenFingerprint = CertificateFingerprint.ofDer(cert.der);
      return false;
    };
}

/// Адаптер Dio с закреплением корневого УЦ.
HttpClientAdapter createPinnedAdapter(
  String rootCaPem, {
  PinObserver? observer,
}) => IOHttpClientAdapter(
  createHttpClient: () => createPinnedHttpClient(rootCaPem, observer: observer),
);

/// Фабрика адаптера. В тестах подменяется фейком.
typedef PinnedAdapterFactory = HttpClientAdapter Function(
  String rootCaPem,
  PinObserver observer,
);

HttpClientAdapter defaultPinnedAdapterFactory(
  String rootCaPem,
  PinObserver observer,
) => createPinnedAdapter(rootCaPem, observer: observer);

/// Обычный адаптер (системное доверие) — только для `http://localhost` в debug.
HttpClientAdapter createPlainAdapter() => IOHttpClientAdapter();
