import 'dart:async';
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

  Future<void> delete(String id);

  /// Путь к копии файла с настоящим именем [fileName] для системного
  /// просмотрщика (по расширению он выбирает программу).
  Future<String> exportForViewing(String id, String fileName);
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
  }

  @override
  Future<String> exportForViewing(String id, String fileName) async {
    final bytes = await read(id);
    if (bytes == null) throw StateError('Файла $id нет на устройстве');
    final safe = fileName.replaceAll(RegExp(r'[/\\]'), '_');
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
  Future<String> exportForViewing(String id, String fileName) async =>
      '/memory/$id/$fileName';
}
