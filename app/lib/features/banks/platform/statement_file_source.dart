import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/banks/platform/file_picker_statement_source.dart';

/// Выбранный файл выписки.
@immutable
class PickedStatementFile {
  const PickedStatementFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Выбор файла выписки (CSV, XLSX, PDF) системным диалогом. Реализация —
/// `file_picker`; тесты подставляют поддельный источник.
abstract interface class StatementFileSource {
  /// `null`, если человек закрыл диалог.
  Future<PickedStatementFile?> pick();
}

final Provider<StatementFileSource> statementFileSourceProvider =
    Provider<StatementFileSource>((ref) => const FilePickerStatementSource());
