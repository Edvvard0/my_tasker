// coverage:ignore-file
// Тонкая платформенная прослойка: системный диалог выбора файла без
// устройства не проверяется. Вся логика импорта — в `statement_import_*`.

import 'package:file_picker/file_picker.dart';
import 'package:my_tasker/features/banks/platform/statement_file_source.dart';

/// Выбор файла через `file_picker` (Android — системный выбор документов,
/// Windows — диалог проводника).
class FilePickerStatementSource implements StatementFileSource {
  const FilePickerStatementSource();

  @override
  Future<PickedStatementFile?> pick() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Выписка банка',
      type: FileType.custom,
      allowedExtensions: const ['csv', 'xlsx', 'pdf'],
    );
    if (file == null) return null;
    return PickedStatementFile(
      name: file.name,
      bytes: await file.readAsBytes(),
    );
  }
}
