import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/model_downloader.dart';

/// Настоящий HTTP-сервер на loopback с поддержкой `Range`.
class _Server {
  _Server(this.content);

  final List<int> content;
  late HttpServer _server;
  bool supportsRange = true;
  int status = 200;

  /// Оборвать соединение после стольких байт ответа (один раз).
  int? cutAfter;
  final List<String?> rangeHeaders = [];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/model.bin');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final range = request.headers.value('range');
      rangeHeaders.add(range);
      final response = request.response;
      if (status != 200) {
        response.statusCode = status;
        await response.close();
        return;
      }
      var from = 0;
      if (supportsRange && range != null) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        if (from >= content.length) {
          response
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..headers.set('content-range', 'bytes */${content.length}');
          await response.close();
          return;
        }
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            'content-range',
            'bytes $from-${content.length - 1}/${content.length}',
          );
      }
      final body = content.sublist(from);
      final cut = cutAfter;
      if (cut != null) {
        cutAfter = null;
        // Обрыв: отдаём заголовки с полной длиной и часть тела, закрываем
        // сокет.
        final socket = await response.detachSocket(writeHeaders: false);
        socket
          ..write('HTTP/1.1 200 OK\r\ncontent-length: ${body.length}\r\n\r\n')
          ..add(body.sublist(0, cut));
        await socket.flush();
        await socket.close();
        return;
      }
      response
        ..contentLength = body.length
        ..add(body);
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late Directory dir;
  late _Server server;
  late DioModelDownloader downloader;
  final content = List.generate(5000, (i) => (i * 13 + 5) % 256);

  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dio_dl');
    server = _Server(content);
    await server.start();
    downloader = DioModelDownloader(idleTimeout: const Duration(seconds: 5));
  });

  tearDown(() async {
    await server.stop();
    dir.deleteSync(recursive: true);
  });

  Future<DownloadOutcome> run(File file, int from, {List<int>? progress}) =>
      downloader.download(
        url: server.url,
        file: file,
        resumeFrom: from,
        onProgress: (received, total) => progress?.add(received),
        cancel: DownloadCancelToken(),
      );

  test('полная загрузка с прогрессом', () async {
    final file = File('${dir.path}/a.part');
    final progress = <int>[];
    final outcome = await run(file, 0, progress: progress);
    expect(outcome.totalBytes, content.length);
    expect(outcome.resumed, isFalse);
    expect(file.readAsBytesSync(), content);
    expect(progress.last, content.length);
    expect(server.rangeHeaders.single, isNull);
  });

  test('докачка: заголовок Range, 206, файл склеен', () async {
    final file = File('${dir.path}/a.part')
      ..writeAsBytesSync(content.sublist(0, 1200));
    final outcome = await run(file, 1200);
    expect(outcome.resumed, isTrue);
    expect(server.rangeHeaders.single, 'bytes=1200-');
    expect(file.readAsBytesSync(), content);
  });

  test('сервер игнорирует Range (200): файл перезаписывается с нуля', () async {
    server.supportsRange = false;
    final file = File('${dir.path}/a.part')
      ..writeAsBytesSync(List.filled(700, 9));
    final outcome = await run(file, 700);
    expect(outcome.resumed, isFalse);
    expect(file.readAsBytesSync(), content);
  });

  test('416 при полном файле: ничего не качаем', () async {
    final file = File('${dir.path}/a.part')..writeAsBytesSync(content);
    final outcome = await run(file, content.length);
    expect(outcome.totalBytes, content.length);
    expect(outcome.resumed, isTrue);
    expect(file.readAsBytesSync(), content);
  });

  test('416 при чужой длине: качаем заново', () async {
    final file = File('${dir.path}/a.part')
      ..writeAsBytesSync(List.filled(content.length + 50, 1));
    final outcome = await run(file, content.length + 50);
    expect(outcome.resumed, isFalse);
    expect(file.readAsBytesSync(), content);
  });

  test(
    'обрыв соединения: ошибка сети, часть файла остаётся и докачивается',
    () async {
      server.cutAfter = 2000;
      final file = File('${dir.path}/a.part');
      await expectLater(
        run(file, 0),
        throwsA(
          isA<DownloadFailure>().having(
            (e) => e.kind,
            'kind',
            DownloadFailureKind.network,
          ),
        ),
      );
      final partial = file.lengthSync();
      expect(partial, greaterThan(0));
      expect(partial, lessThan(content.length));

      final outcome = await run(file, partial);
      expect(outcome.resumed, isTrue);
      expect(file.readAsBytesSync(), content);
    },
  );

  test('HTTP-ошибка', () async {
    server.status = 404;
    await expectLater(
      run(File('${dir.path}/a.part'), 0),
      throwsA(
        isA<DownloadFailure>()
            .having((e) => e.kind, 'kind', DownloadFailureKind.http)
            .having((e) => e.statusCode, 'status', 404),
      ),
    );
  });

  test('отмена прерывает загрузку', () async {
    final cancel = DownloadCancelToken()..cancel();
    await expectLater(
      downloader.download(
        url: server.url,
        file: File('${dir.path}/a.part'),
        resumeFrom: 0,
        onProgress: (_, _) {},
        cancel: cancel,
      ),
      throwsA(isA<DownloadFailure>()),
    );
  });

  test('разбор Content-Range', () {
    expect(parseContentRange('bytes 100-199/200')?.start, 100);
    expect(parseContentRange('bytes 100-199/200')?.total, 200);
    expect(parseContentRange('bytes 0-9/*')?.total, isNull);
    expect(parseContentRange('мусор'), isNull);
    expect(parseContentRange(null), isNull);
  });
}
