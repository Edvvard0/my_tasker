import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';

import '../../support/ai_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

const _profileId = '01900000-0000-7000-8000-0000000000a1';

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late AiDevice device;
  late AiRepository repo;
  late SyncStore store;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = aiServer(clock);
    counter = 0;
    device = await AiDevice.create(server, clock: clock);
    store = device.container.read(syncStoreProvider);
    repo = AiRepository(
      store,
      newId: () =>
          '01900000-0000-7000-8000-${(1000 + ++counter).toString().padLeft(12, '0')}',
      now: () => clock.now,
    );
  });
  tearDown(() async {
    device.dispose();
    await server.dispose();
  });

  Future<void> seedProfile({String prompt = 'Исходный промт'}) => store
      .create('ai_agent_profiles', _profileId, {
        'seed_key': 'general',
        'name': 'Общий',
        'topic': 'general',
        'system_prompt': prompt,
        'prompt_version': 1,
        'default_model': null,
        'enabled_tools': ['get_tasks', 'get_events', 'create_task'],
        'default_context_preset_id': null,
        'position': 0,
      })
      .then(
        (_) =>
            store.create('ai_prompt_versions', promptVersionId(_profileId, 1), {
              'profile_id': _profileId,
              'version': 1,
              'text': prompt,
              'source': 'seed',
            }),
      );

  group('чаты', () {
    const draft = Conversation(
      id: '01900000-0000-7000-8000-0000000000c1',
      title: '',
      topic: AiTopic.work,
      model: 'openai/gpt-4o',
    );

    test(
      'черновик становится строкой один раз; правки идут в outbox',
      () async {
        await repo.ensureConversation(draft);
        await repo.ensureConversation(draft.copyWith(title: 'Другой'));
        final saved = (await repo.getConversation(draft.id))!;
        expect(saved.title, '');
        expect(saved.topic, AiTopic.work);
        expect(saved.mode, ChatMode.cloud);
        final ops = await store.outbox();
        expect(ops.where((o) => o.table == 'ai_conversations'), hasLength(1));
      },
    );

    test('переименовать, закрепить, архивировать', () async {
      await repo.ensureConversation(draft);
      await repo.rename(draft.id, '  Оценка доработок ');
      await repo.setPinned(draft.id, pinned: true);
      await repo.setArchived(draft.id, archived: true);
      await repo.setModel(draft.id, 'anthropic/claude-sonnet');
      await repo.setContextPreset(draft.id, null);
      final c = (await repo.getConversation(draft.id))!;
      expect(c.title, 'Оценка доработок');
      expect(c.pinned, isTrue);
      expect(c.archived, isTrue);
      expect(c.model, 'anthropic/claude-sonnet');
      expect(
        () => repo.rename(draft.id, 'я' * 201),
        throwsA(isA<AiValidationError>()),
      );
    });

    test(
      'удаление уходит в корзину, сообщения скрываются, возврат возвращает',
      () async {
        await repo.ensureConversation(draft);
        await repo.addUserMessage(draft.id, 'Привет');
        await repo.deleteConversation(draft.id);
        expect(await repo.getConversation(draft.id), isNull);
        expect(await repo.messagesOf(draft.id), isEmpty);
        final trash = await store.trashItems();
        expect(trash.map((t) => t.table), contains('ai_conversations'));
        await store.restore('ai_conversations', draft.id);
        expect(await repo.messagesOf(draft.id), hasLength(1));
      },
    );

    test(
      'сообщение пользователя: поля по контракту, заголовок из вопроса',
      () async {
        await repo.ensureConversation(draft);
        final id = await repo.addUserMessage(
          draft.id,
          '  Какие у меня\nзадачи на неделю?  ',
        );
        final m = (await repo.getMessage(id))!;
        expect(m.role, MessageRole.user);
        expect(m.status, MessageStatus.done);
        expect(m.text, 'Какие у меня\nзадачи на неделю?');
        expect((m.parts.single as TextPart).text, m.text);
        expect(
          (await repo.getConversation(draft.id))!.title,
          'Какие у меня задачи на неделю?',
        );
        // Заголовок не затирается вторым вопросом.
        await repo.addUserMessage(draft.id, 'Второй вопрос');
        expect(
          (await repo.getConversation(draft.id))!.title,
          'Какие у меня задачи на неделю?',
        );
        await expectLater(
          repo.addUserMessage(draft.id, '   '),
          throwsA(isA<AiValidationError>()),
        );
      },
    );

    test('сообщения по порядку создания, последнее сообщение чата', () async {
      await repo.ensureConversation(draft);
      await repo.addUserMessage(draft.id, 'первое');
      await repo.addUserMessage(draft.id, 'второе');
      final all = await repo.messagesOf(draft.id);
      expect(all.map((m) => m.text), ['первое', 'второе']);
      final last = await repo.watchLastMessages().first;
      expect(last[draft.id]!.text, 'второе');
      final conversations = await repo.watchConversations().first;
      expect(conversations.single.id, draft.id);
    });

    test(
      'все таблицы Этапа 3 синхронизируются на сервер без отказов',
      () async {
        await seedProfile();
        await repo.ensureConversation(draft);
        await repo.addUserMessage(draft.id, 'Привет');
        await repo.createPreset('Неделя', const [
          ContextSourceRef(source: 'tasks'),
        ], sensitive: false);
        await repo.addFavorite(
          const ModelInfo(
            id: 'openai/gpt-4o',
            name: 'GPT-4o',
            supportsTools: true,
          ),
        );
        await device.sync();
        expect(await store.outbox(), isEmpty, reason: 'ничего не отклонено');
        for (final table in [
          'ai_agent_profiles',
          'ai_prompt_versions',
          'ai_context_presets',
          'ai_model_favorites',
          'ai_conversations',
          'ai_messages',
        ]) {
          expect(server.snapshot(table), isNotEmpty, reason: table);
        }
      },
    );
  });

  group('промты агента', () {
    test('правка: новая версия и профиль одной транзакцией', () async {
      await seedProfile();
      expect(await repo.editPrompt(_profileId, 'Новый промт'), isTrue);
      final profile = (await repo.getAgent(_profileId))!;
      expect(profile.systemPrompt, 'Новый промт');
      expect(profile.promptVersion, 2);
      final versions = await repo.watchPromptVersions(_profileId).first;
      expect(versions.map((v) => v.version), [2, 1]);
      expect(versions.first.source, PromptSource.user);
      expect(versions.first.id, promptVersionId(_profileId, 2));
      // Обе правки — в одной пачке outbox (создание версии + правка профиля).
      final ops = await store.outbox();
      expect(ops.where((o) => o.table == 'ai_prompt_versions'), hasLength(2));
    });

    test(
      'тот же текст — без новой версии; пустой и слишком длинный — ошибка',
      () async {
        await seedProfile();
        expect(await repo.editPrompt(_profileId, 'Исходный промт'), isFalse);
        expect((await repo.getAgent(_profileId))!.promptVersion, 1);
        await expectLater(
          repo.editPrompt(_profileId, '  '),
          throwsA(isA<AiValidationError>()),
        );
        await expectLater(
          repo.editPrompt(_profileId, 'я' * (maxPromptLength + 1)),
          throwsA(isA<AiValidationError>()),
        );
      },
    );

    test(
      'откат: новая версия с текстом старой, история не переписывается',
      () async {
        await seedProfile();
        await repo.editPrompt(_profileId, 'Версия два');
        await repo.editPrompt(_profileId, 'Версия три');
        expect(await repo.rollbackPrompt(_profileId, 1), isTrue);
        final profile = (await repo.getAgent(_profileId))!;
        expect(profile.systemPrompt, 'Исходный промт');
        expect(profile.promptVersion, 4);
        final versions = await repo.watchPromptVersions(_profileId).first;
        expect(versions.map((v) => v.version), [4, 3, 2, 1]);
        expect(versions.first.source, PromptSource.rollback);
        expect(versions[1].text, 'Версия три', reason: 'история цела');
        await expectLater(
          repo.rollbackPrompt(_profileId, 99),
          throwsA(isA<AiValidationError>()),
        );
      },
    );

    test('пресет и модель по умолчанию у агента', () async {
      await seedProfile();
      await repo.setAgentDefaultPreset(_profileId, 'preset-1');
      await repo.setAgentDefaultModel(_profileId, 'openai/gpt-4o');
      final a = (await repo.getAgent(_profileId))!;
      expect(a.defaultContextPresetId, 'preset-1');
      expect(a.defaultModel, 'openai/gpt-4o');
      expect(a.isSeed, isTrue);
    });
  });

  group('избранные модели', () {
    const gpt = ModelInfo(
      id: 'openai/gpt-4o',
      name: 'GPT-4o',
      supportsTools: true,
    );
    const claude = ModelInfo(
      id: 'anthropic/claude-sonnet',
      name: 'Claude',
      supportsTools: true,
    );
    const llama = ModelInfo(
      id: 'meta/llama',
      name: 'Llama',
      supportsTools: false,
    );

    test('добавление по порядку, перемещение, удаление и возврат', () async {
      await repo.addFavorite(gpt);
      await repo.addFavorite(claude);
      await repo.addFavorite(llama);
      await repo.addFavorite(gpt); // повтор не плодит строк
      expect((await repo.favorites()).map((f) => f.modelId), [
        'openai/gpt-4o',
        'anthropic/claude-sonnet',
        'meta/llama',
      ]);
      await repo.moveFavorite('meta/llama', -1);
      await repo.moveFavorite('openai/gpt-4o', -1); // уже первая: ничего
      expect((await repo.favorites()).map((f) => f.modelId), [
        'openai/gpt-4o',
        'meta/llama',
        'anthropic/claude-sonnet',
      ]);
      await repo.removeFavorite('meta/llama');
      expect((await repo.favorites()).map((f) => f.modelId), [
        'openai/gpt-4o',
        'anthropic/claude-sonnet',
      ]);
      await repo.addFavorite(llama);
      final back = await repo.favorites();
      expect(back.last.modelId, 'meta/llama');
      expect(back.last.supportsTools, isFalse);
      expect(back.map((f) => f.id).toSet(), hasLength(3));
    });
  });

  group('пресеты контекста', () {
    test('создание, правка, чувствительность, удаление в корзину', () async {
      final id = await repo.createPreset('  Неделя  ', const [
        ContextSourceRef(source: 'tasks', filter: {'range': 'week'}),
        ContextSourceRef(source: 'events', tokenLimit: 800),
      ], sensitive: false);
      var p = (await repo.getPreset(id))!;
      expect(p.name, 'Неделя');
      expect(p.sources, hasLength(2));
      expect(p.sources.first.filter, {'range': 'week'});
      expect(p.sources.last.tokenLimit, 800);
      expect(p.sensitive, isFalse);

      await repo.updatePreset(id, 'Финансы', const [], sensitive: true);
      p = (await repo.getPreset(id))!;
      expect(p.name, 'Финансы');
      expect(p.sensitive, isTrue);
      expect(p.sources, isEmpty);

      await repo.deletePreset(id);
      expect(await repo.getPreset(id), isNull);
      expect(
        (await store.trashItems()).map((t) => t.table),
        contains('ai_context_presets'),
      );
    });

    test('проверки: пустое имя, длинное имя, больше 32 источников', () async {
      await expectLater(
        repo.createPreset(' ', const [], sensitive: false),
        throwsA(isA<AiValidationError>()),
      );
      await expectLater(
        repo.createPreset('я' * 101, const [], sensitive: false),
        throwsA(isA<AiValidationError>()),
      );
      await expectLater(
        repo.createPreset('много', [
          for (var i = 0; i < 33; i++) ContextSourceRef(source: 's$i'),
        ], sensitive: false),
        throwsA(isA<AiValidationError>()),
      );
    });
  });
}
