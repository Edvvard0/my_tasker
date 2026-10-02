import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/network/api_client.dart';

/// Сбой запроса к ИИ в понятном виде (spec Этапа 3, раздел 8). Клиент
/// ветвится только по [code]; [message] — русский текст для человека.
@immutable
class ChatFailure {
  const ChatFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.critical = false,
  });

  /// Из ошибки HTTP до начала потока.
  factory ChatFailure.fromApi(ApiException e) {
    if (e.isNetwork) return ChatFailure.forCode('offline', retryable: true);
    if (e.kind == ApiErrorKind.notConfigured) {
      return ChatFailure.forCode('not_configured');
    }
    return ChatFailure.forCode(
      e.code ?? 'internal_error',
      retryable: e.isServerError,
      details: e.details,
    );
  }

  /// Описание по коду.
  factory ChatFailure.forCode(
    String code, {
    bool retryable = false,
    Map<String, Object?> details = const {},
  }) {
    final (text, critical) = switch (code) {
      'offline' => (
        'Нет сети: ответ ИИ недоступен. Сообщение сохранено, повторите, '
            'когда сеть появится.',
        false,
      ),
      'not_configured' => (
        'Сервер не настроен: укажите его в Настройках.',
        false,
      ),
      'limit_exceeded' => (_limitText(details), true),
      'sensitive_context_forbidden' => (
        'В контексте есть данные с пометкой «не отправлять в облако». '
            'Уберите их из контекста: такие данные только для локальной '
            'модели.',
        true,
      ),
      'model_not_found' => (
        'Эта модель недоступна у провайдера. Выберите другую в шапке чата.',
        false,
      ),
      'upstream_timeout' => (
        'Провайдер ИИ не ответил вовремя. Попробуйте ещё раз.',
        false,
      ),
      'upstream_error' => (
        'Сбой у провайдера ИИ. Попробуйте ещё раз чуть позже.',
        false,
      ),
      'upstream_rate_limited' => (
        'Провайдер ИИ просит подождать: слишком много запросов.',
        false,
      ),
      'upstream_payment_required' => (
        'У ключа провайдера ИИ закончились средства. Пополните баланс.',
        true,
      ),
      'upstream_rejected' => ('Провайдер ИИ отклонил запрос.', false),
      'ai_not_configured' => (
        'ИИ не настроен на сервере (нет ключа провайдера).',
        true,
      ),
      'conversation_not_found' => (
        'Сервер ещё не получил этот чат. Дождитесь синхронизации и повторите.',
        false,
      ),
      'agent_not_found' => (
        'Агент не найден на сервере. Выберите другого агента.',
        false,
      ),
      'message_exists' => ('Этот ответ уже обрабатывается.', false),
      'tool_loop_limit' => (
        'Модель не уложилась в лимит шагов с инструментами.',
        false,
      ),
      'persist_failed' => ('Сервер не смог сохранить ответ.', false),
      'no_model' => (
        'Выберите модель в шапке чата, чтобы отправить сообщение.',
        false,
      ),
      'sync_failed' => (
        'Не удалось отправить чат на сервер. Проверьте синхронизацию.',
        false,
      ),
      'connection_lost' => (
        'Ответ прервался: связь с сервером потеряна.',
        false,
      ),
      'validation_error' || 'unknown_tool' => (
        'Сервер не принял запрос. Обновите приложение.',
        false,
      ),
      _ => ('Не удалось получить ответ ИИ.', false),
    };
    return ChatFailure(
      code: code,
      message: text,
      retryable: retryable || _alwaysRetryable.contains(code),
      critical: critical,
    );
  }

  /// Код раздела 8 либо клиентский: `offline`, `no_model`, `sync_failed`,
  /// `connection_lost`, `not_configured`.
  final String code;
  final String message;

  /// Имеет смысл нажать «Повторить».
  final bool retryable;

  /// Критичная ошибка: единственный случай красного в чате.
  final bool critical;

  /// Нет сети — не авария, а состояние.
  bool get isOffline => code == 'offline';

  static const Set<String> _alwaysRetryable = {
    'offline',
    'upstream_timeout',
    'upstream_error',
    'upstream_rate_limited',
    'persist_failed',
    'internal_error',
    'connection_lost',
    'sync_failed',
    'conversation_not_found',
  };

  static String _limitText(Map<String, Object?> details) {
    final limit = details['limit_kopecks'];
    final spent = details['spent_kopecks'];
    const base = 'Месячный лимит расходов на ИИ исчерпан';
    if (limit is int && spent is int) {
      return '$base: потрачено ${formatAmount(spent)} из ${formatAmount(limit)}. '
          'Измените лимит в разделе «Расход и лимит».';
    }
    return '$base. Измените лимит в разделе «Расход и лимит».';
  }
}
