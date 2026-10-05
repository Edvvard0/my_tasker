import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/data/attachment_service.dart';
import 'package:my_tasker/features/study/data/attachment_store.dart';
import 'package:my_tasker/features/study/data/files_api.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_validation.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/study_env.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Вложения «Учёбы» (spec `stage7_study.md`, раздел 7): файл сначала
/// сохраняется на устройстве, в фоне загружается `PUT /files/{id}`,
/// на другом устройстве скачивается по требованию. Проверки сервера
/// воспроизводит `FakeFilesApi` (размер, SHA-256, лимит, тип, повтор,
/// чужой файл); сбои — обрыв, неверный хеш, лимит.
void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late StudyDevice phone;
  late StudyDevice pc;
  late String subj;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => _uuid(8000 + ++counter);
    final api = FakeFilesApi(metaOf: (id) => server.row('attachments', id));
    phone = await StudyDevice.create(
      server,
      clock: clock,
      newId: next,
      api: api,
    );
    pc = await StudyDevice.create(server, clock: clock, newId: next, api: api);
    final sem = phone.study.newId();
    await phone.study.createSemester(
      Semester(
        id: sem,
        name: 'Осень',
        startDate: '2026-09-01',
        endDate: '2026-12-31',
        week1Start: '2026-08-31',
      ),
    );
    subj = phone.study.newId();
    await phone.study.createSubject(
      Subject(id: subj, semesterId: sem, name: 'Физика'),
    );
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
  }

  Future<Attachment> add([String name = 'Методичка.pdf', Uint8List? bytes]) =>
      phone.attachments.add(
        fileName: name,
        bytes: bytes ?? fakePdf(),
        subjectId: subj,
      );

  AttachmentService serviceWith({
    Future<void> Function()? syncNow,
    FakeFilesApi? api,
  }) => AttachmentService(
    repository: phone.study,
    files: phone.files,
    api: api ?? phone.api,
    syncNow: syncNow,
  );

  group('добавление: файл на устройстве сразу, офлайн', () {
    test(
      'сохраняется локально, метаданные — по файлу, статус pending',
      () async {
        final bytes = fakePdf('текст');
        final a = await add('Методичка.pdf', bytes);
        expect(await phone.files.exists(a.id), isTrue);
        expect(await phone.files.read(a.id), bytes);
        expect(a.sizeBytes, bytes.length);
        expect(a.sha256, sha256Of(bytes));
        expect(a.mimeType, 'application/pdf');
        expect(a.uploadStatus, UploadStatus.pending);
        expect(phone.api.uploadCalls, isEmpty);
        expect(await phone.attachments.isLocal(a.id), isTrue);
      },
    );

    test(
      'тип не из списка, пустой и слишком большой файл отклоняются',
      () async {
        await expectLater(
          add('вирус.exe'),
          throwsA(
            isA<ValidationError>().having(
              (e) => e.message,
              'сообщение',
              contains('не поддерживается'),
            ),
          ),
        );
        await expectLater(
          add('пустой.pdf', Uint8List(0)),
          throwsA(isA<ValidationError>()),
        );
        await expectLater(
          add('огромный.pdf', Uint8List(maxFileBytes + 1)),
          throwsA(
            isA<ValidationError>().having(
              (e) => e.message,
              'сообщение',
              contains('25'),
            ),
          ),
        );
        expect(phone.files.files, isEmpty);
        expect(await phone.device.store.visibleRows('attachments'), isEmpty);
      },
    );

    test('ровно 25 МиБ — можно', () async {
      final big = Uint8List(maxFileBytes)
        ..setRange(0, 4, [0x25, 0x50, 0x44, 0x46]);
      final a = await add('большой.pdf', big);
      expect(a.sizeBytes, maxFileBytes);
    });

    test('сбой записи метаданных убирает файл с устройства', () async {
      final service = AttachmentService(
        repository: _FailingRepo(phone),
        files: phone.files,
        api: phone.api,
      );
      await expectLater(
        service.add(fileName: 'a.pdf', bytes: fakePdf(), subjectId: subj),
        throwsStateError,
      );
      expect(phone.files.files, isEmpty);
    });
  });

  group('загрузка PUT /files/{id}', () {
    test(
      'после синхронизации файл уходит на сервер, статус uploaded',
      () async {
        final a = await add();
        await phone.device.sync();
        final report = await phone.attachments.uploadPending();
        expect(report.uploaded, [a.id]);
        expect(phone.api.stored[a.id], isNotNull);
        expect(
          (await phone.study.getAttachment(a.id))!.uploadStatus,
          UploadStatus.uploaded,
        );
        expect(await phone.study.pendingUploads(), isEmpty);
        // Статус доезжает до второго устройства.
        await syncBoth();
        expect(
          (await pc.study.getAttachment(a.id))!.uploadStatus,
          UploadStatus.uploaded,
        );
        // Повторный запуск ничего не делает.
        expect((await phone.attachments.uploadPending()).uploaded, isEmpty);
        expect(phone.api.uploadCalls, hasLength(1));
      },
    );

    test(
      'метаданные не синхронизированы: сначала синхронизация, потом PUT',
      () async {
        final a = await add();
        var synced = 0;
        final service = serviceWith(
          syncNow: () async {
            synced++;
            await phone.device.sync();
          },
        );
        final report = await service.uploadPending();
        expect(synced, 1);
        expect(report.uploaded, [a.id]);
      },
    );

    test('сбой синхронизации не мешает: сервер ответит attachment_not_found, '
        'повтор позже', () async {
      final a = await add();
      final service = serviceWith(syncNow: () async => throw StateError('x'));
      final report = await service.uploadPending();
      expect(report.retryLater, [a.id]);
      expect(report.failed, isEmpty);
      expect(phone.api.uploadCalls, [a.id]);
      expect(await phone.study.pendingUploads(), hasLength(1));
    });

    test(
      'обрыв: ничего не сохраняется, статус pending, повтор проходит',
      () async {
        final a = await add();
        await phone.device.sync();
        phone.api.dropNextUploads = 1;
        var report = await phone.attachments.uploadPending();
        expect(report.retryLater, [a.id]);
        expect(phone.api.stored, isEmpty);
        expect(
          (await phone.study.getAttachment(a.id))!.uploadStatus,
          UploadStatus.pending,
        );
        report = await phone.attachments.uploadPending();
        expect(report.uploaded, [a.id]);
      },
    );

    test('сервер недоступен (5xx): повтор позже, не отказ', () async {
      final a = await add();
      await phone.device.sync();
      phone.api.serverDown = true;
      final report = await phone.attachments.uploadPending();
      expect(report.retryLater, [a.id]);
      expect(report.failed, isEmpty);
    });

    test('повтор идемпотентен: файл уже на сервере — exists, статус '
        'выставляется', () async {
      final a = await add();
      await phone.device.sync();
      phone.api.stored[a.id] = (await phone.files.read(a.id))!;
      final report = await phone.attachments.uploadPending();
      expect(report.uploaded, [a.id]);
      expect(
        (await phone.study.getAttachment(a.id))!.uploadStatus,
        UploadStatus.uploaded,
      );
    });

    test(
      'неверный хеш и размер: окончательный отказ, файл не сохранён',
      () async {
        final a = await add('a.pdf', fakePdf('первый'));
        final b = await add('b.pdf', fakePdf('второй'));
        await phone.device.sync();
        // Содержимое на устройстве расходится с метаданными.
        await phone.files.write(a.id, fakePdf('другой'));
        await phone.files.write(
          b.id,
          Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
        );
        final report = await phone.attachments.uploadPending();
        expect(report.failed, {a.id: 'hash_mismatch', b.id: 'size_mismatch'});
        expect(report.uploaded, isEmpty);
        expect(phone.api.stored, isEmpty);
        expect(
          (await phone.study.getAttachment(a.id))!.uploadStatus,
          UploadStatus.pending,
        );
      },
    );

    test('содержимое не подходит к типу: 415', () async {
      final a = await add('a.pdf', Uint8List.fromList(List.filled(10, 7)));
      await phone.device.sync();
      final report = await phone.attachments.uploadPending();
      expect(report.failed, {a.id: 'content_type_mismatch'});
    });

    test('лимит сервера: 413 — окончательный отказ', () async {
      final a = await add();
      await phone.device.sync();
      final api = FakeFilesApi(
        metaOf: (id) => {
          ...server.row('attachments', id)!,
          'size_bytes': maxFileBytes + 1,
        },
      );
      final report = await serviceWith(api: api).uploadPending();
      expect(report.failed, {a.id: 'payload_too_large'});
    });

    test(
      'чужой файл: сервер отвечает как на неизвестный id — повтор позже',
      () async {
        final a = await add();
        await phone.device.sync();
        phone.api.foreign.add(a.id);
        final report = await phone.attachments.uploadPending();
        expect(report.retryLater, [a.id]);
        expect(report.failed, isEmpty);
      },
    );

    test(
      'файла нет на этом устройстве (вложение с другого) — не трогаем',
      () async {
        final a = await add();
        await syncBoth();
        expect(await pc.study.pendingUploads(), hasLength(1));
        final report = await pc.attachments.uploadPending();
        expect(report.uploaded, isEmpty);
        expect(pc.api.uploadCalls, isEmpty);
        expect(await pc.attachments.isLocal(a.id), isFalse);
      },
    );

    test('параллельные запуски объединяются', () async {
      await add();
      await phone.device.sync();
      final first = phone.attachments.uploadPending();
      final second = phone.attachments.uploadPending();
      expect(identical(first, second), isTrue);
      await first;
      expect(phone.api.uploadCalls, hasLength(1));
    });
  });

  group('скачивание GET /files/{id} на другом устройстве', () {
    Future<Attachment> uploaded() async {
      final a = await add();
      await phone.device.sync();
      await phone.attachments.uploadPending();
      await syncBoth();
      return (await pc.study.getAttachment(a.id))!;
    }

    test('скачивается по требованию, проверяется и кэшируется', () async {
      final a = await uploaded();
      expect(await pc.attachments.isLocal(a.id), isFalse);
      final bytes = await pc.attachments.bytesOf(a);
      expect(sha256Of(bytes), a.sha256);
      expect(await pc.attachments.isLocal(a.id), isTrue);
      expect(pc.api.downloadCalls, [a.id]);
      await pc.attachments.bytesOf(a);
      expect(pc.api.downloadCalls, hasLength(1));
      final path = await pc.attachments.pathForViewing(a);
      expect(path, endsWith('Методичка.pdf'));
    });

    test('параллельные скачивания объединяются', () async {
      final a = await uploaded();
      await Future.wait([pc.attachments.bytesOf(a), pc.attachments.bytesOf(a)]);
      expect(pc.api.downloadCalls, hasLength(1));
    });

    test('обрыв: ничего не кэшируется, повтор проходит', () async {
      final a = await uploaded();
      pc.api.dropNextDownloads = 1;
      await expectLater(
        pc.attachments.bytesOf(a),
        throwsA(isA<ApiException>().having((e) => e.isNetwork, 'сеть', isTrue)),
      );
      expect(await pc.attachments.isLocal(a.id), isFalse);
      expect(await pc.attachments.bytesOf(a), isNotEmpty);
    });

    test(
      'неверное содержимое: испорченный хеш и размер не кэшируются',
      () async {
        final a = await uploaded();
        pc.api.corruptDownloads = true;
        await expectLater(
          pc.attachments.bytesOf(a),
          throwsA(
            isA<FileIntegrityError>().having(
              (e) => e.message,
              'сообщение',
              contains('контрольная сумма'),
            ),
          ),
        );
        pc.api
          ..corruptDownloads = false
          ..truncateDownloads = true;
        await expectLater(
          pc.attachments.bytesOf(a),
          throwsA(
            isA<FileIntegrityError>().having(
              (e) => e.message,
              'сообщение',
              contains('Размер'),
            ),
          ),
        );
        expect(await pc.attachments.isLocal(a.id), isFalse);
      },
    );

    test('ещё не загружен (file_not_uploaded) и чужой файл', () async {
      final a = await add();
      await syncBoth();
      final onPc = (await pc.study.getAttachment(a.id))!;
      await expectLater(
        pc.attachments.bytesOf(onPc),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'код', 'file_not_uploaded'),
        ),
      );
      pc.api.foreign.add(a.id);
      await expectLater(
        pc.attachments.bytesOf(onPc),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'код',
            'attachment_not_found',
          ),
        ),
      );
    });
  });

  group('тексты ошибок', () {
    test('коды раздела 7 и прочее', () {
      String text(String code, {int status = 422}) => fileErrorText(
        ApiException(kind: ApiErrorKind.http, status: status, code: code),
      );
      expect(
        fileErrorText(const ApiException.network('x')),
        contains('Нет соединения'),
      );
      expect(
        text('file_not_uploaded', status: 404),
        contains('ещё не загружен'),
      );
      expect(
        text('attachment_not_found', status: 404),
        contains('синхронизации'),
      );
      expect(text('payload_too_large', status: 413), contains('25'));
      expect(text('size_mismatch'), contains('не совпало'));
      expect(text('hash_mismatch'), contains('не совпало'));
      expect(text('content_type_mismatch', status: 415), contains('типу'));
      expect(text('files_not_configured', status: 503), contains('хранилище'));
      expect(text('not_configured'), contains('Сервер не настроен'));
      expect(text('что-то'), contains('Не удалось'));
      expect(fileErrorText(const FileIntegrityError('Битый')), 'Битый');
      expect(fileErrorText(StateError('x')), contains('Не удалось'));
      expect(const FileIntegrityError('Битый').toString(), 'Битый');
    });
  });

  group('локальное хранилище на диске', () {
    late Directory dir;
    late DirectoryAttachmentStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('study_files_test');
      store = DirectoryAttachmentStore(() async => dir);
    });
    tearDown(() => dir.delete(recursive: true));

    test(
      'запись, чтение, наличие, удаление; временных файлов не остаётся',
      () async {
        expect(await store.exists('a1'), isFalse);
        expect(await store.read('a1'), isNull);
        await store.write('a1', Uint8List.fromList([1, 2, 3]));
        expect(await store.exists('a1'), isTrue);
        expect(await store.read('a1'), [1, 2, 3]);
        await store.write('a1', Uint8List.fromList([4]));
        expect(await store.read('a1'), [4]);
        final names = Directory('${dir.path}/files')
            .listSync()
            .map((e) => e.uri.pathSegments.last)
            .toList();
        expect(names, ['a1']);
        await store.delete('a1');
        await store.delete('a1');
        expect(await store.exists('a1'), isFalse);
      },
    );

    test(
      'копия для просмотра с настоящим именем; чужие пути отвергаются',
      () async {
        await store.write('a2', Uint8List.fromList([9]));
        final path = await store.exportForViewing('a2', 'Отчёт/2026.docx');
        expect(path, endsWith('Отчёт_2026.docx'));
        expect(File(path).readAsBytesSync(), [9]);
        await expectLater(
          store.exportForViewing('нет', 'a.pdf'),
          throwsStateError,
        );
        for (final bad in ['', '..', 'a/b', r'a\b']) {
          await expectLater(
            store.exists(bad),
            throwsArgumentError,
            reason: bad,
          );
        }
      },
    );

    test('память: то же поведение', () async {
      final memory = MemoryAttachmentStore();
      await memory.write('x', Uint8List.fromList([1]));
      expect(await memory.exists('x'), isTrue);
      expect(await memory.read('x'), [1]);
      expect(await memory.exportForViewing('x', 'f.pdf'), '/memory/x/f.pdf');
      await memory.delete('x');
      expect(await memory.exists('x'), isFalse);
    });
  });

  group('HTTP-клиент файлов (PUT и GET поверх ApiClient)', () {
    late _FilesAdapter adapter;
    late HttpFilesApi api;

    setUp(() {
      adapter = _FilesAdapter();
      final client = ApiClient(
        dio: ApiClient.createDio(
          baseUrl: Uri.parse('http://localhost:8000'),
          adapter: adapter,
        ),
        schemaVersion: 8,
      );
      api = HttpFilesApi(() async => client);
    });

    test('PUT: сырые байты, тип и длина; 201 — stored, 200 — exists', () async {
      final bytes = fakePdf('данные');
      expect(await api.upload('f1', bytes), UploadOutcome.stored);
      expect(adapter.last.method, 'PUT');
      expect(adapter.last.path, '/files/f1');
      expect(adapter.last.contentType, 'application/octet-stream');
      expect(adapter.last.body, bytes);
      expect(adapter.last.schemaVersion, '8');
      expect(await api.upload('f1', bytes), UploadOutcome.exists);
    });

    test('PUT: ошибки сервера приходят кодом', () async {
      adapter.failWith = (422, 'hash_mismatch');
      await expectLater(
        api.upload('f2', fakePdf()),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'статус', 422)
              .having((e) => e.code, 'код', 'hash_mismatch'),
        ),
      );
    });

    test('GET: байты; ошибка в JSON-теле разбирается; обрыв — сеть', () async {
      adapter.store['f3'] = Uint8List.fromList([1, 2, 3]);
      expect(await api.download('f3'), [1, 2, 3]);
      await expectLater(
        api.download('нет'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'код', 'file_not_uploaded'),
        ),
      );
      adapter.drop = true;
      await expectLater(
        api.download('f3'),
        throwsA(isA<ApiException>().having((e) => e.isNetwork, 'сеть', isTrue)),
      );
      await expectLater(
        api.upload('f3', fakePdf()),
        throwsA(isA<ApiException>().having((e) => e.isNetwork, 'сеть', isTrue)),
      );
    });

    test('сервер не настроен', () async {
      final none = HttpFilesApi(() async => null);
      await expectLater(
        none.upload('x', fakePdf()),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'код', 'not_configured'),
        ),
      );
      await expectLater(
        none.download('x'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'код', 'not_configured'),
        ),
      );
    });
  });
}

/// Репозиторий, у которого запись метаданных падает.
class _FailingRepo extends StudyRepository {
  _FailingRepo(StudyDevice device)
    : super(device.device.store, newId: () => _uuid(9999));

  @override
  Future<String> createAttachment(Attachment attachment) async =>
      throw StateError('нет места');
}

class _Request {
  _Request(
    this.method,
    this.path,
    this.contentType,
    this.schemaVersion,
    this.body,
  );

  final String method;
  final String path;
  final String? contentType;
  final String? schemaVersion;
  final Uint8List body;
}

/// Файловый сервер на уровне HTTP: `PUT` кладёт тело, `GET` отдаёт байты;
/// ошибка — стандартная форма `{"error": {"code": …}}`.
class _FilesAdapter implements HttpClientAdapter {
  final Map<String, Uint8List> store = {};
  final List<_Request> requests = [];
  (int, String)? failWith;
  bool drop = false;

  _Request get last => requests.last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (drop) {
      throw DioException.connectionError(requestOptions: options, reason: 't');
    }
    final body = <int>[];
    if (requestStream != null) {
      await requestStream.forEach(body.addAll);
    }
    requests.add(
      _Request(
        options.method,
        options.path,
        options.contentType,
        options.headers['X-Client-Schema-Version'] as String?,
        Uint8List.fromList(body),
      ),
    );
    final id = options.path.split('/').last;
    ResponseBody error(int status, String code) => ResponseBody.fromBytes(
      utf8.encode(
        jsonEncode({
          'error': {'code': code, 'message': code},
        }),
      ),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
    final failure = failWith;
    if (failure != null) return error(failure.$1, failure.$2);
    if (options.method == 'PUT') {
      final exists = store.containsKey(id);
      store[id] = Uint8List.fromList(body);
      return ResponseBody.fromString(
        jsonEncode({'status': exists ? 'exists' : 'stored'}),
        exists ? 200 : 201,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final data = store[id];
    if (data == null) return error(404, 'file_not_uploaded');
    return ResponseBody.fromBytes(data, 200);
  }

  @override
  void close({bool force = false}) {}
}
