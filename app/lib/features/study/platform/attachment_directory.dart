// coverage:ignore-file
// Тонкая платформенная прослойка: каталог приложения без устройства не
// проверяется.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Каталог приложения для файлов вложений (вне синхронизации и вне
/// резервной копии БД): `<support>/attachments`.
Future<Directory> attachmentRoot() async {
  final support = await getApplicationSupportDirectory();
  return Directory(p.join(support.path, 'attachments'));
}
