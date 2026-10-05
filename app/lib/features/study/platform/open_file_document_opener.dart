// coverage:ignore-file
// Тонкая платформенная прослойка: системный просмотрщик без устройства не
// проверяется.

import 'package:my_tasker/features/study/platform/document_opener.dart';
import 'package:open_filex/open_filex.dart';

/// Открытие файла через `open_filex` (Android — намерение `VIEW`, Windows —
/// программа по умолчанию).
class OpenFileDocumentOpener implements DocumentOpener {
  const OpenFileDocumentOpener();

  @override
  Future<DocumentOpenResult> open(String path, String mimeType) async {
    try {
      final result = await OpenFilex.open(path, type: mimeType);
      return switch (result.type) {
        ResultType.done => DocumentOpenResult.opened,
        ResultType.noAppToOpen => DocumentOpenResult.noApp,
        _ => DocumentOpenResult.failed,
      };
    } on Object {
      return DocumentOpenResult.failed;
    }
  }
}
