import 'package:flutter/foundation.dart';

/// Модель из каталога разрешённых (решение этапа 10, п. 3: каталог в коде,
/// произвольные URL приложение не качает).
@immutable
class LocalModelSpec {
  const LocalModelSpec({
    required this.id,
    required this.name,
    required this.engineId,
    required this.fileName,
    required this.url,
    required this.sizeBytes,
    required this.licenseName,
    required this.licenseUrl,
    required this.minTotalRamBytes,
    required this.minAvailableRamBytes,
    required this.contextTokens,
    this.sha256,
    this.sizeIsExact = false,
    this.description = '',
  });

  /// Устойчивый идентификатор (идёт в `ai_messages.model` с префиксом
  /// `local/`, см. [wireModelId]).
  final String id;
  final String name;

  /// Рантайм, которым модель запускается (`LocalLlmEngine.id`).
  final String engineId;

  /// Имя файла в каталоге моделей приложения.
  final String fileName;
  final String url;

  /// Размер файла: точный ([sizeIsExact]) либо оценка для проверки места.
  final int sizeBytes;
  final bool sizeIsExact;

  /// SHA-256 файла (hex, нижний регистр). `null` — контрольная сумма ещё не
  /// закреплена: менеджер сверяет размер с ответом сервера, а экран моделей
  /// показывает вычисленную сумму, чтобы её можно было закрепить в каталоге.
  final String? sha256;

  final String licenseName;
  final String licenseUrl;

  /// Нижняя граница всей ОЗУ устройства и свободной ОЗУ перед запуском.
  final int minTotalRamBytes;
  final int minAvailableRamBytes;

  /// Окно контекста (вход + выход) при загрузке модели.
  final int contextTokens;
  final String description;

  bool get isPinned => sha256 != null;

  /// Идентификатор модели в `ai_messages.model` локальных ответов.
  String get wireModelId => 'local/$id';

  /// Размер в «ГБ» для показа.
  String get sizeLabel => formatBytes(sizeBytes);
}

const int _mib = 1024 * 1024;
const int _gib = 1024 * _mib;

/// Основная модель: Gemma 4 E2B-it, формат LiteRT-LM, только CPU (на
/// Galaxy A55 GPU Xclipse в LiteRT-LM даёт мусор — решение этапа 10, п. 1).
///
/// ВАЖНО (открытый вопрос): SHA-256 и точный размер закрепляются при первой
/// загрузке на устройстве/сети с доступом к Hugging Face (из среды разработки
/// он недоступен): экран моделей показывает вычисленную сумму.
const LocalModelSpec gemma4E2b = LocalModelSpec(
  id: 'gemma-4-e2b-it',
  name: 'Gemma 4 E2B (русский, офлайн)',
  engineId: 'flutter_gemma',
  fileName: 'gemma-4-E2B-it.litertlm',
  url:
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
      'resolve/main/gemma-4-E2B-it.litertlm',
  sizeBytes: 2600 * _mib,
  licenseName: 'Gemma (условия использования Google)',
  licenseUrl:
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm',
  minTotalRamBytes: 6 * _gib,
  minAvailableRamBytes: 3 * _gib,
  contextTokens: 4096,
  description: 'Основная офлайн-модель. Только процессор, без видеоускорителя.',
);

/// Каталог разрешённых моделей.
const List<LocalModelSpec> localModelCatalog = [gemma4E2b];

LocalModelSpec? localModelById(String id) {
  for (final spec in localModelCatalog) {
    if (spec.id == id) return spec;
  }
  return null;
}

/// Модель по значению `ai_messages.model` / `ai_conversations.model`
/// (`local/<id>`); `null` для облачных моделей и неизвестных id.
LocalModelSpec? localModelByWireId(String? wire) {
  if (wire == null || !wire.startsWith('local/')) return null;
  return localModelById(wire.substring('local/'.length));
}

/// Размер для людей: «2,5 ГБ», «340 МБ».
String formatBytes(int bytes) {
  if (bytes >= _gib) {
    return '${(bytes / _gib).toStringAsFixed(1).replaceAll('.', ',')} ГБ';
  }
  if (bytes >= _mib) return '${(bytes / _mib).round()} МБ';
  if (bytes >= 1024) return '${(bytes / 1024).round()} КБ';
  return '$bytes Б';
}
