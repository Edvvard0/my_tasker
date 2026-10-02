import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/chat_routing.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';

ChatMessage _msg(String id, MessageRole role, {MessageStatus? status}) =>
    ChatMessage(
      id: id,
      conversationId: 'c',
      role: role,
      text: 'т',
      parts: const [],
      status: status ?? MessageStatus.done,
    );

void main() {
  RouteDecision route(
    ChatMode mode,
    LocalAvailability l, {
    required bool online,
  }) => decideRoute(mode: mode, online: online, local: l);

  group('маршрутизация', () {
    test('облако + сеть -> облако (в любом состоянии модели)', () {
      for (final l in LocalAvailability.values) {
        expect(
          route(ChatMode.cloud, l, online: true).action,
          ChatRouteAction.sendCloud,
        );
      }
    });

    test('облако без сети, модель скачана -> предложить локально', () {
      final d = route(ChatMode.cloud, LocalAvailability.ready, online: false);
      expect(d.action, ChatRouteAction.offerLocal);
      expect(d.message, contains('Нет сети'));
    });

    test('облако без сети и без модели -> сообщение не теряется', () {
      for (final l in [
        LocalAvailability.modelNotReady,
        LocalAvailability.unsupportedPlatform,
      ]) {
        final d = route(ChatMode.cloud, l, online: false);
        expect(d.action, ChatRouteAction.holdForNetwork);
        expect(d.message, contains('сохранено'));
      }
    });

    test('локальный режим + модель -> локально, сеть не нужна', () {
      expect(
        route(ChatMode.local, LocalAvailability.ready, online: false).action,
        ChatRouteAction.sendLocal,
      );
      expect(
        route(ChatMode.local, LocalAvailability.ready, online: true).action,
        ChatRouteAction.sendLocal,
      );
    });

    test('локальный режим без модели: недоступно, облако возможно онлайн', () {
      final online = route(
        ChatMode.local,
        LocalAvailability.modelNotReady,
        online: true,
      );
      expect(online.action, ChatRouteAction.localUnavailable);
      expect(online.cloudPossible, isTrue);
      expect(online.message, contains('не скачана'));
      final offline = route(
        ChatMode.local,
        LocalAvailability.modelNotReady,
        online: false,
      );
      expect(offline.cloudPossible, isFalse);
    });

    test('Windows: понятное «недоступно»', () {
      final d = route(
        ChatMode.local,
        LocalAvailability.unsupportedPlatform,
        online: true,
      );
      expect(d.action, ChatRouteAction.localUnavailable);
      expect(d.message, contains('Android'));
      expect(d.cloudPossible, isTrue);
    });
  });

  group('сообщение без ответа', () {
    test('последнее сообщение пользователя без ответа — ожидает отправки', () {
      final pending = pendingUserMessage([
        _msg('1', MessageRole.user),
        _msg('2', MessageRole.assistant),
        _msg('3', MessageRole.user),
      ]);
      expect(pending?.id, '3');
    });

    test('есть ответ (в том числе ошибочный) — ничего не ждёт', () {
      expect(
        pendingUserMessage([
          _msg('1', MessageRole.user),
          _msg('2', MessageRole.assistant, status: MessageStatus.error),
        ]),
        isNull,
      );
      expect(pendingUserMessage(const []), isNull);
    });

    test('системные сообщения не мешают', () {
      expect(
        pendingUserMessage([
          _msg('1', MessageRole.user),
          _msg('2', MessageRole.system),
        ])?.id,
        '1',
      );
    });
  });
}
