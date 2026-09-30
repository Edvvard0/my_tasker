/// Причина, по которой адрес сервера не принят.
enum ServerUrlError {
  empty,
  invalid,
  insecureScheme,
  credentialsNotAllowed,
  unexpectedPath,
}

/// Результат разбора адреса сервера.
sealed class ServerUrlResult {
  const ServerUrlResult();
}

final class ValidServerUrl extends ServerUrlResult {
  const ValidServerUrl(this.uri);

  /// Нормализованный адрес без завершающего `/` (только схема, хост, порт).
  final Uri uri;

  bool get isHttps => uri.scheme == 'https';

  @override
  String toString() => uri.toString();
}

final class InvalidServerUrl extends ServerUrlResult {
  const InvalidServerUrl(this.error);

  final ServerUrlError error;
}

const _localHosts = {'localhost', '127.0.0.1', '::1', '[::1]'};

/// Проверяет и нормализует адрес сервера.
///
/// Правила: схема `https` обязательна; `http` допустим только для
/// localhost и только если [allowInsecureLocalhost] (debug-сборка);
/// без логина/пароля, query, fragment и пути.
ServerUrlResult parseServerUrl(
  String input, {
  required bool allowInsecureLocalhost,
}) {
  final text = input.trim();
  if (text.isEmpty) return const InvalidServerUrl(ServerUrlError.empty);

  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.hasScheme ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return const InvalidServerUrl(ServerUrlError.invalid);
  }
  if (uri.userInfo.isNotEmpty) {
    return const InvalidServerUrl(ServerUrlError.credentialsNotAllowed);
  }
  if (uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return const InvalidServerUrl(ServerUrlError.unexpectedPath);
  }
  if (uri.scheme == 'http' &&
      !(allowInsecureLocalhost && _localHosts.contains(uri.host))) {
    return const InvalidServerUrl(ServerUrlError.insecureScheme);
  }

  return ValidServerUrl(
    Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ),
  );
}
