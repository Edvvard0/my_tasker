import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/data/attachment_store.dart';
import 'package:my_tasker/features/study/data/files_api.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/file_magic.dart';
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

  /// Во время загрузки попросили ещё одну: после неё — следующий проход
  /// (новое вложение не должно ждать следующей синхронизации).
  bool _again = false;

  /// Файлы, которые [add] сейчас записывает: сверка «файл без строки» их
  /// не трогает.
  final Set<String> _adding = {};
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
    // Сервер отвергает файл по первым байтам (`415`): отказываем сразу, а не
    // оставляем вложение «ждёт загрузки» навсегда.
    if (!looksLikeMime(mime, bytes)) {
      throw const ValidationError(
        'Содержимое файла не подходит к его типу: проверьте, что файл не '
        'повреждён и расширение указано верно.',
      );
    }
    _adding.add(attachment.id);
    try {
      await files.write(attachment.id, bytes);
      try {
        await repository.createAttachment(attachment);
      } on Object {
        await files.delete(attachment.id);
        rethrow;
      }
    } finally {
      _adding.remove(attachment.id);
    }
    return attachment;
  }

  /// Загружает на сервер все вложения со статусом `pending`, файлы которых
  /// есть на этом устройстве. Параллельные вызовы объединяются.
  /// Если вызов пришёл во время идущей загрузки, после неё делается ещё один
  /// проход: вложение, добавленное в это время, не ждёт следующей
  /// синхронизации. Файлы с окончательным отказом сервера (`413/415/422`…)
  /// сами не загружаются — только после [retryUpload].
  Future<UploadReport> uploadPending() {
    final running = _uploading;
    if (running != null) {
      _again = true;
      return running;
    }
    return _uploading = _uploadLoop();
  }

  Future<UploadReport> _uploadLoop() async {
    var report = const UploadReport();
    try {
      while (true) {
        report = _merge(report, await _uploadAll());
        if (!_again) return report;
        _again = false;
      }
    } finally {
      _again = false;
      _uploading = null;
    }
  }

  static UploadReport _merge(UploadReport a, UploadReport b) {
    final uploaded = [...a.uploaded, ...b.uploaded];
    return UploadReport(
      uploaded: uploaded,
      retryLater: [
        for (final id in {...a.retryLater, ...b.retryLater})
          if (!uploaded.contains(id)) id,
      ],
      failed: {
        for (final e in {...a.failed, ...b.failed}.entries)
          if (!uploaded.contains(e.key)) e.key: e.value,
      },
    );
  }

  /// Пользователь просит повторить загрузку файла с окончательным отказом.
  Future<void> retryUpload(String id) => repository.clearUploadFailures([id]);

  Future<UploadReport> _uploadAll() async {
    final blocked = await repository.uploadFailures();
    final pending = <Attachment>[];
    final known = <String, String>{};
    for (final a in await repository.pendingUploads()) {
      final code = blocked[a.id];
      if (code != null) {
        known[a.id] = code;
        continue;
      }
      if (await files.exists(a.id)) pending.add(a);
    }
    if (pending.isEmpty) return UploadReport(failed: known);
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
    final failed = <String, String>{...known};
    for (final a in pending) {
      final bytes = await files.read(a.id);
      if (bytes == null) continue;
      try {
        await api.upload(a.id, bytes);
        await repository.markUploaded(a.id);
        uploaded.add(a.id);
        await repository.clearUploadFailures([a.id]);
      } on ApiException catch (e) {
        if (_isTemporary(e)) {
          later.add(a.id);
        } else {
          final code = e.code ?? 'http_${e.status}';
          failed[a.id] = code;
          await repository.markUploadFailed(a.id, code);
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

  /// Корзина физически очищена ([ids] — строки, удалённые навсегда): убирает
  /// локальные файлы (`files/<id>`, `view/<id>`) и запомненные отказы. Файл
  /// вложения, строка которого ещё есть, не трогается.
  Future<void> purgeFiles(Iterable<String> ids) async {
    final gone = <String>[];
    for (final id in ids) {
      if (_adding.contains(id)) continue;
      if (await repository.getAttachment(id) != null) continue;
      await files.delete(id);
      gone.add(id);
    }
    await repository.clearUploadFailures(gone);
  }

  /// Стартовая сверка: локальные файлы без строки `attachments` (очистка
  /// корзины, прерванное добавление, остатки записи) удаляются. Возвращает
  /// число удалённых.
  Future<int> sweepOrphans() async {
    final orphans = [
      for (final id in await files.ids())
        if (!_adding.contains(id)) id,
    ];
    var removed = 0;
    for (final id in orphans) {
      if (_adding.contains(id)) continue;
      if (await repository.getAttachment(id) != null) continue;
      await files.delete(id);
      removed++;
    }
    await repository.clearUploadFailures([
      for (final id in (await repository.uploadFailures()).keys)
        if (await repository.getAttachment(id) == null) id,
    ]);
    return removed;
  }
}
