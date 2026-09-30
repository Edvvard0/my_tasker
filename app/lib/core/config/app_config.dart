import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Конфигурация сборки. В тестах переопределяется через [appConfigProvider].
@immutable
class AppConfig {
  const AppConfig({
    required this.allowInsecureLocalhost,
    this.clientSchemaVersion = 1,
    this.appVersion = '0.1.0',
  });

  /// Конфигурация по умолчанию: небезопасный `http://localhost` разрешён
  /// только в debug-сборках.
  factory AppConfig.forBuild() =>
      const AppConfig(allowInsecureLocalhost: kDebugMode);

  /// Разрешить `http://` для localhost (только debug).
  final bool allowInsecureLocalhost;

  /// Версия клиентской части API-контракта; сервер отдаёт
  /// `min_client_schema_version` в `GET /version`.
  final int clientSchemaVersion;

  /// Версия приложения (для экрана настроек).
  final String appVersion;
}

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.forBuild());
