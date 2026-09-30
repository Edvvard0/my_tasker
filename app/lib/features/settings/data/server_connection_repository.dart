import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';

/// Ключи в таблице `local_settings`.
abstract final class SettingsKeys {
  static const serverUrl = 'server_url';
  static const serverRootCaPem = 'server_root_ca_pem';
}

/// Настройки подключения к серверу, сохранённые на устройстве.
@immutable
class ServerConnectionSettings {
  const ServerConnectionSettings({this.url, this.caPem});

  /// Нормализованный адрес (`https://host[:port]`).
  final String? url;

  /// Закреплённый корневой УЦ сервера (PEM с одним сертификатом). Относится
  /// именно к [url]: при смене адреса сбрасывается.
  final String? caPem;

  bool get isConfigured => url != null;

  @override
  bool operator ==(Object other) =>
      other is ServerConnectionSettings &&
      other.url == url &&
      other.caPem == caPem;

  @override
  int get hashCode => Object.hash(url, caPem);
}

/// Чтение и запись настроек сервера поверх [LocalSettingsRepository].
class ServerConnectionRepository {
  ServerConnectionRepository(this._settings);

  final LocalSettingsRepository _settings;

  Future<ServerConnectionSettings> load() async => ServerConnectionSettings(
    url: await _settings.read(SettingsKeys.serverUrl),
    caPem: await _settings.read(SettingsKeys.serverRootCaPem),
  );

  /// Сохраняет обе настройки атомарно; `null` очищает значение.
  Future<void> save(ServerConnectionSettings value) => _settings.writeAll({
    SettingsKeys.serverUrl: value.url,
    SettingsKeys.serverRootCaPem: value.caPem,
  });
}

final serverConnectionRepositoryProvider = Provider<ServerConnectionRepository>(
  (ref) =>
      ServerConnectionRepository(ref.watch(localSettingsRepositoryProvider)),
);
