import 'package:flutter/foundation.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';

/// Готовность локального режима на этом устройстве.
enum LocalAvailability {
  /// Платформа поддерживает, модель скачана и проверена.
  ready,

  /// Платформа поддерживает, модель ещё не скачана.
  modelNotReady,

  /// Платформа без офлайн-модели (Windows и др.).
  unsupportedPlatform,
}

/// Что делать с отправкой сообщения.
enum ChatRouteAction {
  /// Облачный запрос на сервер (этап 3).
  sendCloud,

  /// Ответить локальной моделью.
  sendLocal,

  /// Облачный чат без сети, но модель скачана: предложить ответить локально.
  offerLocal,

  /// Облачный чат без сети и без локальной модели: сообщение сохранено,
  /// отправить в облако, когда появится сеть.
  holdForNetwork,

  /// Локальный режим недоступен (нет модели или платформа без неё).
  localUnavailable,
}

@immutable
class RouteDecision {
  const RouteDecision(this.action, this.message, {this.cloudPossible = false});

  final ChatRouteAction action;

  /// Подсказка пользователю (по-русски); пустая, если решение очевидно.
  final String message;

  /// Для `localUnavailable`: можно ли вместо этого отправить в облако.
  final bool cloudPossible;

  @override
  String toString() => 'RouteDecision(${action.name}: $message)';
}

/// Маршрутизация сообщения (решение этапа 10, п. 4). Чистая функция: сеть,
/// режим беседы и готовность модели приходят параметрами.
///
/// * `cloud` + сеть -> облако;
/// * `cloud`, сети нет, модель скачана -> предложить продолжить локально;
/// * `cloud`, сети нет, модели нет -> сообщение сохраняется, облачный
///   запрос уйдёт, когда появится сеть (запрос не теряется);
/// * `local` + модель готова -> локально (сеть не нужна);
/// * `local` без модели или на Windows -> «недоступно» с понятной причиной.
RouteDecision decideRoute({
  required ChatMode mode,
  required bool online,
  required LocalAvailability local,
}) {
  if (mode == ChatMode.cloud) {
    if (online) return const RouteDecision(ChatRouteAction.sendCloud, '');
    if (local == LocalAvailability.ready) {
      return const RouteDecision(
        ChatRouteAction.offerLocal,
        'Нет сети. Ответить на устройстве офлайн-моделью?',
      );
    }
    return const RouteDecision(
      ChatRouteAction.holdForNetwork,
      'Нет сети. Сообщение сохранено: отправим в облако, когда она появится.',
    );
  }
  switch (local) {
    case LocalAvailability.ready:
      return const RouteDecision(ChatRouteAction.sendLocal, '');
    case LocalAvailability.modelNotReady:
      return RouteDecision(
        ChatRouteAction.localUnavailable,
        online
            ? 'Офлайн-модель не скачана. Скачайте её в настройках ИИ или '
                  'переключите чат на облако.'
            : 'Офлайн-модель не скачана, а сети нет. Сообщение сохранено.',
        cloudPossible: online,
      );
    case LocalAvailability.unsupportedPlatform:
      return RouteDecision(
        ChatRouteAction.localUnavailable,
        'Офлайн-модель недоступна на этом устройстве: она работает только '
        'на Android. Переключите чат на облако.',
        cloudPossible: online,
      );
  }
}

/// Сообщение пользователя без ответа в конце беседы (облачный запрос,
/// который не ушёл из-за отсутствия сети): на него предлагается кнопка
/// «Отправить в облако». Ошибочный ответ ассистента — это уже ответ,
/// повтор в таком случае предлагает сам чат.
ChatMessage? pendingUserMessage(List<ChatMessage> messages) {
  ChatMessage? last;
  for (final m in messages) {
    if (m.role == MessageRole.system) continue;
    last = m;
  }
  return last != null && last.role == MessageRole.user ? last : null;
}
