import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Токен отмены загрузки (не зависит от HTTP-клиента).
class DownloadCancelToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

enum DownloadFailureKind {
  /// Обрыв соединения, таймаут, ошибка чтения потока.
  network,

  /// Сервер ответил кодом ошибки.
  http,

  /// Не удалось записать файл (диск).
  disk,
}

class DownloadFailure implements Exception {
  const DownloadFailure(this.kind, this.message, {this.statusCode});

  final DownloadFailureKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'DownloadFailure(${kind.name}): $message';
}

/// Итог успешной загрузки.
class DownloadOutcome {
  const DownloadOutcome({required this.totalBytes, required this.resumed});

  /// Итоговый размер файла.
  final int totalBytes;

  /// Загрузка продолжила существующий файл (сервер принял `Range`).
  final bool resumed;
}

/// Скачивает файл в `file` с продолжением. Поток записи — только дозапись:
/// если `resumeFrom` > 0, а сервер не поддерживает `Range`, файл
/// перезаписывается с нуля (`DownloadOutcome.resumed` = false).
abstract interface class ModelDownloader {
  Future<DownloadOutcome> download({
    required Uri url,
    required File file,
    required int resumeFrom,
    required void Function(int received, int? total) onProgress,
    required DownloadCancelToken cancel,
  });
}

/// Разбор `Content-Range: bytes 100-199/200` -> (начало, всего).
({int start, int? total})? parseContentRange(String? header) {
  if (header == null) return null;
  final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$')
      .firstMatch(header.trim());
  if (match == null) return null;
  return (
    start: int.parse(match[1]!),
    total: match[3] == '*' ? null : int.parse(match[3]!),
  );
}

/// Реализация на Dio: потоковое чтение, заголовок `Range`, повтор с нуля,
/// если сервер его проигнорировал.
class DioModelDownloader implements ModelDownloader {
  DioModelDownloader({Dio? dio, this.idleTimeout = const Duration(seconds: 45)})
    : _dio = dio ?? Dio();

  final Dio _dio;

  /// Максимальная пауза между порциями данных.
  final Duration idleTimeout;

  @override
  Future<DownloadOutcome> download({
    required Uri url,
    required File file,
    required int resumeFrom,
    required void Function(int received, int? total) onProgress,
    required DownloadCancelToken cancel,
  }) async {
    final dioCancel = CancelToken();
    unawaited(cancel.whenCancelled.then((_) => dioCancel.cancel()));
    final Response<ResponseBody> response;
    try {
      response = await _dio.getUri<ResponseBody>(
        url,
        cancelToken: dioCancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          receiveTimeout: idleTimeout,
          headers: {if (resumeFrom > 0) 'Range': 'bytes=$resumeFrom-'},
          // 416 разбираем сами: возможно, файл уже целиком на диске.
          validateStatus: (s) =>
              s != null && (s == 200 || s == 206 || s == 416),
        ),
      );
    } on DioException catch (e) {
      throw _failure(e);
    }

    final status = response.statusCode ?? 0;
    final body = response.data!;
    if (status == 416) {
      await body.stream.drain<void>();
      final range = response.headers.value('content-range');
      final total = RegExp(r'\*/(\d+)$').firstMatch(range ?? '')?[1];
      if (total != null && int.parse(total) == resumeFrom) {
        onProgress(resumeFrom, resumeFrom);
        return DownloadOutcome(totalBytes: resumeFrom, resumed: true);
      }
      // Отрезок недостижим: частичный файл не подходит, качаем заново.
      return await download(
        url: url,
        file: file,
        resumeFrom: 0,
        onProgress: onProgress,
        cancel: cancel,
      );
    }

    var offset = 0;
    var resumed = false;
    int? total;
    if (status == 206) {
      final range = parseContentRange(response.headers.value('content-range'));
      if (range == null || range.start != resumeFrom) {
        await body.stream.drain<void>();
        throw const DownloadFailure(
          DownloadFailureKind.http,
          'Сервер вернул неожиданный диапазон',
          statusCode: 206,
        );
      }
      offset = resumeFrom;
      resumed = resumeFrom > 0;
      total = range.total;
    } else {
      // 200: сервер отдаёт файл целиком, `Range` не поддержан.
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      total = length;
    }

    RandomAccessFile? raf;
    try {
      await file.parent.create(recursive: true);
      raf = await file.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var received = offset;
      onProgress(received, total);
      await for (final chunk in body.stream.timeout(idleTimeout)) {
        if (cancel.isCancelled) {
          throw const DownloadFailure(
            DownloadFailureKind.network,
            'Загрузка остановлена',
          );
        }
        await raf.writeFrom(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await raf.flush();
      if (total != null && received != total) {
        throw const DownloadFailure(
          DownloadFailureKind.network,
          'Соединение оборвалось до конца файла',
        );
      }
      return DownloadOutcome(totalBytes: received, resumed: resumed);
    } on DownloadFailure {
      rethrow;
    } on DioException catch (e) {
      throw _failure(e);
    } on TimeoutException {
      throw const DownloadFailure(
        DownloadFailureKind.network,
        'Сервер перестал отвечать',
      );
    } on FileSystemException catch (e) {
      throw DownloadFailure(DownloadFailureKind.disk, e.message);
    } on Object catch (e) {
      throw DownloadFailure(DownloadFailureKind.network, '$e');
    } finally {
      await raf?.close();
    }
  }

  DownloadFailure _failure(DioException e) {
    final status = e.response?.statusCode;
    if (status != null && status >= 400) {
      return DownloadFailure(
        DownloadFailureKind.http,
        'Сервер ответил кодом $status',
        statusCode: status,
      );
    }
    if (e.type == DioExceptionType.cancel) {
      return const DownloadFailure(
        DownloadFailureKind.network,
        'Загрузка остановлена',
      );
    }
    return DownloadFailure(
      DownloadFailureKind.network,
      e.message ?? 'Ошибка сети',
    );
  }
}
