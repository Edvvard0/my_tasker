import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/core/local_llm/chat_routing.dart';
import 'package:my_tasker/core/local_llm/local_chat_service.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/network_probe.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/local_ai/application/local_ai_providers.dart';
import 'package:my_tasker/features/local_ai/presentation/local_ai_settings_tile.dart';
import 'package:my_tasker/features/local_ai/presentation/mode_switch.dart';
import 'package:my_tasker/features/local_ai/presentation/route_banner.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

import '../../support/fake_llm.dart';
import '../../support/pump_app.dart';

final List<int> _content = List.generate(64, (i) => (i * 5 + 1) % 251);

/// Настройка окружения экранов: поддельные движок, сеть и загрузка, каталог
/// моделей во временной папке.
class _Env {
  _Env({bool supported = true})
    : engine = FakeLlmEngine(supported: supported),
      downloader = FakeDownloader(_content),
      resources = FakeResources(),
      network = FakeNetwork(),
      dir = Directory.systemTemp.createTempSync('local_ai_ui');

  final FakeLlmEngine engine;
  final FakeDownloader downloader;
  final FakeResources resources;
  final FakeNetwork network;
  final Directory dir;

  List<Override> get overrides => [
    localLlmEngineProvider.overrideWithValue(engine),
    modelsDirProvider.overrideWithValue(() async => dir),
    modelDownloaderProvider.overrideWithValue(downloader),
    deviceResourcesProvider.overrideWithValue(resources),
    networkProbeProvider.overrideWithValue(network),
  ];

  /// Модель уже скачана и проверена.
  void installModel() {
    File('${dir.path}/${gemma4E2b.fileName}').writeAsBytesSync(_content);
    File('${dir.path}/${gemma4E2b.fileName}.ok')
        .writeAsStringSync('${_content.length} ${'a' * 64}');
  }

  void dispose() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Реальный ввод-вывод в виджет-тесте идёт вне фейковых часов: чередуем
/// ожидание настоящего цикла событий и кадры, пока не выполнено [until].
Future<void> _io(WidgetTester tester, {bool Function()? until}) async {
  for (var i = 0; i < 120; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    if (until != null && until()) break;
  }
  await tester.pump();
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  _Env env, {
  String location = '/ai/settings/local',
}) async {
  addTearDown(env.dispose);
  final container = await pumpApp(
    tester,
    location: location,
    overrides: env.overrides,
    settle: false,
  );
  await _io(tester);
  return container;
}

void main() {
  group('экран «Офлайн-модель» (через маршрут)', () {
    testWidgets('скачать -> скачана -> удалить', (tester) async {
      final env = _Env();
      final container = await _open(tester, env);
      expect(find.text('Офлайн-модель'), findsWidgets);
      expect(find.byKey(const Key('local-download')), findsOneWidget);

      await tester.tap(find.byKey(const Key('local-download')));
      await _io(
        tester,
        until: () =>
            container.read(localAvailabilityProvider) ==
            LocalAvailability.ready,
      );

      expect(find.byKey(const Key('local-benchmark')), findsOneWidget);
      expect(find.byKey(const Key('local-checksum')), findsOneWidget);
      expect(
        container.read(localAvailabilityProvider),
        LocalAvailability.ready,
      );
      expect(
        File('${env.dir.path}/${gemma4E2b.fileName}').existsSync(),
        isTrue,
      );

      await tester.tap(find.byKey(const Key('local-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await _io(
        tester,
        until: () =>
            container.read(localAvailabilityProvider) ==
            LocalAvailability.modelNotReady,
      );
      expect(find.byKey(const Key('local-download')), findsOneWidget);
      expect(
        container.read(localAvailabilityProvider),
        LocalAvailability.modelNotReady,
      );
    });

    testWidgets('на мобильной сети ждёт Wi-Fi, переключатель пишет настройку', (
      tester,
    ) async {
      final env = _Env()..network.kind = NetworkKind.cellular;
      final container = await _open(tester, env);
      await tester.tap(find.byKey(const Key('local-download')));
      await _io(
        tester,
        until: () =>
            find.textContaining('появится Wi-Fi').evaluate().isNotEmpty,
      );
      expect(find.textContaining('появится Wi-Fi'), findsOneWidget);
      expect(env.downloader.calls, 0);
      await tester.tap(find.byKey(const Key('local-pause')));
      await _io(
        tester,
        until: () =>
            find.byKey(const Key('local-resume')).evaluate().isNotEmpty,
      );

      await tester.tap(find.byKey(const Key('local-wifi-only')));
      await _io(
        tester,
        until: () => container.read(wifiOnlyProvider).value == false,
      );
      final value = await tester.runAsync(
        () => container.read(userSettingsRepositoryProvider).read(wifiOnlyKey),
      );
      expect(value, isFalse);
      expect(container.read(wifiOnlyProvider).value, isFalse);
    });

    testWidgets('платформа без офлайн-модели: «недоступно»', (tester) async {
      final env = _Env(supported: false);
      final container = await _open(tester, env);
      expect(find.byKey(const Key('local-unsupported')), findsOneWidget);
      expect(find.byKey(const Key('local-download')), findsNothing);
      expect(
        container.read(localAvailabilityProvider),
        LocalAvailability.unsupportedPlatform,
      );
    });
  });

  group('экран замеров', () {
    testWidgets('модель не скачана: запуск заблокирован', (tester) async {
      await _open(tester, _Env(), location: '/ai/settings/local/benchmark');
      expect(find.byKey(const Key('bench-unavailable')), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('bench-start')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('прогон 20 фраз и копирование отчёта', (tester) async {
      final env = _Env()..installModel();
      final container = await _open(
        tester,
        env,
        location: '/ai/settings/local/benchmark',
      );
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.runAsync(
        () => container.read(benchmarkControllerProvider.notifier).start(),
      );
      await tester.pump();

      final state = container.read(benchmarkControllerProvider);
      expect(state.report, isNotNull);
      expect(state.report!.items.length, 20);
      expect(env.engine.loads, 1);
      expect(find.byKey(const Key('bench-report')), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('bench-report')))
            .data,
        contains('Тест локальной модели'),
      );

      await tester.tap(find.byKey(const Key('bench-copy')));
      await tester.pump();
      expect(clipboard, state.report!.toText());
      expect(find.text('Отчёт скопирован'), findsOneWidget);
    });

    testWidgets('недоступная ОЗУ: понятная ошибка вместо прогона', (
      tester,
    ) async {
      final env = _Env()..installModel();
      env.resources.totalRam = 3 * 1024 * 1024 * 1024;
      final container = await _open(
        tester,
        env,
        location: '/ai/settings/local/benchmark',
      );
      await tester.runAsync(
        () => container.read(benchmarkControllerProvider.notifier).start(),
      );
      await tester.pump();
      expect(find.byKey(const Key('bench-error')), findsOneWidget);
      expect(find.textContaining('ОЗУ'), findsWidgets);
      expect(env.engine.loads, 0);
    });
  });

  group('переключатель режима и плашка маршрута', () {
    Future<List<String>> pumpSwitch(
      WidgetTester tester, {
      required LocalAvailability availability,
      ChatMode mode = ChatMode.cloud,
      String? unsupportedReason,
    }) async {
      final log = <String>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: Center(
                child: ChatModeSwitch(
                  conversationId: 'c1',
                  mode: mode,
                  onSwitched: (m) => log.add('switched:${m.name}'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/ai/settings/local',
            builder: (_, _) => const Scaffold(body: Text('экран моделей')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localAvailabilityProvider.overrideWithValue(availability),
            localLlmEngineProvider.overrideWithValue(
              FakeLlmEngine(
                supported:
                    availability != LocalAvailability.unsupportedPlatform,
              ),
            ),
            localChatServiceProvider.overrideWithValue(_FakeService(log)),
          ],
          child: MaterialApp.router(
            theme: AppTheme.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return log;
    }

    testWidgets('модель готова: переключение в local и обратно', (
      tester,
    ) async {
      final log = await pumpSwitch(
        tester,
        availability: LocalAvailability.ready,
      );
      await tester.tap(find.text('На устройстве'));
      await tester.pumpAndSettle();
      expect(log, ['switch:c1:local', 'switched:local']);
      // Тот же режим — ничего.
      log.clear();
      await tester.tap(find.text('Облако'));
      await tester.pumpAndSettle();
      expect(log, isEmpty);
    });

    testWidgets('из local обратно в облако', (tester) async {
      final log = await pumpSwitch(
        tester,
        availability: LocalAvailability.ready,
        mode: ChatMode.local,
      );
      await tester.tap(find.text('Облако'));
      await tester.pumpAndSettle();
      expect(log, ['switch:c1:cloud', 'switched:cloud']);
    });

    testWidgets('модели нет: предлагается скачать, режим не меняется', (
      tester,
    ) async {
      final log = await pumpSwitch(
        tester,
        availability: LocalAvailability.modelNotReady,
      );
      await tester.tap(find.text('На устройстве'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(find.text('экран моделей'), findsOneWidget);
      expect(log, isEmpty);
    });

    testWidgets('платформа без модели: объяснение, режим не меняется', (
      tester,
    ) async {
      final log = await pumpSwitch(
        tester,
        availability: LocalAvailability.unsupportedPlatform,
      );
      await tester.tap(find.text('На устройстве'));
      await tester.pumpAndSettle();
      expect(find.text('Не поддерживается'), findsOneWidget);
      expect(log, isEmpty);
    });

    testWidgets('плашка маршрута: действия по решению', (tester) async {
      final log = <String>[];
      Future<void> show(RouteDecision d) => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: LocalRouteBanner(
              decision: d,
              onContinueLocally: () => log.add('local'),
              onSendToCloud: () => log.add('cloud'),
              onOpenModels: () => log.add('models'),
            ),
          ),
        ),
      );

      await show(
        decideRoute(
          mode: ChatMode.cloud,
          online: false,
          local: LocalAvailability.ready,
        ),
      );
      expect(find.textContaining('Нет сети'), findsOneWidget);
      await tester.tap(find.byKey(const Key('route-continue-local')));

      await show(
        decideRoute(
          mode: ChatMode.cloud,
          online: false,
          local: LocalAvailability.modelNotReady,
        ),
      );
      expect(find.textContaining('сохранено'), findsOneWidget);
      await tester.tap(find.byKey(const Key('route-send-cloud')));

      await show(
        decideRoute(
          mode: ChatMode.local,
          online: true,
          local: LocalAvailability.modelNotReady,
        ),
      );
      await tester.tap(find.byKey(const Key('route-open-models')));
      await tester.tap(find.byKey(const Key('route-send-cloud')));
      expect(log, ['local', 'cloud', 'models', 'cloud']);

      await show(
        decideRoute(
          mode: ChatMode.cloud,
          online: true,
          local: LocalAvailability.ready,
        ),
      );
      expect(find.byKey(const Key('route-banner')), findsNothing);
    });

    testWidgets('строка настроек ведёт на экран моделей', (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: LocalAiSettingsTile()),
          ),
          GoRoute(
            path: '/ai/settings/local',
            builder: (_, _) => const Scaffold(body: Text('экран моделей')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
      );
      expect(find.text('Офлайн-модель'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai-settings-local')));
      await tester.pumpAndSettle();
      expect(find.text('экран моделей'), findsOneWidget);
    });
  });

  group('маршрутизация через провайдеры', () {
    test('решение зависит от режима, сети и готовности модели', () {
      ProviderContainer make({
        required bool online,
        required LocalAvailability a,
      }) {
        final c = ProviderContainer(
          overrides: [
            isOnlineProvider.overrideWithValue(AsyncData(online)),
            localAvailabilityProvider.overrideWithValue(a),
          ],
        );
        addTearDown(c.dispose);
        return c;
      }

      expect(
        make(
          online: true,
          a: LocalAvailability.ready,
        ).read(routeDecisionProvider(ChatMode.cloud)).action,
        ChatRouteAction.sendCloud,
      );
      expect(
        make(
          online: false,
          a: LocalAvailability.ready,
        ).read(routeDecisionProvider(ChatMode.cloud)).action,
        ChatRouteAction.offerLocal,
      );
      expect(
        make(
          online: false,
          a: LocalAvailability.modelNotReady,
        ).read(routeDecisionProvider(ChatMode.cloud)).action,
        ChatRouteAction.holdForNetwork,
      );
      expect(
        make(
          online: false,
          a: LocalAvailability.ready,
        ).read(routeDecisionProvider(ChatMode.local)).action,
        ChatRouteAction.sendLocal,
      );
    });
  });
}

/// Сервис, записывающий переключения режима.
class _FakeService implements LocalChatService {
  _FakeService(this.log);

  final List<String> log;

  @override
  bool get isGenerating => false;

  @override
  Future<void> switchMode(
    String conversationId,
    ChatMode mode, {
    String? model,
  }) async => log.add('switch:$conversationId:${mode.name}');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
