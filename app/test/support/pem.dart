import 'dart:convert';

import 'package:my_tasker/core/network/certificate_fingerprint.dart';

/// Структурно корректный PEM (содержимое — произвольные байты): для тестов,
/// где настоящий сертификат не нужен.
String fakePem([List<int> der = const [1, 2, 3, 4, 5, 6, 7, 8]]) =>
    '-----BEGIN CERTIFICATE-----\n${base64.encode(der)}\n'
    '-----END CERTIFICATE-----\n';

String fakeFingerprint([List<int> der = const [1, 2, 3, 4, 5, 6, 7, 8]]) =>
    CertificateFingerprint.ofDer(der);
