import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/hlc.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_format.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/models_screen.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

import '../../support/ai_env.dart';
import '../../support/ai_ui_env.dart';
import '../../support/pump_app.dart';

const _general = '01900000-0000-7000-8000-0000000000a1';
const _finance = '01900000-0000-7000-8000-0000000000a2';
const _server = '00000000-0000-7000-8000-000000000a11';

Future<void> _seedAgents(AiRepository repo) async {
  await seedAgent(
    repo,
    AiTopic.general,
    id: _general,
    prompt: 'Ты общий помощник.',
  );
  await seedAgent(
    repo,
    AiTopic.finance,
    id: _finance,
    prompt: 'Ты финансовый помощник.',
  );
}

Finder _text(String t) => find.text(t);

String _nb(String s) => s.replaceAll(' ', ' ');

void main() {
  group('хаб настроек ИИ', () {
    testWidgets('четыре раздела и переходы', (tester) async {
      await pumpAi(tester, location: '/ai/settings');
      for (final (key, probe) in [
        ('ai-settings-agents', 'agents-screen-empty'),
        ('ai-settings-models', 'catalog-search'),
        ('ai-settings-presets', 'preset-add'),
        ('ai-settings-usage', 'limit-field'),
      ]) {
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expect(find.byKey(Key(probe)), findsOneWidget, reason: key);
        await tester.tap(find.byTooltip('Назад'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('из «Настроек» приложения есть вход в ИИ', (tester) async {
      await pumpAi(tester, location: '/settings');
      await tester.tap(find.byKey(const Key('settings-ai')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-settings-agents')), findsOneWidget);
    });
  });

  group('агенты и промты', () {
    testWidgets('пусто: агенты придут с сервера', (tester) async {
      await pumpAi(tester, location: '/ai/settings/agents');
      expect(find.byKey(const Key('agents-screen-empty')), findsOneWidget);
    });

    testWidgets('список агентов и открытие редактора', (tester) async {
      await pumpAi(tester, location: '/ai/settings/agents', seed: _seedAgents);
      expect(_text('Общий'), findsOneWidget);
      expect(_text('Финансы'), findsOneWidget);
      await tester.tap(find.byKey(const Key('agent-tile-$_general')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('prompt-field')), findsOneWidget);
      expect(find.text('Ты общий помощник.'), findsOneWidget);
    });

    testWidgets('правка промта создаёт версию; история и откат', (
      tester,
    ) async {
      final ui = await pumpAi(
        tester,
        location: '/ai/settings/agents/$_general',
        seed: _seedAgents,
      );
      expect(find.text('Системный промт · версия 1'), findsOneWidget);
      // Пока текст не менялся — «Сохранить» недоступна.
      expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('prompt-save')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'Ты строгий помощник.',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt-save')));
      await tester.pumpAndSettle();
      expect(find.text('Системный промт · версия 2'), findsOneWidget);
      expect(find.text('Сохранена версия 2'), findsOneWidget);
      expect(find.byKey(const Key('version-2')), findsOneWidget);
      expect(find.text('Версия 2 · текущая'), findsOneWidget);

      // Откат к версии 1: новая версия 3 с исходным текстом.
      await tester.ensureVisible(find.byKey(const Key('version-1')));
      await tester.tap(find.byKey(const Key('version-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('version-text')), findsOneWidget);
      expect(find.text('Ты общий помощник.'), findsWidgets);
      await tester.tap(find.byKey(const Key('version-rollback')));
      await tester.pumpAndSettle();
      expect(find.text('Системный промт · версия 3'), findsOneWidget);
      final agent = await tester.runAsync(() => ui.repo.getAgent(_general));
      expect(agent!.systemPrompt, 'Ты общий помощник.');
      expect(agent.promptVersion, 3);
    });

    testWidgets('текущая версия не откатывается', (tester) async {
      await pumpAi(
        tester,
        location: '/ai/settings/agents/$_general',
        seed: _seedAgents,
      );
      await tester.ensureVisible(find.byKey(const Key('version-1')));
      await tester.tap(find.byKey(const Key('version-1')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('version-rollback')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('«Сбросить»: подтверждение, строки сервера применяются', (
      tester,
    ) async {
      final api = FakeAiApi();
      final stamp = formatHlc(aiNow.millisecondsSinceEpoch + 60000, 0, _server);
      api.resetChanges = [
        SyncChange(
          table: 'ai_agent_profiles',
          id: _general,
          serverVersion: 50,
          row: {
            'id': _general,
            'created_at': '2026-09-01T00:00:00.000Z',
            'updated_at': stamp,
            'deleted_at': null,
            'server_version': 50,
            'origin_device_id': _server,
            'seed_key': 'general',
            'name': 'Общий',
            'topic': 'general',
            'system_prompt': 'Исходный промт сервера.',
            'prompt_version': 2,
            'default_model': null,
            'enabled_tools': const <Object?>[],
            'default_context_preset_id': null,
            'position': 0,
          },
        ),
        SyncChange(
          table: 'ai_prompt_versions',
          id: promptVersionId(_general, 2),
          serverVersion: 51,
          row: {
            'id': promptVersionId(_general, 2),
            'created_at': '2026-09-01T00:00:00.000Z',
            'updated_at': stamp,
            'deleted_at': null,
            'server_version': 51,
            'origin_device_id': _server,
            'profile_id': _general,
            'version': 2,
            'text': 'Исходный промт сервера.',
            'source': 'reset',
          },
        ),
      ];
      final ui = await pumpAi(
        tester,
        location: '/ai/settings/agents/$_general',
        api: api,
        seed: _seedAgents,
      );
      // Агенты пришли с сервера: неотправленных правок у них нет.
      await tester.runAsync(ui.sync);
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt-reset')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tester.tap(find.text('Сбросить').last);
      await tester.pumpAndSettle();
      expect(api.resets, ['general']);
      expect(find.text('Исходный промт сервера.'), findsOneWidget);
      expect(find.text('Системный промт · версия 2'), findsOneWidget);
      expect(find.text('Версия 2 · текущая'), findsOneWidget);
    });

    testWidgets('сброс без сети: понятное сообщение, промт цел', (
      tester,
    ) async {
      final api = FakeAiApi()..resetError = const ApiException.network('x');
      await pumpAi(
        tester,
        location: '/ai/settings/agents/$_general',
        api: api,
        seed: _seedAgents,
      );
      await tester.tap(find.byKey(const Key('prompt-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сбросить').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Нет сети'), findsOneWidget);
      expect(find.text('Ты общий помощник.'), findsOneWidget);
    });

    testWidgets('пресет контекста по умолчанию у агента', (tester) async {
      final ui = await pumpAi(
        tester,
        location: '/ai/settings/agents/$_general',
        seed: (repo) async {
          await _seedAgents(repo);
          await repo.createPreset('Неделя', const [
            ContextSourceRef(source: 'tasks'),
          ], sensitive: false);
        },
      );
      final presets = await tester.runAsync(() => ui.repo.watchPresets().first);
      final id = presets!.single.id;
      await tester.ensureVisible(find.byKey(Key('agent-preset-$id')));
      await tester.tap(find.byKey(Key('agent-preset-$id')));
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(() => ui.repo.getAgent(_general)))!
            .defaultContextPresetId,
        id,
      );
      await tester.tap(find.byKey(const Key('agent-preset-none')));
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(() => ui.repo.getAgent(_general)))!
            .defaultContextPresetId,
        isNull,
      );
    });

    testWidgets('агента нет: понятная заглушка', (tester) async {
      await pumpAi(tester, location: '/ai/settings/agents/no-such');
      expect(find.text('Агент не найден'), findsOneWidget);
    });
  });

  group('модели быстрого выбора', () {
    testWidgets('каталог, звёздочка, порядок, удаление', (tester) async {
      final ui = await pumpAi(tester, location: '/ai/settings/models');
      expect(find.byKey(const Key('favorites-empty')), findsOneWidget);
      expect(find.byKey(const Key('catalog-openai/gpt-4o')), findsOneWidget);
      expect(find.textContaining('вход 250'), findsOneWidget);

      await tester.tap(find.byKey(const Key('catalog-star-openai/gpt-4o')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('catalog-star-anthropic/claude-sonnet')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('favorites-empty')), findsNothing);
      expect(find.byKey(const Key('favorite-openai/gpt-4o')), findsOneWidget);

      await tester.tap(find.byKey(const Key('favorite-down-openai/gpt-4o')));
      await tester.pumpAndSettle();
      var favorites = await tester.runAsync(() => ui.repo.favorites());
      expect(favorites!.map((f) => f.modelId), [
        'anthropic/claude-sonnet',
        'openai/gpt-4o',
      ]);

      await tester.tap(
        find.byKey(const Key('favorite-remove-anthropic/claude-sonnet')),
      );
      await tester.pumpAndSettle();
      favorites = await tester.runAsync(() => ui.repo.favorites());
      expect(favorites!.map((f) => f.modelId), ['openai/gpt-4o']);
    });

    testWidgets('поиск по каталогу', (tester) async {
      await pumpAi(tester, location: '/ai/settings/models');
      await typeInto(tester, 'catalog-search', 'llama');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-meta/llama-small')), findsOneWidget);
      expect(find.byKey(const Key('catalog-openai/gpt-4o')), findsNothing);
    });

    testWidgets(
      'каталог недоступен: сообщение, избранные продолжают работать',
      (tester) async {
        final api = FakeAiApi()..modelsError = const ApiException.network('x');
        await pumpAi(
          tester,
          location: '/ai/settings/models',
          api: api,
          seed: (repo) => repo.addFavorite(
            const ModelInfo(
              id: 'openai/gpt-4o',
              name: 'GPT-4o',
              supportsTools: true,
            ),
          ),
        );
        expect(find.byKey(const Key('catalog-error')), findsOneWidget);
        expect(find.byKey(const Key('favorite-openai/gpt-4o')), findsOneWidget);
      },
    );

    testWidgets(
      'обновление каталога просит сервер обновить кэш; недоступная избранная помечена',
      (tester) async {
        final api = FakeAiApi();
        await pumpAi(
          tester,
          location: '/ai/settings/models',
          api: api,
          seed: (repo) => repo.addFavorite(
            const ModelInfo(
              id: 'old/retired',
              name: 'Старая',
              supportsTools: false,
            ),
          ),
        );
        expect(find.text('Недоступна в каталоге'), findsOneWidget);
        await tester.tap(find.byKey(const Key('catalog-refresh')));
        await tester.pumpAndSettle();
        expect(api.lastRefresh, isTrue);
      },
    );

    testWidgets('устаревший каталог помечен', (tester) async {
      final api = FakeAiApi(
        catalog: const ModelCatalog(models: [], stale: true),
      );
      await pumpAi(tester, location: '/ai/settings/models', api: api);
      expect(find.textContaining('сохранённый каталог'), findsOneWidget);
    });

    test('подпись цены модели', () {
      expect(
        priceLabel(const ModelInfo(id: 'a', name: 'A', supportsTools: false)),
        'цена не указана',
      );
    });
  });

  group('пресеты контекста', () {
    testWidgets('пусто → создать → правка → удаление', (tester) async {
      final ui = await pumpAi(tester, location: '/ai/settings/presets');
      expect(find.text('Пресетов пока нет'), findsOneWidget);
      await tester.tap(find.byKey(const Key('preset-empty-add')));
      await tester.pumpAndSettle();
      // Пустое название — ошибка.
      await tester.tap(find.byKey(const Key('preset-field-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preset-error')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('preset-field-name')),
        'Неделя',
      );
      await tester.tap(find.byKey(const Key('context-source-tasks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('context-filter-tasks-month')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('preset-field-save')));
      await tester.pumpAndSettle();
      expect(find.text('Неделя'), findsOneWidget);
      expect(find.text('Задачи'), findsOneWidget);
      var presets = await tester.runAsync(() => ui.repo.watchPresets().first);
      expect(presets!.single.sources.single.filter, {'range': 'month'});

      // Правка: пометка «не в облако».
      await tester.tap(find.text('Неделя'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('preset-field-sensitive')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('preset-field-save')));
      await tester.pumpAndSettle();
      expect(find.text('Неделя · не в облако'), findsOneWidget);
      presets = await tester.runAsync(() => ui.repo.watchPresets().first);
      expect(presets!.single.sensitive, isTrue);

      // Удаление с подтверждением.
      await tester.tap(find.text('Неделя · не в облако'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('preset-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить').last);
      await tester.pumpAndSettle();
      expect(find.text('Пресетов пока нет'), findsOneWidget);
    });

    testWidgets('кнопка «+» в панели открывает форму', (tester) async {
      await pumpAi(tester, location: '/ai/settings/presets');
      await tester.tap(find.byKey(const Key('preset-add')));
      await tester.pumpAndSettle();
      expect(find.text('Новый пресет'), findsOneWidget);
    });
  });

  group('расход и лимит', () {
    testWidgets('данные: сумма в рублях, запросы, по моделям, полоса лимита', (
      tester,
    ) async {
      final api = FakeAiApi();
      await pumpAi(tester, location: '/ai/settings/usage', api: api);
      expect(
        tester.widget<Text>(find.byKey(const Key('usage-total'))).data,
        _nb('12,34 ₽'),
      );
      expect(find.textContaining('12 запросов'), findsOneWidget);
      expect(find.textContaining(_nb('49 000')), findsOneWidget);
      expect(
        find.byKey(const Key('usage-model-openai/gpt-4o')),
        findsOneWidget,
      );
      expect(find.text('октябрь 2026'), findsNothing);
      // Месяц — текущий месяц биллинга (30 сентября 2026 11:40 МСК).
      expect(find.text('сентябрь 2026'), findsOneWidget);
      expect(api.usageMonths, contains('2026-09'));
    });

    testWidgets('месяцы листаются назад; вперёд — только до текущего', (
      tester,
    ) async {
      final api = FakeAiApi();
      await pumpAi(tester, location: '/ai/settings/usage', api: api);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('usage-next')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('usage-prev')));
      await tester.pumpAndSettle();
      expect(find.text('август 2026'), findsOneWidget);
      expect(api.usageMonths, contains('2026-08'));
      await tester.tap(find.byKey(const Key('usage-next')));
      await tester.pumpAndSettle();
      expect(find.text('сентябрь 2026'), findsOneWidget);
    });

    testWidgets('нет сети: ошибка и «Повторить», лимит всё равно доступен', (
      tester,
    ) async {
      final api = FakeAiApi()..usageError = const ApiException.network('x');
      await pumpAi(tester, location: '/ai/settings/usage', api: api);
      expect(find.byKey(const Key('usage-error')), findsOneWidget);
      expect(find.byKey(const Key('limit-field')), findsOneWidget);
      api.usageError = null;
      await tester.tap(find.byKey(const Key('usage-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usage-total')), findsOneWidget);
    });

    testWidgets('лимит: сохраняется в копейках, предупреждение 80 %, снятие', (
      tester,
    ) async {
      final api = FakeAiApi()
        ..usageValue = const UsageSummary(
          month: '2026-09',
          spentKopecks: 41000,
          requests: 5,
          promptTokens: 1,
          completionTokens: 1,
        );
      final ui = await pumpAi(tester, location: '/ai/settings/usage', api: api);
      expect(find.byKey(const Key('usage-bar')), findsNothing);
      await typeInto(tester, 'limit-field', '500');
      await tester.tap(find.byKey(const Key('limit-save')));
      await tester.pumpAndSettle();
      final stored = await tester.runAsync(
        () => ui.container
            .read(userSettingsRepositoryProvider)
            .read(monthlyLimitKey),
      );
      expect(stored, 50000, reason: 'целые копейки');
      expect(find.byKey(const Key('usage-bar')), findsOneWidget);
      expect(find.byKey(const Key('usage-warning-text')), findsOneWidget);
      expect(find.textContaining('более 80'), findsOneWidget);

      await typeInto(tester, 'limit-field', '12,50');
      await tester.tap(find.byKey(const Key('limit-save')));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(
          () => ui.container
              .read(userSettingsRepositoryProvider)
              .read(monthlyLimitKey),
        ),
        1250,
      );
      expect(find.textContaining('Лимит исчерпан'), findsOneWidget);

      await tester.tap(find.byKey(const Key('limit-remove')));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(
          () => ui.container
              .read(userSettingsRepositoryProvider)
              .read(monthlyLimitKey),
        ),
        isNull,
      );
      expect(find.byKey(const Key('usage-bar')), findsNothing);
    });

    testWidgets('неверная сумма — ошибка, лимит не меняется', (tester) async {
      final ui = await pumpAi(tester, location: '/ai/settings/usage');
      await typeInto(tester, 'limit-field', 'много');
      await tester.tap(find.byKey(const Key('limit-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('limit-error')), findsOneWidget);
      expect(
        await tester.runAsync(
          () => ui.container
              .read(userSettingsRepositoryProvider)
              .read(monthlyLimitKey),
        ),
        isNull,
      );
    });

    testWidgets('нулевой лимит блокирует всё: полоса полная', (tester) async {
      final ui = await pumpAi(tester, location: '/ai/settings/usage');
      await typeInto(tester, 'limit-field', '0');
      await tester.tap(find.byKey(const Key('limit-save')));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(
          () => ui.container
              .read(userSettingsRepositoryProvider)
              .read(monthlyLimitKey),
        ),
        0,
      );
      expect(find.textContaining('Лимит исчерпан'), findsOneWidget);
    });

    testWidgets('лимит из настроек подставляется в поле', (tester) async {
      await pumpAi(
        tester,
        location: '/ai/settings/usage',
        overrides: [
          monthlyLimitProvider.overrideWith((ref) => Stream.value(75000)),
        ],
      );
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('limit-field')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        '750',
      );
    });
  });

  testWidgets('десктоп: настройки открываются', (tester) async {
    await pumpAi(tester, size: desktopSize, location: '/ai/settings/usage');
    expect(find.byKey(const Key('limit-field')), findsOneWidget);
  });

  test('месячный лимит в ключе настроек и подпись месяца', () {
    expect(monthlyLimitKey, 'ai.monthly_limit_kopecks');
    expect(monthLabel('2026-09'), 'сентябрь 2026');
  });
}
