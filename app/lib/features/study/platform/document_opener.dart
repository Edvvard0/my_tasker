import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/study/platform/open_file_document_opener.dart';

/// Результат открытия документа системным просмотрщиком.
enum DocumentOpenResult {
  /// Просмотрщик запущен.
  opened,

  /// На устройстве нет программы для этого типа файла.
  noApp,

  /// Не получилось открыть (нет доступа, файл не найден, сбой).
  failed,
}

/// Открывает документ программой по умолчанию (PDF, Office…). Реализация —
/// `open_filex`; тесты подставляют поддельный просмотрщик.
abstract interface class DocumentOpener {
  Future<DocumentOpenResult> open(String path, String mimeType);
}

final Provider<DocumentOpener> documentOpenerProvider =
    Provider<DocumentOpener>((ref) => const OpenFileDocumentOpener());
