import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';

/// Ключ локальной настройки: решение пользователя о финансовых инструментах
/// ИИ в этой беседе (`1` — разрешено, `0` — не разрешено).
String sensitiveToolsConsentKey(String conversationId) =>
    'ai.sensitive_tools_consent.$conversationId';

/// Согласие на чувствительные инструменты облачного агента (спецификация
/// Этапа 3, 5.1: `sensitive_tools_consent`). Решение хранится на уровне
/// беседы, на устройстве; в запрос уходит только согласие (`true`).
class SensitiveToolsConsent {
  const SensitiveToolsConsent(this._settings);

  final LocalSettingsRepository _settings;

  /// `null` — пользователь ещё не решал в этой беседе.
  Future<bool?> read(String conversationId) async {
    final value = await _settings.read(
      sensitiveToolsConsentKey(conversationId),
    );
    return switch (value) {
      '1' => true,
      '0' => false,
      _ => null,
    };
  }

  Future<void> write(String conversationId, {required bool allowed}) =>
      _settings.write(
        sensitiveToolsConsentKey(conversationId),
        allowed ? '1' : '0',
      );
}

final Provider<SensitiveToolsConsent> sensitiveToolsConsentProvider =
    Provider<SensitiveToolsConsent>(
      (ref) =>
          SensitiveToolsConsent(ref.watch(localSettingsRepositoryProvider)),
    );
