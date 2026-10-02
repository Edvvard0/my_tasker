import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/chat_routing.dart';
import 'package:my_tasker/core/local_llm/llama_cpp_engine.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/features/local_ai/application/local_ai_providers.dart';

import '../../support/fake_llm.dart';

final List<int> _content = List.generate(32, (i) => i + 1);

void main() {
  late Directory dir;
  late FakeLlmEngine engine;
  late FakeResources resources;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('local_ai_providers');
    engine = FakeLlmEngine();
    resources = FakeResources();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ProviderContainer make({List<Override> extra = const []}) {
    final container = ProviderContainer(
      overrides: [
        localLlmEngineProvider.overrideWithValue(engine),
        modelsDirProvider.overrideWithValue(() async => dir),
        deviceResourcesProvider.overrideWithValue(resources),
        networkProbeProvider.overrideWithValue(FakeNetwork()),
        modelDownloaderProvider.overrideWithValue(FakeDownloader(_content)),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void install() {
    File('${dir.path}/${gemma4E2b.fileName}').writeAsBytesSync(_content);
    File('${dir.path}/${gemma4E2b.fileName}.ok')
        .writeAsStringSync('${_content.length} ${'b' * 64}');
  }

  test('на хосте без Android по умолчанию — заглушка «недоступно»', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    if (!Platform.isAndroid) {
      expect(
        container.read(localLlmEngineProvider),
        isA<UnsupportedLlmEngine>(),
      );
    }
  });

  group('загрузка модели в движок перед ответом', () {
    test('модели нет на диске: понятная ошибка', () async {
      final container = make();
      late Ref captured;
      final probe = Provider<int>((ref) {
        captured = ref;
        return 0;
      });
      container.read(probe);
      await expectLater(
        ensureLocalModelLoaded(captured, gemma4E2b.id),
        throwsA(
          isA<LocalLlmException>()
              .having((e) => e.kind, 'kind', LocalLlmErrorKind.notLoaded)
              .having((e) => e.message, 'message', contains('не скачана')),
        ),
      );
      expect(engine.loads, 0);
    });

    test('не хватает ОЗУ: отказ до загрузки', () async {
      install();
      resources.availableRam = 512 * 1024 * 1024;
      final container = make();
      late Ref captured;
      container.read(
        Provider<int>((ref) {
          captured = ref;
          return 0;
        }),
      );
      await expectLater(
        ensureLocalModelLoaded(captured, gemma4E2b.id),
        throwsA(
          isA<LocalLlmException>().having(
            (e) => e.kind,
            'kind',
            LocalLlmErrorKind.outOfMemory,
          ),
        ),
      );
      expect(engine.loads, 0);
    });

    test(
      'модель есть: грузится один раз, повторный вызов ничего не делает',
      () async {
        install();
        final container = make();
        late Ref captured;
        container.read(
          Provider<int>((ref) {
            captured = ref;
            return 0;
          }),
        );
        await ensureLocalModelLoaded(captured, gemma4E2b.id);
        await ensureLocalModelLoaded(captured, gemma4E2b.id);
        expect(engine.loads, 1);
        expect(engine.loadedModel?.modelId, gemma4E2b.id);
      },
    );
  });

  group('готовность локального режима', () {
    test(
      'модель скачана -> ready; платформа без модели -> unsupported',
      () async {
        install();
        final container = make()..listen(localModelStatesProvider, (_, _) {});
        await container.read(localModelStatesProvider.future);
        expect(
          container.read(localAvailabilityProvider),
          LocalAvailability.ready,
        );

        final unsupported = ProviderContainer(
          overrides: [
            localLlmEngineProvider.overrideWithValue(
              FakeLlmEngine(supported: false),
            ),
          ],
        );
        addTearDown(unsupported.dispose);
        expect(
          unsupported.read(localAvailabilityProvider),
          LocalAvailability.unsupportedPlatform,
        );
      },
    );

    test('модели нет -> modelNotReady; сведения об устройстве', () async {
      final container = make()..listen(localModelStatesProvider, (_, _) {});
      await container.read(localModelStatesProvider.future);
      expect(
        container.read(localAvailabilityProvider),
        LocalAvailability.modelNotReady,
      );
      final info = await container.read(localDeviceInfoProvider.future);
      expect(info.usedBytes, 0);
      expect(info.freeBytes, resources.free);
      expect(info.totalRamBytes, resources.totalRam);
    });
  });
}
