import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/llama_cpp_engine.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';

void main() {
  const file = LlmModelFile(modelId: 'm', path: '/tmp/m', contextTokens: 1024);

  group('заглушка для платформ без офлайн-модели (Windows)', () {
    const engine = UnsupportedLlmEngine();

    test('«недоступно» с понятным текстом на любую попытку', () async {
      expect(engine.isSupported, isFalse);
      expect(engine.isLoaded, isFalse);
      expect(engine.loadedModel, isNull);
      expect(engine.lastStats, isNull);
      expect(engine.unsupportedReason, contains('только на Android'));
      await expectLater(
        engine.load(file),
        throwsA(
          isA<LocalLlmException>()
              .having(
                (e) => e.kind,
                'kind',
                LocalLlmErrorKind.unsupportedPlatform,
              )
              .having((e) => e.message, 'message', contains('Android')),
        ),
      );
      await expectLater(
        engine.generate(const [
          LlmTurn.user('привет'),
        ], const LlmGenerationParams()),
        emitsError(isA<LocalLlmException>()),
      );
      await engine.cancel();
      await engine.unload();
    });
  });

  group('заготовка llama.cpp', () {
    const engine = LlamaCppEngine();

    test('не подключена: честная ошибка «не готово»', () async {
      expect(engine.id, 'llama_cpp');
      expect(engine.isSupported, isFalse);
      expect(engine.isLoaded, isFalse);
      expect(engine.loadedModel, isNull);
      expect(engine.lastStats, isNull);
      expect(engine.unsupportedReason, contains('llama.cpp'));
      await expectLater(
        engine.load(file),
        throwsA(
          isA<LocalLlmException>().having(
            (e) => e.kind,
            'kind',
            LocalLlmErrorKind.notImplemented,
          ),
        ),
      );
      await expectLater(
        engine.generate(const [
          LlmTurn.user('привет'),
        ], const LlmGenerationParams()),
        emitsError(isA<LocalLlmException>()),
      );
      await engine.cancel();
      await engine.unload();
    });
  });

  group('значения интерфейса', () {
    test('реплики сравниваются по значению', () {
      expect(const LlmTurn.user('а'), const LlmTurn.user('а'));
      expect(const LlmTurn.user('а'), isNot(const LlmTurn.model('а')));
      expect(
        const LlmTurn.system('а').hashCode,
        const LlmTurn.system('а').hashCode,
      );
      expect(const LlmTurn.user('привет').toString(), 'user: привет');
    });

    test('параметры генерации: умолчания и copyWith', () {
      const params = LlmGenerationParams();
      expect(params.maxOutputTokens, 512);
      final changed = params.copyWith(maxOutputTokens: 100, temperature: 0.9);
      expect(changed.maxOutputTokens, 100);
      expect(changed.temperature, 0.9);
      expect(changed.topK, params.topK);
      expect(
        const LocalLlmException(LocalLlmErrorKind.busy, 'занято').toString(),
        contains('busy'),
      );
    });
  });
}
