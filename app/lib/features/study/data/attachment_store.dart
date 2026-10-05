import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Локальное хранилище содержимого вложений на устройстве: файл
/// сохраняется сразу (офлайн работает), загружается на сервер в фоне, а на
/// других устройствах скачивается по требованию и кэшируется здесь же.
/// Платформенная часть (каталог приложения) за интерфейсом; тесты
/// подставляют каталог во временной папке или память.
abstract interface class AttachmentFileStore {
  /// Файл вложения [id] есть на устройстве.
  Future<bool> exists(String id);

  /// Содержимое или `null`, если файла нет.
  Future<Uint8List?> read(String id);

  /// Сохраняет содержимое (атомарно: запись во временный файл и
  /// переименование — недописанный файл никто не увидит).
  Future<void> write(String id, Uint8List bytes);

  /// Удаляет файл и копию для просмотра (если их нет — ничего не делает).
  Future<void> delete(String id);

  /// Идентификаторы всех файлов в хранилище (для сверки «файл без строки»).
  Future<List<String>> ids();

  /// Путь к копии файла с настоящим именем [fileName] для системного
  /// просмотрщика (по расширению он выбирает программу).
  Future<String> exportForViewing(String id, String fileName);
}

final RegExp _unsafeNameChars = RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]');
final RegExp _reservedNames = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$',
  caseSensitive: false,
);

/// Лимит имени файла в файловых системах (байт в UTF-8).
const int maxFileNameBytes = 255;

/// Имя для копии файла на диске: годится и для Windows (нет `: * ? " < > |`
/// и управляющих символов, зарезервированных имён `CON`, `NUL`, `COM1`…,
/// точки или пробела в конце) и для Android; длиннее 255 байт — режется с
/// сохранением расширения.
String safeFileName(String name) {
  var safe = name.replaceAll(_unsafeNameChars, '_');
  safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
  if (safe.isEmpty) return 'file';
  final dot = safe.indexOf('.');
  final stem = dot < 0 ? safe : safe.substring(0, dot);
  if (_reservedNames.hasMatch(stem.trimRight())) safe = '_$safe';
  if (utf8.encode(safe).length > maxFileNameBytes) {
    final lastDot = safe.lastIndexOf('.');
    // Расширение — только если оно короткое и не всё имя.
    final ext = lastDot > 0 && safe.length - lastDot <= 16
        ? safe.substring(lastDot)
        : '';
    final budget = maxFileNameBytes - utf8.encode(ext).length;
    final buffer = StringBuffer();
    var used = 0;
    for (final rune
        in safe.substring(0, ext.isEmpty ? safe.length : lastDot).runes) {
      final piece = String.fromCharCode(rune);
      final size = utf8.encode(piece).length;
      if (used + size > budget) break;
      buffer.write(piece);
      used += size;
    }
    safe = '$buffer$ext';
    if (ext.isEmpty) safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
  }
  return safe;
}

/// Хранилище в каталоге приложения: `<root>/files/<id>`; копии для просмотра —
/// `<root>/view/<id>/<имя>`.
class DirectoryAttachmentStore implements AttachmentFileStore {
  DirectoryAttachmentStore(this._root);

  /// Каталог можно получить позже (путь платформы известен асинхронно).
  final Future<Directory> Function() _root;

  Future<File> _file(String id) async {
    _checkId(id);
    final dir = Directory('${(await _root()).path}/files');
    await dir.create(recursive: true);
    return File('${dir.path}/$id');
  }

  static void _checkId(String id) {
    if (id.isEmpty || id.contains('/') || id.contains(r'\') || id == '..') {
      throw ArgumentError.value(id, 'id', 'неверный идентификатор файла');
    }
  }

  @override
  Future<bool> exists(String id) async => (await _file(id)).existsSync();

  @override
  Future<Uint8List?> read(String id) async {
    final file = await _file(id);
    return file.existsSync() ? await file.readAsBytes() : null;
  }

  @override
  Future<void> write(String id, Uint8List bytes) async {
    final file = await _file(id);
    final temp = File('${file.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> delete(String id) async {
    final file = await _file(id);
    if (file.existsSync()) await file.delete();
    final view = Directory('${(await _root()).path}/view/$id');
    if (view.existsSync()) await view.delete(recursive: true);
  }

  @override
  Future<List<String>> ids() async {
    final root = (await _root()).path;
    final ids = <String>{};
    final files = Directory('$root/files');
    if (files.existsSync()) {
      for (final e in files.listSync()) {
        if (e is File) ids.add(e.uri.pathSegments.last);
      }
    }
    // Копии для просмотра без самого файла тоже подлежат сверке.
    final views = Directory('$root/view');
    if (views.existsSync()) {
      for (final e in views.listSync()) {
        if (e is Directory) {
          ids.add(e.uri.pathSegments.where((p) => p.isNotEmpty).last);
        }
      }
    }
    return ids.toList();
  }

  @override
  Future<String> exportForViewing(String id, String fileName) async {
    final bytes = await read(id);
    if (bytes == null) throw StateError('Файла $id нет на устройстве');
    final safe = safeFileName(fileName);
    final dir = Directory('${(await _root()).path}/view/$id');
    await dir.create(recursive: true);
    final copy = File('${dir.path}/$safe');
    await copy.writeAsBytes(bytes, flush: true);
    return copy.path;
  }
}

/// Хранилище в памяти (тесты и виджет-тесты без файловой системы).
class MemoryAttachmentStore implements AttachmentFileStore {
  final Map<String, Uint8List> files = {};

  @override
  Future<bool> exists(String id) async => files.containsKey(id);

  @override
  Future<Uint8List?> read(String id) async => files[id];

  @override
  Future<void> write(String id, Uint8List bytes) async => files[id] = bytes;

  @override
  Future<void> delete(String id) async => files.remove(id);

  @override
  Future<List<String>> ids() async => files.keys.toList();

  @override
  Future<String> exportForViewing(String id, String fileName) async =>
      '/memory/$id/$fileName';
}
