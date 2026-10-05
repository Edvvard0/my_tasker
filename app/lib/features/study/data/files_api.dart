import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/api_providers.dart';

/// Итог загрузки файла на сервер.
enum UploadOutcome {
  /// `201 stored`: файл сохранён.
  stored,

  /// `200 exists`: файл уже был на сервере (повтор после обрыва).
  exists,
}

/// Эндпоинты файлов глазами клиента (spec `stage7_study.md`, раздел 7):
/// `PUT /files/{attachment_id}` и `GET /files/{attachment_id}`.
/// Размер и SHA-256 сервер берёт из метаданных вложения, поэтому строка
/// `attachments` должна быть синхронизирована до загрузки.
abstract interface class FilesApi {
  /// Загружает [bytes] файла вложения [attachmentId]. Идемпотентно.
  Future<UploadOutcome> upload(String attachmentId, Uint8List bytes);

  /// Скачивает содержимое вложения [attachmentId].
  Future<Uint8List> download(String attachmentId);
}

/// [FilesApi] поверх [ApiClient]: закреплённый сертификат, токен доступа и
/// его обновление — как у остальных запросов.
class HttpFilesApi implements FilesApi {
  HttpFilesApi(this._client);

  final Future<ApiClient?> Function() _client;

  @override
  Future<UploadOutcome> upload(String attachmentId, Uint8List bytes) async {
    final client = await _client();
    if (client == null) throw const ApiException.notConfigured();
    final json = await client.putBytes('/files/$attachmentId', bytes);
    return json['status'] == 'exists'
        ? UploadOutcome.exists
        : UploadOutcome.stored;
  }

  @override
  Future<Uint8List> download(String attachmentId) async {
    final client = await _client();
    if (client == null) throw const ApiException.notConfigured();
    return await client.getBytes('/files/$attachmentId');
  }
}

final Provider<FilesApi> filesApiProvider = Provider<FilesApi>(
  (ref) => HttpFilesApi(ref.read(apiClientResolverProvider)),
);

/// Понятное сообщение об ошибке передачи файла (коды раздела 7).
String fileErrorText(Object error) {
  if (error is ApiException) {
    if (error.isNetwork) {
      return 'Нет соединения с сервером. Файл останется на устройстве и '
          'загрузится позже.';
    }
    return switch (error.code) {
      'file_not_uploaded' =>
        'Файл ещё не загружен на сервер с устройства, где его добавили. '
            'Откройте приложение там и дождитесь загрузки.',
      'attachment_not_found' =>
        'Вложение не найдено на сервере: дождитесь синхронизации.',
      'payload_too_large' => 'Файл больше 25 МБ.',
      'size_mismatch' || 'hash_mismatch' =>
        'Содержимое файла не совпало с описанием. Добавьте файл заново.',
      'content_type_mismatch' =>
        'Содержимое файла не подходит к его типу. Проверьте расширение.',
      'files_not_configured' => 'На сервере не настроено хранилище файлов.',
      'not_configured' => 'Сервер не настроен: укажите адрес в настройках.',
      _ => 'Не удалось передать файл. Повторите позже.',
    };
  }
  if (error is FileIntegrityError) return error.message;
  return 'Не удалось передать файл. Повторите позже.';
}

/// Скачанное содержимое не совпало с метаданными (размер или SHA-256).
class FileIntegrityError implements Exception {
  const FileIntegrityError(this.message);

  final String message;

  @override
  String toString() => message;
}
