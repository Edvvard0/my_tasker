import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/network/server_url.dart';

/// Результат проверки поля адреса на экране «Сервер».
@immutable
class ServerUrlValidation {
  const ServerUrlValidation({this.url, this.error});

  /// Нормализованный адрес (если введён корректно).
  final ValidServerUrl? url;

  /// Текст ошибки под полем.
  final String? error;

  bool get isValid => url != null;
}

/// Текст ошибки адреса. Формулировки — по 02, 7.3: что случилось + что делать.
String serverUrlErrorText(ServerUrlError error) => switch (error) {
  ServerUrlError.empty => 'Введи адрес сервера',
  ServerUrlError.invalid =>
    'Адрес должен выглядеть так: https://203.0.113.10 или '
        'https://203.0.113.10:8443',
  ServerUrlError.insecureScheme =>
    'Нужен https: по каналу идут токены и финансы. Обычный http разрешён '
        'только для localhost в debug-сборке',
  ServerUrlError.credentialsNotAllowed => 'Логин и пароль в адресе не нужны',
  ServerUrlError.unexpectedPath => 'Укажи только адрес и порт, без пути',
};

const pemInvalidText =
    'Нужен один сертификат в формате PEM: от «-----BEGIN CERTIFICATE-----» '
    'до «-----END CERTIFICATE-----»';

ServerUrlValidation validateServerUrl(
  String url, {
  required bool allowInsecureLocalhost,
}) {
  final parsed = parseServerUrl(
    url,
    allowInsecureLocalhost: allowInsecureLocalhost,
  );
  return switch (parsed) {
    ValidServerUrl() => ServerUrlValidation(url: parsed),
    InvalidServerUrl(:final error) => ServerUrlValidation(
      error: serverUrlErrorText(error),
    ),
  };
}
