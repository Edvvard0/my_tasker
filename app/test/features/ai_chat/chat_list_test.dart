import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/ai_chat/ai_chat_screen.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';

import '../../support/ai_env.dart';
import '../../support/ai_ui_env.dart';
import '../../support/pump_app.dart';

const _a = '01900000-0000-7000-8000-0000000000a1';
const _b = '01900000-0000-7000-8000-0000000000a2';
const _c = '01900000-0000-7000-8000-0000000000a3';

Future<void> _seedChats(AiRepository repo) async {
  await repo.ensureConversation(
    const Conversation(
      id: _a,
      title: '',
      topic: AiTopic.work,
      model: 'openai/gpt-4o',
    ),
  );
  await repo.addUserMessage(_a, 'Оцени доработку входа в бота');
  await repo.ensureConversation(
    const Conversation(
      id: _b,
      title: 'Бюджет на месяц',
      topic: AiTopic.finance,
      pinned: true,
    ),
  );
  await repo.addUserMessage(_b, 'Как распределить бюджет?');
  await repo.ensureConversation(
    const Conversation(
      id: _c,
      title: 'Старый разговор',
      topic: AiTopic.study,
      archived: true,
    ),
  );
}

ChatListEntry _entry(
  String id,
  AiTopic topic, {
  String title = 'Чат',
  bool pinned = false,
  bool archived = false,
  DateTime? created,
  String? last,
}) => ChatListEntry(
  Conversation(
    id: id,
    title: title,
    topic: topic,
    pinned: pinned,
    archived: archived,
    createdAt: created,
  ),
  last == null
      ? null
      : ChatMessage(
          id: uuid7(
            nowMs: (created ?? DateTime.utc(2026)).millisecondsSinceEpoch,
          ),
          conversationId: id,
          role: MessageRole.user,
          text: last,
          parts: const [],
          status: MessageStatus.done,
        ),
);

void main() {
  group('список чатов: логика', () {
    final now = DateTime.utc(2026, 9, 30, 12);

    test('группы: закреплённые, сегодня, на этой неделе, ранее', () {
      ChatGroup g(ChatListEntry e) => groupOf(e, now);
      expect(g(_entry('1', AiTopic.work, pinned: true)), ChatGroup.pinned);
      expect(
        g(_entry('2', AiTopic.work, created: DateTime.utc(2026, 9, 30, 8))),
        ChatGroup.today,
      );
      expect(
        g(_entry('3', AiTopic.work, created: DateTime.utc(2026, 9, 27, 8))),
        ChatGroup.week,
      );
      expect(
        g(_entry('4', AiTopic.work, created: DateTime.utc(2026, 9))),
        ChatGroup.earlier,
      );
    });

    test('отбор: архив отдельно, тема, поиск по названию и тексту', () {
      final all = [
        _entry('1', AiTopic.work, title: 'Смета', last: 'Привет'),
        _entry('2', AiTopic.finance, title: 'Бюджет', last: 'Расходы за месяц'),
        _entry('3', AiTopic.work, title: 'Старый', archived: true),
      ];
      List<String> ids(List<ChatListEntry> l) => [
        for (final e in l) e.conversation.id,
      ];
      expect(ids(filterEntries(all, archived: false)), ['1', '2']);
      expect(ids(filterEntries(all, archived: true)), ['3']);
      expect(ids(filterEntries(all, archived: false, topic: AiTopic.finance)), [
        '2',
      ]);
      expect(ids(filterEntries(all, archived: false, query: 'СМЕТ')), ['1']);
      expect(ids(filterEntries(all, archived: false, query: 'расходы')), ['2']);
      expect(
        ids(filterEntries(all, archived: false, query: 'нет такого')),
        isEmpty,
      );
    });

    test('порядок: закреплённые выше, затем по активности', () {
      final all = [
        _entry('old', AiTopic.work, created: DateTime.utc(2026, 9)),
        _entry('new', AiTopic.work, created: DateTime.utc(2026, 9, 30)),
        _entry(
          'pin',
          AiTopic.work,
          pinned: true,
          created: DateTime.utc(2026, 8),
        ),
      ];
      expect(
        [
          for (final e in filterEntries(all, archived: false))
            e.conversation.id,
        ],
        ['pin', 'new', 'old'],
      );
    });
  });

  group('экран «ИИ»', () {
    testWidgets('пусто: состояние и кнопка «Новый чат» открывает чат', (
      tester,
    ) async {
      await pumpAi(tester);
      expect(find.text('Пока нет чатов'), findsOneWidget);
      await tester.tap(find.byKey(const Key('empty-new-chat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
      expect(find.text('О чём поговорим?'), findsOneWidget);
    });

    testWidgets('данные: закреплённые сверху, названия, превью, чипы', (
      tester,
    ) async {
      await pumpAi(tester, seed: _seedChats);
      expect(find.byKey(const Key('group-pinned')), findsOneWidget);
      expect(find.byKey(const Key('group-today')), findsOneWidget);
      // Заголовок пустого чата — из первого вопроса.
      expect(find.text('Оцени доработку входа в бота'), findsWidgets);
      expect(find.text('Бюджет на месяц'), findsOneWidget);
      expect(find.text('Как распределить бюджет?'), findsOneWidget);
      // Архивный чат в основном списке не виден.
      expect(find.text('Старый разговор'), findsNothing);
      // Закреплённый — выше обычного.
      final pinnedY = tester
          .getTopLeft(find.byKey(const Key('chat-row-$_b')))
          .dy;
      final normalY = tester
          .getTopLeft(find.byKey(const Key('chat-row-$_a')))
          .dy;
      expect(pinnedY, lessThan(normalY));
    });

    testWidgets('поиск и чип темы сужают список; архив — отдельный вид', (
      tester,
    ) async {
      await pumpAi(tester, seed: _seedChats);
      await typeInto(tester, 'chat-search', 'бюджет');
      expect(find.byKey(const Key('chat-row-$_b')), findsOneWidget);
      expect(find.byKey(const Key('chat-row-$_a')), findsNothing);
      await typeInto(tester, 'chat-search', 'нет-такого');
      expect(find.text('Ничего не найдено'), findsOneWidget);
      await typeInto(tester, 'chat-search', '');

      await tester.ensureVisible(find.byKey(const Key('topic-chip-work')));
      await tester.tap(find.byKey(const Key('topic-chip-work')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-row-$_a')), findsOneWidget);
      expect(find.byKey(const Key('chat-row-$_b')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('topic-all')));
      await tester.tap(find.byKey(const Key('topic-all')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('topic-archive')));
      await tester.tap(find.byKey(const Key('topic-archive')));
      await tester.pumpAndSettle();
      expect(find.text('Старый разговор'), findsOneWidget);
      expect(find.byKey(const Key('chat-row-$_a')), findsNothing);
    });

    testWidgets('меню: закрепить, переименовать, в архив', (tester) async {
      final ui = await pumpAi(tester, seed: _seedChats);
      // Закрепить.
      await tester.tap(find.byKey(const Key('chat-row-menu-$_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('row-menu-pin')));
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(() => ui.repo.getConversation(_a)))!.pinned,
        isTrue,
      );

      // Переименовать.
      await tester.tap(find.byKey(const Key('chat-row-menu-$_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('row-menu-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('rename-field')),
        'Оценка входа',
      );
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();
      expect(find.text('Оценка входа'), findsOneWidget);

      // В архив.
      await tester.tap(find.byKey(const Key('chat-row-menu-$_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('row-menu-archive')));
      await tester.pumpAndSettle();
      expect(find.text('Оценка входа'), findsNothing);
      expect(
        (await tester.runAsync(() => ui.repo.getConversation(_a)))!.archived,
        isTrue,
      );
    });

    testWidgets('удаление с подтверждением уходит в корзину', (tester) async {
      final ui = await pumpAi(tester, seed: _seedChats);
      await tester.tap(find.byKey(const Key('chat-row-menu-$_b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('row-menu-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      // Отмена ничего не удаляет.
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Бюджет на месяц'), findsOneWidget);

      await tester.tap(find.byKey(const Key('chat-row-menu-$_b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('row-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить').last);
      await tester.pumpAndSettle();
      expect(find.text('Бюджет на месяц'), findsNothing);
      final trash = await tester.runAsync(
        () => ui.container.read(syncStoreProvider).trashItems(),
      );
      expect(trash!.map((t) => t.table), contains('ai_conversations'));
    });

    testWidgets('свайп влево архивирует чат', (tester) async {
      final ui = await pumpAi(tester, seed: _seedChats);
      await tester.drag(
        find.byKey(const Key('chat-row-$_a')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-row-$_a')), findsNothing);
      expect(
        (await tester.runAsync(() => ui.repo.getConversation(_a)))!.archived,
        isTrue,
      );
    });

    testWidgets('открытие чата из списка', (tester) async {
      await pumpAi(tester, seed: _seedChats);
      await tester.tap(find.byKey(const Key('chat-row-$_b')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
      expect(find.byKey(const Key('chat-title')), findsOneWidget);
      expect(find.text('Бюджет на месяц'), findsWidgets);
      // Назад возвращает в список.
      await tester.tap(find.byKey(const Key('chat-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-search')), findsOneWidget);
    });

    testWidgets('ошибка чтения чатов: сообщение вместо списка', (tester) async {
      await pumpAi(
        tester,
        overrides: [
          conversationsProvider.overrideWith(
            (ref) => Stream<List<Conversation>>.error(StateError('db')),
          ),
        ],
      );
      expect(find.textContaining('Не удалось прочитать чаты'), findsOneWidget);
    });

    testWidgets('агенты подтягиваются: первый вход вызывает bootstrap', (
      tester,
    ) async {
      final api = FakeAiApi();
      await pumpAi(tester, api: api);
      expect(api.bootstrapCalls, 1);
    });

    testWidgets('кнопки панели: «Новый чат» и настройки ИИ', (tester) async {
      await pumpAi(tester);
      await tester.tap(find.byKey(const Key('ai-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-settings-agents')), findsOneWidget);
    });

    testWidgets('десктоп: список и чат открываются', (tester) async {
      await pumpAi(tester, size: desktopSize, seed: _seedChats);
      expect(find.text('Бюджет на месяц'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai-new-chat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
    });
  });
}
