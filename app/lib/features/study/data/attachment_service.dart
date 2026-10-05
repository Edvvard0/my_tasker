import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/data/attachment_store.dart';
import 'package:my_tasker/features/study/data/files_api.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_validation.dart';

/// Итог фоновой загрузки вложений.
class UploadReport {
  const UploadReport({
    this.uploaded = const [],
    this.retryLater = const [],
    this.failed = const {},
  });

  /// Загружены (или уже были на сервере): `upload_status = uploaded`.
  final List<String> uploaded;

  /// Не получилось сейчас (нет сети, сервер недоступен, строка ещё не
  /// синхронизирована): повтор позже.
  final List<String> retryLater;

  /// Сервер отказал окончательно: `id -> код ошибки` (повтор не поможет).
  final Map<String, String> failed;
}

/// Вложения: сохранение файла на устройстве, фоновая загрузка на сервер и
/// скачивание по требованию (spec `stage7_study.md`, раздел 7).
///
/// 1. [add] кладёт файл в локальное хранилище и создаёт метаданные
///    (`upload_status = pending`) — работает без сети.
/// 2. [uploadPending] отправляет `PUT /files/{id}`; после успеха ставит
///    `upload_status = uploaded` обычной правкой. Повтор безопасен
///    (сервер отвечает `exists`).
/// 3. [bytesOf] отдаёт локальный файл или скачивает его `GET /files/{id}`,
///    проверяет размер и SHA-256 и кэширует.
class AttachmentService {
  AttachmentService({
    required this.repository,
    required this.files,
    required this.api,
    this.syncNow,
    this.syncTimeout = const Duration(seconds: 30),
    String Function()? newId,
  }) : _newId = newId ?? uuid7;

  final StudyRepository repository;
  final AttachmentFileStore files;
  final FilesApi api;

  /// Синхронизация перед загрузкой: строка `attachments` должна дойти до
  /// сервера, иначе `PUT` ответит `404 attachment_not_found`.
  final Future<void> Function()? syncNow;

  /// Сколько ждать синхронизацию перед загрузкой: дальше — загружаем как
  /// есть (сервер ответит `attachment_not_found`, повтор позже).
  final Duration syncTimeout;
  final String Function() _newId;

  Future<UploadReport>? _uploading;
  final Map<String, Future<Uint8List>> _downloads = {};

  /// Добавляет файл владельцу (предмету или долгу): проверяет имя, тип и
  /// размер, считает SHA-256, сохраняет файл на устройстве и создаёт
  /// метаданные. Бросает [ValidationError].
  Future<Attachment> add({
    required String fileName,
    required Uint8List bytes,
    String? subjectId,
    String? debtId,
  }) async {
    final name = fileName.trim();
    final mime = mimeTypeOf(name);
    if (mime == null) {
      throw const ValidationError(
        'Такой тип файла не поддерживается: допустимы фото (JPG, PNG, HEIC, '
        'WebP), PDF, документы Office, TXT и ZIP.',
      );
    }
    final attachment = Attachment(
      id: _newId(),
      subjectId: subjectId,
      debtId: debtId,
      fileName: name,
      mimeType: mime,
      sizeBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    ensureValid(attachmentProblem(attachment));
    await files.write(attachment.id, bytes);
    try {
      await repository.createAttachment(attachment);
    } on Object {
      await files.delete(attachment.id);
      rethrow;
    }
    return attachment;
  }

  /// Загружает на сервер все вложения со статусом `pending`, файлы которых
  /// есть на этом устройстве. Параллельные вызовы объединяются.
  Future<UploadReport> uploadPending() =>
      _uploading ??= _uploadAll().whenComplete(() => _uploading = null);

  Future<UploadReport> _uploadAll() async {
    final pending = <Attachment>[];
    for (final a in await repository.pendingUploads()) {
      if (await files.exists(a.id)) pending.add(a);
    }
    if (pending.isEmpty) return const UploadReport();
    // Сначала метаданные должны дойти до сервера.
    var unsynced = false;
    for (final a in pending) {
      if (!await repository.isSynced(a.id)) unsynced = true;
    }
    if (unsynced) {
      try {
        await syncNow?.call().timeout(syncTimeout);
      } on Object {
        // Синхронизация — удобство: ниже каждое вложение решит само.
      }
    }
    final uploaded = <String>[];
    final later = <String>[];
    final failed = <String, String>{};
    for (final a in pending) {
      final bytes = await files.read(a.id);
      if (bytes == null) continue;
      try {
        await api.upload(a.id, bytes);
        await repository.markUploaded(a.id);
        uploaded.add(a.id);
      } on ApiException catch (e) {
        if (_isTemporary(e)) {
          later.add(a.id);
        } else {
          failed[a.id] = e.code ?? 'http_${e.status}';
        }
      }
    }
    return UploadReport(uploaded: uploaded, retryLater: later, failed: failed);
  }

  /// Временная причина: повтор позже имеет смысл.
  static bool _isTemporary(ApiException e) =>
      e.isNetwork ||
      e.isServerError ||
      e.kind == ApiErrorKind.notConfigured ||
      e.code == 'attachment_not_found' ||
      e.code == 'files_not_configured' ||
      e.status == 401 ||
      e.status == 429;

  /// Файл есть на устройстве.
  Future<bool> isLocal(String id) => files.exists(id);

  /// Содержимое файла: локальное или скачанное с сервера (с проверкой
  /// размера и SHA-256 и кэшированием). Бросает [ApiException] и
  /// [FileIntegrityError].
  Future<Uint8List> bytesOf(Attachment attachment) async {
    final local = await files.read(attachment.id);
    if (local != null) return local;
    // `whenComplete` не должен возвращать само скачивание (`remove` отдаёт
    // его же): оно бы ждало себя вечно.
    return await (_downloads[attachment.id] ??= _download(attachment)
        .whenComplete(() {
          unawaited(_downloads.remove(attachment.id));
        }));
  }

  Future<Uint8List> _download(Attachment a) async {
    final data = await api.download(a.id);
    if (data.length != a.sizeBytes) {
      throw const FileIntegrityError(
        'Размер скачанного файла не совпал с описанием. Повторите позже.',
      );
    }
    if (sha256.convert(data).toString() != a.sha256) {
      throw const FileIntegrityError(
        'Скачанный файл повреждён (не совпала контрольная сумма). '
        'Повторите позже.',
      );
    }
    await files.write(a.id, data);
    return data;
  }

  /// Путь к копии файла для системного просмотрщика (файл при
  /// необходимости скачивается).
  Future<String> pathForViewing(Attachment attachment) async {
    await bytesOf(attachment);
    return await files.exportForViewing(attachment.id, attachment.fileName);
  }

  /// Убирает вложение в корзину (локальный файл остаётся до очистки
  /// корзины: «Восстановить» вернёт вложение целиком).
  Future<void> remove(String id) => repository.deleteAttachment(id);
}
