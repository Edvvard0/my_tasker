import 'package:flutter/foundation.dart';

/// Роль реплики в запросе к локальной модели.
enum LlmRole { system, user, model }

/// Одна реплика запроса. Платформенные адаптеры сами приводят список реплик
/// к формату рантайма (SDK-шаблон у LiteRT-LM, `ChatTemplate` у llama.cpp).
@immutable
class LlmTurn {
  const LlmTurn(this.role, this.text);

  const LlmTurn.system(String text) : this(LlmRole.system, text);
  const LlmTurn.user(String text) : this(LlmRole.user, text);
  const LlmTurn.model(String text) : this(LlmRole.model, text);

  final LlmRole role;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is LlmTurn && other.role == role && other.text == text;

  @override
  int get hashCode => Object.hash(role, text);

  @override
  String toString() => '${role.name}: $text';
}

/// Параметры одной генерации.
@immutable
class LlmGenerationParams {
  const LlmGenerationParams({
    this.maxOutputTokens = 512,
    this.temperature = 0.4,
    this.topK = 40,
    this.topP,
    this.seed = 1,
  });

  /// Предел длины ответа (не окно контекста).
  final int maxOutputTokens;
  final double temperature;
  final int topK;
  final double? topP;
  final int seed;

  LlmGenerationParams copyWith({int? maxOutputTokens, double? temperature}) =>
      LlmGenerationParams(
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
        temperature: temperature ?? this.temperature,
        topK: topK,
        topP: topP,
        seed: seed,
      );
}

/// Файл модели на диске, который движок должен загрузить.
@immutable
class LlmModelFile {
  const LlmModelFile({
    required this.modelId,
    required this.path,
    required this.contextTokens,
  });

  /// Идентификатор из каталога (`LocalModelSpec.id`).
  final String modelId;
  final String path;

  /// Окно контекста (вход + выход), с которым загружается модель.
  final int contextTokens;
}

/// Сведения о загруженной модели.
@immutable
class LlmModelInfo {
  const LlmModelInfo({
    required this.modelId,
    required this.engineId,
    required this.contextTokens,
    this.backend,
  });

  final String modelId;
  final String engineId;
  final int contextTokens;

  /// Фактический бэкенд («cpu»), если рантайм его сообщает.
  final String? backend;
}

/// Метрики рантайма по последней генерации (если он их отдаёт).
@immutable
class LlmRuntimeStats {
  const LlmRuntimeStats({
    this.inputTokens,
    this.outputTokens,
    this.timeToFirstTokenMs,
    this.tokensPerSecond,
  });

  final int? inputTokens;
  final int? outputTokens;
  final double? timeToFirstTokenMs;
  final double? tokensPerSecond;
}

/// Причина отказа локального движка.
enum LocalLlmErrorKind {
  /// Платформа без офлайн-модели (Windows и т. д.).
  unsupportedPlatform,

  /// Модель не загружена в движок (`load` не вызывали).
  notLoaded,

  /// Не хватило памяти при загрузке или генерации.
  outOfMemory,

  /// Рантайм не смог загрузить файл модели.
  loadFailed,

  /// Ошибка во время генерации.
  generationFailed,

  /// Адаптер ещё не написан (запасной движок).
  notImplemented,

  /// Уже идёт генерация: движок один, запросы не накладываются.
  busy,
}

class LocalLlmException implements Exception {
  const LocalLlmException(this.kind, this.message);

  final LocalLlmErrorKind kind;

  /// Текст для показа пользователю (по-русски).
  final String message;

  @override
  String toString() => 'LocalLlmException(${kind.name}): $message';
}

/// Рантайм локальной модели. Единственное место, где приложение знает про
/// конкретную библиотеку; всё остальное (чат, замеры, менеджер моделей)
/// работает через этот интерфейс и тестируется на поддельном движке.
///
/// Жизненный цикл: [load] -> любое число [generate] (по одному за раз) ->
/// [unload]. Отмена — [cancel] (останавливает декодирование в рантайме) либо
/// отписка от потока токенов.
abstract interface class LocalLlmEngine {
  /// Устойчивый идентификатор рантайма: `flutter_gemma`, `llama_cpp`.
  String get id;

  /// Работает ли рантайм на этой платформе (Android-arm64: да; Windows: нет).
  bool get isSupported;

  /// Причина, по которой [isSupported] ложно (для показа); иначе `null`.
  String? get unsupportedReason;

  /// Загружена ли модель.
  bool get isLoaded;

  /// Сведения о загруженной модели; `null`, если не загружена.
  LlmModelInfo? get loadedModel;

  /// Загружает модель в память. Повторный вызов с другой моделью заменяет
  /// прежнюю. Ошибки — [LocalLlmException].
  Future<void> load(LlmModelFile model);

  /// Генерирует ответ потоком фрагментов текста. Поток закрывается по
  /// окончании, по [cancel] или с ошибкой [LocalLlmException].
  Stream<String> generate(List<LlmTurn> turns, LlmGenerationParams params);

  /// Останавливает идущую генерацию (поток токенов закроется).
  Future<void> cancel();

  /// Метрики последней завершённой генерации, если рантайм их отдаёт.
  LlmRuntimeStats? get lastStats;

  /// Освобождает память модели.
  Future<void> unload();
}
