import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/study/application/attachment_providers.dart';
import 'package:my_tasker/features/study/data/attachment_service.dart';
import 'package:my_tasker/features/study/data/attachment_store.dart';
import 'package:my_tasker/features/study/data/files_api.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/domain/study_validation.dart';
import 'package:my_tasker/features/study/platform/attachment_picker.dart';
import 'package:my_tasker/features/study/platform/document_opener.dart';

import 'calendar_env.dart' show appRegistry;
import 'fake_server/fake_sync_server.dart';
import 'manual_clock.dart';
import 'pump_app.dart';
import 'sync_env.dart';
import 'work_env.dart' show goTo;

export 'pump_app.dart' show desktopSize, expandedSize, mediumSize, phoneSize;
export 'work_env.dart' show goTo, locationOf, tapKey;

/// «Сейчас» для экранов «Учёбы»: понедельник, 5 октября 2026, 12:00 по
/// Москве; неделя цикла — чётная (опора семестра — 31 августа).
final DateTime studyNow = DateTime.utc(2026, 10, 5, 9);

/// Самая маленькая настоящая PNG-картинка (1×1) — для просмотрщика.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// Начало PDF: проходит проверку «первых байтов» сервера.
Uint8List fakePdf([String body = 'содержимое']) =>
    Uint8List.fromList([...utf8.encode('%PDF-1.4\n'), ...utf8.encode(body)]);

String sha256Of(Uint8List bytes) => sha256.convert(bytes).toString();

/// Поддельный файловый API: те же проверки, что у сервера (spec 7.2–7.3) —
/// размер и SHA-256 из метаданных, лимит, тип по первым байтам, идемпотент-
/// ность, чужой/неизвестный `id`; плюс управляемые сбои (обрыв).
class FakeFilesApi implements FilesApi {
  FakeFilesApi({required this.metaOf});

  /// Метаданные вложения по `id` (то, что сервер уже получил
  /// синхронизацией) или `null`.
  final Map<String, Object?>? Function(String id) metaOf;

  final Map<String, Uint8List> stored = {};

  /// Чужие файлы: сервер отвечает как на неизвестный `id`.
  final Set<String> foreign = {};

  /// Следующий `upload` обрывается: сетевой сбой, файл не сохраняется.
  int dropNextUploads = 0;

  /// Следующий `download` обрывается.
  int dropNextDownloads = 0;

  /// Скачивание отдаёт испорченное содержимое (тот же размер, другие байты).
  bool corruptDownloads = false;

  /// Скачивание отдаёт файл другой длины.
  bool truncateDownloads = false;

  /// Сервер отвечает ошибкой 5xx.
  bool serverDown = false;

  final List<String> uploadCalls = [];
  final List<String> downloadCalls = [];

  static ApiException _http(int status, String code) =>
      ApiException(kind: ApiErrorKind.http, status: status, code: code);

  @override
  Future<UploadOutcome> upload(String attachmentId, Uint8List bytes) async {
    uploadCalls.add(attachmentId);
    if (serverDown) throw _http(503, 'unavailable');
    if (dropNextUploads > 0) {
      dropNextUploads--;
      throw const ApiException.network('connectionError');
    }
    final meta = foreign.contains(attachmentId) ? null : metaOf(attachmentId);
    if (meta == null) throw _http(404, 'attachment_not_found');
    final size = meta['size_bytes']! as int;
    if (size > maxFileBytes) throw _http(413, 'payload_too_large');
    if (stored.containsKey(attachmentId)) return UploadOutcome.exists;
    if (bytes.length != size) throw _http(422, 'size_mismatch');
    if (sha256Of(bytes) != meta['sha256']) throw _http(422, 'hash_mismatch');
    if (!_magicFits(meta['mime_type']! as String, bytes)) {
      throw _http(415, 'content_type_mismatch');
    }
    stored[attachmentId] = bytes;
    return UploadOutcome.stored;
  }

  @override
  Future<Uint8List> download(String attachmentId) async {
    downloadCalls.add(attachmentId);
    if (serverDown) throw _http(503, 'unavailable');
    if (dropNextDownloads > 0) {
      dropNextDownloads--;
      throw const ApiException.network('connectionError');
    }
    final meta = foreign.contains(attachmentId) ? null : metaOf(attachmentId);
    if (meta == null) throw _http(404, 'attachment_not_found');
    final data = stored[attachmentId];
    if (data == null) throw _http(404, 'file_not_uploaded');
    if (corruptDownloads) {
      return Uint8List.fromList([for (final b in data) b ^ 0xFF]);
    }
    if (truncateDownloads) return data.sublist(0, data.length - 1);
    return data;
  }

  static bool _magicFits(String mime, Uint8List bytes) {
    bool starts(List<int> prefix) =>
        bytes.length >= prefix.length &&
        [for (var i = 0; i < prefix.length; i++) bytes[i]].toString() ==
            prefix.toString();
    return switch (mime) {
      'application/pdf' => starts([0x25, 0x50, 0x44, 0x46]),
      'image/png' => starts([0x89, 0x50, 0x4E, 0x47]),
      'image/jpeg' => starts([0xFF, 0xD8, 0xFF]),
      _ => true,
    };
  }
}

/// Поддельный выбор файла: что выбрать, какие источники доступны.
class FakeAttachmentPicker implements AttachmentPicker {
  FakeAttachmentPicker({
    this.available = const {
      AttachmentSource.camera,
      AttachmentSource.gallery,
      AttachmentSource.document,
    },
  });

  final Set<AttachmentSource> available;
  PickedAttachment? next;
  Exception? error;
  final List<AttachmentSource> picks = [];

  @override
  Set<AttachmentSource> get sources => available;

  @override
  Future<PickedAttachment?> pick(AttachmentSource source) async {
    picks.add(source);
    final e = error;
    if (e != null) throw e;
    final file = next;
    next = null;
    return file;
  }
}

/// Поддельный системный просмотрщик документов.
class FakeDocumentOpener implements DocumentOpener {
  DocumentOpenResult result = DocumentOpenResult.opened;
  final List<(String, String)> opened = [];

  @override
  Future<DocumentOpenResult> open(String path, String mimeType) async {
    opened.add((path, mimeType));
    return result;
  }
}

/// Устройство в тесте: репозиторий «Учёбы», файловое хранилище в памяти и
/// файловый API сервера поверх [TestDevice] (тесты синхронизации и
/// вложений без интерфейса).
class StudyDevice {
  StudyDevice(
    this.device,
    this.server, {
    FakeFilesApi? api,
    String Function()? newId,
  }) : study = StudyRepository(
         device.store,
         newId: newId,
         now: () => device.clock.now,
       ),
       files = MemoryAttachmentStore() {
    this.api =
        api ?? FakeFilesApi(metaOf: (id) => server.row('attachments', id));
    attachments = AttachmentService(
      repository: study,
      files: files,
      api: this.api,
      newId: newId,
    );
  }

  static Future<StudyDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    String Function()? newId,
    FakeFilesApi? api,
  }) async => StudyDevice(
    await TestDevice.create(server, clock: clock, registry: appRegistry()),
    server,
    api: api,
    newId: newId,
  );

  final TestDevice device;
  final FakeSyncServer server;
  final StudyRepository study;
  final MemoryAttachmentStore files;
  late final FakeFilesApi api;
  late final AttachmentService attachments;

  Future<void> close() => device.close();
}

/// Идентификаторы демо-данных.
class StudyDemo {
  const StudyDemo({
    required this.semester,
    required this.math,
    required this.physics,
    required this.prog,
    required this.mathMon,
    required this.physMon,
    required this.progTue,
    required this.mathThu,
    required this.rule,
    required this.lab1,
    required this.practice2,
    required this.credit,
    required this.physLab,
  });

  final String semester;
  final String math;
  final String physics;
  final String prog;
  final String mathMon;
  final String physMon;
  final String progTue;
  final String mathThu;
  final String rule;
  final String lab1;
  final String practice2;
  final String credit;
  final String physLab;
}

/// Демо по случаю заказчика (docs/briefs/stage-7.md): семестр «Осень 2026»
/// (1 сентября — 31 декабря, чёт/нечёт от 31 августа); «Математический
/// анализ» (Иванов, к1 28, лимит 4), «Физика» (к2 101, лимит 3),
/// «Программирование» (без лимита). Пары: пн №1 матан (каждую неделю), пн №2
/// физика-лаба (нечётные), вт №3 программирование (чётные), чт №1–3 обычные;
/// правило на четверг — «Подготовка к олимпиаде» (3 занятия, обычных пар
/// нет). Отметки матана: 7 сентября — пропуск, 14 — был; долги: «ЛР 1»
/// (просрочена на 5 дней), «Практика 2», «Зачёт» (сдан), у физики «ЛР 3».
Future<StudyDemo> seedStudyDemo(ProviderContainer container) async {
  final repo = container.read(studyRepositoryProvider);
  final semester = repo.newId();
  await repo.createSemester(
    Semester(
      id: semester,
      name: 'Осень 2026',
      startDate: '2026-09-01',
      endDate: '2026-12-31',
      week1Start: '2026-08-31',
    ),
  );
  await repo.replaceBells(
    semesterId: semester,
    grid: generateBells('08:30', 90, [10, 10, 30, 10, 10], 6)!,
  );

  Future<String> subject(
    String name, {
    String? teacher,
    String? building,
    String? room,
    int? limit,
    String? note,
  }) async {
    final id = repo.newId();
    await repo.createSubject(
      Subject(
        id: id,
        semesterId: semester,
        name: name,
        teacher: teacher,
        building: building,
        room: room,
        absenceLimit: limit,
        note: note,
      ),
    );
    return id;
  }

  final math = await subject(
    'Математический анализ',
    teacher: 'Иванов Иван Иванович',
    building: '1',
    room: '28',
    limit: 4,
  );
  final physics = await subject(
    'Физика',
    teacher: 'Петрова Анна Сергеевна',
    building: '2',
    room: '101',
    limit: 3,
  );
  final prog = await subject('Программирование', teacher: 'Сидоров П. К.');

  Future<String> slot(
    String subjectId,
    int weekday,
    int number,
    LessonKind kind, {
    int? cycleWeek,
    String? building,
    String? room,
  }) async {
    final id = repo.newId();
    await repo.createSlot(
      ClassSlot(
        id: id,
        semesterId: semester,
        subjectId: subjectId,
        weekday: weekday,
        number: number,
        kind: kind,
        cycleWeek: cycleWeek,
        building: building,
        room: room,
      ),
    );
    return id;
  }

  final mathMon = await slot(math, 1, 1, LessonKind.lecture);
  final physMon = await slot(physics, 1, 2, LessonKind.lab, cycleWeek: 1);
  final progTue = await slot(prog, 2, 3, LessonKind.practice, cycleWeek: 2);
  final mathThu = await slot(math, 4, 1, LessonKind.lecture);
  await slot(physics, 4, 2, LessonKind.lecture);
  await slot(prog, 4, 3, LessonKind.lecture);

  final rule = await repo.saveDayRule(
    semester,
    const DayRule(
      id: '',
      semesterId: '',
      weekday: 4,
      title: 'Подготовка к олимпиаде',
      hideRegular: true,
      items: [
        RuleItem(
          key: 'i1',
          title: 'Подготовка к олимпиаде',
          kind: LessonKind.other,
          number: 1,
        ),
        RuleItem(
          key: 'i2',
          title: 'Подготовка к олимпиаде',
          kind: LessonKind.other,
          number: 2,
        ),
        RuleItem(
          key: 'i3',
          title: 'Подготовка к олимпиаде',
          kind: LessonKind.other,
          number: 3,
        ),
      ],
    ),
  );

  await repo.mark(mathMon, '2026-09-07', AttendanceStatus.absent);
  await repo.mark(mathMon, '2026-09-14', AttendanceStatus.present);

  Future<String> debt(
    String subjectId,
    DebtKind kind,
    String title, {
    DebtStatus status = DebtStatus.open,
    String? due,
    String? done,
    String? note,
  }) async {
    final id = repo.newId();
    await repo.createDebt(
      StudyDebt(
        id: id,
        subjectId: subjectId,
        kind: kind,
        title: title,
        status: status,
        dueDate: due,
        doneDate: done,
        note: note,
      ),
    );
    return id;
  }

  final lab1 = await debt(
    math,
    DebtKind.lab,
    'ЛР 1',
    due: '2026-09-30',
    note: 'Предел последовательности: вариант 7, оформить по ГОСТу',
  );
  final practice2 = await debt(
    math,
    DebtKind.practice,
    'Практика 2',
    due: '2026-10-20',
  );
  final credit = await debt(
    math,
    DebtKind.credit,
    'Зачёт',
    status: DebtStatus.submitted,
    done: '2026-09-25',
  );
  final physLab = await debt(physics, DebtKind.lab, 'ЛР 3');

  return StudyDemo(
    semester: semester,
    math: math,
    physics: physics,
    prog: prog,
    mathMon: mathMon,
    physMon: physMon,
    progTue: progTue,
    mathThu: mathThu,
    rule: rule,
    lab1: lab1,
    practice2: practice2,
    credit: credit,
    physLab: physLab,
  );
}

/// Всё, что подменяют экраны «Учёбы» в тестах.
class StudyFakes {
  StudyFakes({
    FakeAttachmentPicker? picker,
    FakeDocumentOpener? opener,
    MemoryAttachmentStore? files,
  }) : picker = picker ?? FakeAttachmentPicker(),
       opener = opener ?? FakeDocumentOpener(),
       files = files ?? MemoryAttachmentStore();

  final FakeAttachmentPicker picker;
  final FakeDocumentOpener opener;
  final MemoryAttachmentStore files;

  /// Файловый API создаётся при запуске приложения: ему нужны метаданные
  /// «сервера» — здесь это вложения, помеченные тестом синхронизированными.
  final Map<String, Map<String, Object?>> serverMeta = {};
  late final FakeFilesApi api = FakeFilesApi(metaOf: (id) => serverMeta[id]);

  /// Сколько раз служба просила синхронизацию перед загрузкой.
  int syncRequests = 0;

  List<Override> get overrides => [
    attachmentStoreProvider.overrideWithValue(files),
    filesApiProvider.overrideWithValue(api),
    // Без настоящего координатора синхронизации: сети в тестах нет.
    attachmentServiceProvider.overrideWith(
      (ref) => AttachmentService(
        repository: ref.watch(studyRepositoryProvider),
        files: files,
        api: api,
        syncNow: () async => syncRequests++,
      ),
    ),
    attachmentPickerProvider.overrideWithValue(picker),
    documentOpenerProvider.overrideWithValue(opener),
  ];

  /// «Сервер получил» метаданные вложения (после синхронизации).
  void synced(Attachment a) => serverMeta[a.id] = a.toFields();
}

/// Запускает приложение на экране «Учёбы» с зафиксированным временем и
/// поясом Москвы; [seed] наполняет демо-данными, [seedWith] — своими.
Future<ProviderContainer> pumpStudy(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/study',
  bool seed = false,
  DateTime? now,
  StudyFakes? fakes,
  Future<void> Function(ProviderContainer container)? seedWith,
  List<Override> overrides = const [],
}) async {
  final container = await pumpApp(
    tester,
    size: size,
    location: location,
    now: now ?? studyNow,
    settle: false,
    overrides: [
      deviceTimeZoneSourceProvider.overrideWithValue(
        const FixedTimeZoneSource('Europe/Moscow'),
      ),
      // Праздники РФ из файла приложения — без асинхронной загрузки ассета.
      holidayCalendarProvider.overrideWith(
        (ref) => HolidayCalendar.fromJsonString(
          File('assets/calendar/holidays_ru.json').readAsStringSync(),
        ),
      ),
      ...(fakes ?? StudyFakes()).overrides,
      ...overrides,
    ],
  );
  await tester.runAsync(() async {
    if (seed) await seedStudyDemo(container);
    if (seedWith != null) await seedWith(container);
  });
  await tester.pumpAndSettle();
  return container;
}

/// Начало JPEG: проходит проверку «первых байтов» сервера.
Uint8List fakeJpeg([int size = 2048]) => Uint8List.fromList([
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  for (var i = 0; i < size; i++) i % 251,
]);

/// Демо-вложения: методичка у матана и фото задания у «ЛР 1».
Future<void> seedStudyFiles(ProviderContainer container, StudyDemo demo) async {
  final service = container.read(attachmentServiceProvider);
  await service.add(
    fileName: 'Методичка.pdf',
    bytes: fakePdf(),
    subjectId: demo.math,
  );
  await service.add(
    fileName: 'Задание ЛР 1.jpg',
    bytes: fakeJpeg(),
    debtId: demo.lab1,
  );
}

/// Запускает приложение, наполняет демо-данными (с файлами при [files]) и
/// переходит на экран [at].
Future<(ProviderContainer, StudyDemo)> pumpStudyDemo(
  WidgetTester tester, {
  String Function(StudyDemo demo)? at,
  Size size = phoneSize,
  bool files = true,
  StudyFakes? fakes,
  List<Override> overrides = const [],
}) async {
  late StudyDemo demo;
  final container = await pumpStudy(
    tester,
    size: size,
    fakes: fakes,
    overrides: overrides,
    seedWith: (c) async {
      demo = await seedStudyDemo(c);
      if (files) await seedStudyFiles(c, demo);
    },
  );
  if (at != null) await goTo(tester, container, at(demo));
  return (container, demo);
}
