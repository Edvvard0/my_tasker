import 'package:my_tasker/core/network/certificate_fingerprint.dart';

/// Минимальный DER, проходящий структурную проверку X.509
/// (`SEQUENCE { SEQUENCE, SEQUENCE, BIT STRING }`), но не настоящий
/// сертификат. [salt] делает содержимое (и отпечаток) разным.
List<int> fakeDer([int salt = 0xAB]) => [
  0x30, 0x0E, //
  0x30, 0x03, 0x02, 0x01, 0x01, //
  0x30, 0x03, 0x06, 0x01, 0x2A, //
  0x03, 0x02, 0x00, salt,
];

/// Каноническая PEM-запись [fakeDer].
String fakePem([int salt = 0xAB]) =>
    CertificateFingerprint.pemFromDer(fakeDer(salt));

String fakeFingerprint([int salt = 0xAB]) =>
    CertificateFingerprint.ofDer(fakeDer(salt));
