import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/study/application/attachment_providers.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/attachment_store.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/platform/attachment_picker.dart';
import 'package:my_tasker/features/study/platform/document_opener.dart';

import '../../support/study_env.dart';

Future<ProviderContainer> _subject(
  WidgetTester tester,
  StudyFakes fakes, {
  bool files = true,
}) async {
  final (container, _) = await pumpStudyDemo(
    tester,
    at: (d) => '/study/subjects/${d.math}',
    fakes: fakes,
    files: files,
  );
  return container;
}

Attachment _attachmentNamed(ProviderContainer c, String name) => c
    .read(studyDataProvider)
    .requireValue
    .attachments
    .firstWhere((a) => a.fileName == name);

/// Хранилище в памяти со счётчиком чтений.
class _CountingStore extends MemoryAttachmentStore {
  int reads = 0;

  @override
  Future<Uint8List?> read(String id) {
    reads++;
    return super.read(id);
  }
}

void main() {
  group('добавление файла', () {
    testWidgets('лист источников: камера, галерея, документ; выбор из '
        'галереи сохраняет файл на устройстве и в метаданных', (tester) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes, files: false);
      expect(find.byKey(const Key('attachments-empty')), findsOneWidget);
      fakes.picker.next = PickedAttachment(name: 'Фото.jpg', bytes: fakeJpeg());
      await tapKey(tester, 'attachment-add');
      for (final s in ['camera', 'gallery', 'document']) {
        expect(find.byKey(Key('attach-source-$s')), findsOneWidget);
      }
      await tapKey(tester, 'attach-source-gallery');
      expect(fakes.picker.picks, [AttachmentSource.gallery]);
      final a = _attachmentNamed(container, 'Фото.jpg');
      expect(a.mimeType, 'image/jpeg');
      expect(a.uploadStatus, UploadStatus.pending);
      expect(await fakes.files.exists(a.id), isTrue);
      expect(find.text('Фото.jpg'), findsOneWidget);
    });

    testWidgets('нет камеры (Windows): источника «Камера» нет', (tester) async {
      final fakes = StudyFakes(
        picker: FakeAttachmentPicker(
          available: {AttachmentSource.gallery, AttachmentSource.document},
        ),
      );
      await _subject(tester, fakes, files: false);
      await tapKey(tester, 'attachment-add');
      expect(find.byKey(const Key('attach-source-camera')), findsNothing);
      expect(find.byKey(const Key('attach-source-document')), findsOneWidget);
    });

    testWidgets('документ с камеры: имя без расширения получает его от '
        'выбора; закрытый диалог и сбой выбора ничего не добавляют', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes, files: false);
      // Диалог закрыт.
      await tapKey(tester, 'attachment-add');
      await tapKey(tester, 'attach-source-document');
      expect(find.byKey(const Key('attachments-empty')), findsOneWidget);
      // Сбой платформы.
      fakes.picker.error = Exception('нет доступа');
      await tapKey(tester, 'attachment-add');
      await tapKey(tester, 'attach-source-camera');
      expect(find.text('Не удалось выбрать файл.'), findsOneWidget);
      expect(
        container.read(studyDataProvider).requireValue.attachments,
        isEmpty,
      );
    });

    testWidgets('тип не из списка отклоняется с понятным сообщением', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes, files: false);
      fakes.picker.next = PickedAttachment(
        name: 'программа.exe',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      await tapKey(tester, 'attachment-add');
      await tapKey(tester, 'attach-source-document');
      expect(find.textContaining('не поддерживается'), findsOneWidget);
      expect(
        container.read(studyDataProvider).requireValue.attachments,
        isEmpty,
      );
      expect(fakes.files.files, isEmpty);
    });

    testWidgets('содержимое не подходит к типу: отказ сразу, файл не '
        'сохраняется', (tester) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes, files: false);
      fakes.picker.next = PickedAttachment(
        name: 'Сканы.pdf',
        bytes: Uint8List.fromList(List.filled(32, 7)),
      );
      await tapKey(tester, 'attachment-add');
      await tapKey(tester, 'attach-source-document');
      expect(find.textContaining('не подходит к его типу'), findsOneWidget);
      expect(
        container.read(studyDataProvider).requireValue.attachments,
        isEmpty,
      );
      expect(fakes.files.files, isEmpty);
    });

    testWidgets('слишком большой файл: отказ до чтения в память', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes, files: false);
      fakes.picker.error = const AttachmentTooLargeException();
      await tapKey(tester, 'attachment-add');
      await tapKey(tester, 'attach-source-document');
      expect(find.text('Файл больше 25 МБ.'), findsOneWidget);
      expect(
        container.read(studyDataProvider).requireValue.attachments,
        isEmpty,
      );
      expect(const AttachmentTooLargeException().toString(), contains('25'));
    });

    testWidgets('файл в карточке долга: «фото заданий и документы»', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.practice2}',
        fakes: fakes,
        files: false,
      );
      expect(
        find.text('Фото заданий и документы пока не добавлены.'),
        findsOneWidget,
      );
      fakes.picker.next = PickedAttachment(name: 'Задание.png', bytes: tinyPng);
      await tapKey(tester, 'attachment-add');
      await tapKey(tester, 'attach-source-camera');
      final a = _attachmentNamed(container, 'Задание.png');
      expect(a.debtId, demo.practice2);
      expect(a.mimeType, 'image/png');
      expect(find.text('Задание.png'), findsOneWidget);
    });
  });

  group('состояние файла и загрузка в фоне', () {
    testWidgets('pending → «Ждёт загрузки», после загрузки — «на устройстве и '
        'на сервере»', (tester) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes);
      expect(find.textContaining('Ждёт загрузки на сервер'), findsOneWidget);
      final a = _attachmentNamed(container, 'Методичка.pdf');
      // Метаданные дошли до сервера; фоновая загрузка отправляет файл.
      fakes.synced(a);
      final report = await tester.runAsync(
        () => container.read(attachmentTransferProvider.notifier).kick(),
      );
      expect(report!.uploaded, [a.id]);
      await tester.pumpAndSettle();
      expect(find.textContaining('На устройстве и на сервере'), findsOneWidget);
      expect(fakes.api.stored[a.id], isNotNull);
    });

    testWidgets('окончательный отказ сервера показывается красным текстом', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes);
      final a = _attachmentNamed(container, 'Методичка.pdf');
      fakes.synced(a);
      // На устройстве лежит не тот файл: сервер ответит 422 hash_mismatch.
      final tampered = Uint8List.fromList((await fakes.files.read(a.id))!);
      tampered[tampered.length - 1] ^= 1;
      await fakes.files.write(a.id, tampered);
      final report = await tester.runAsync(
        () => container.read(attachmentTransferProvider.notifier).kick(),
      );
      expect(report!.failed[a.id], 'hash_mismatch');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Содержимое файла не совпало'),
        findsOneWidget,
      );
      final state = container.read(attachmentTransferProvider);
      expect(state.failureOf(a.id), contains('Содержимое файла не совпало'));
      expect(state.failureOf('нет'), isNull);
      expect(state.uploading, isFalse);
    });

    testWidgets('окончательный отказ не повторяется сам; «Повторить загрузку» '
        'в меню файла запускает заново', (tester) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes);
      final a = _attachmentNamed(container, 'Методичка.pdf');
      fakes.synced(a);
      final tampered = Uint8List.fromList((await fakes.files.read(a.id))!);
      tampered[tampered.length - 1] ^= 1;
      await fakes.files.write(a.id, tampered);
      int callsFor(Attachment x) =>
          fakes.api.uploadCalls.where((id) => id == x.id).length;
      final notifier = container.read(attachmentTransferProvider.notifier);
      await tester.runAsync(notifier.kick);
      expect(callsFor(a), 1);
      // Следующие проходы (синхронизация, перезапуск) файл не шлют.
      await tester.runAsync(notifier.kick);
      await tester.runAsync(notifier.kick);
      expect(callsFor(a), 1);
      await tester.pumpAndSettle();
      await tapKey(tester, 'attachment-menu-${a.id}');
      await tapKey(tester, 'attachment-retry');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(callsFor(a), 2);
    });

    testWidgets('сбой загрузки не роняет приложение: повтор позже', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes);
      final a = _attachmentNamed(container, 'Методичка.pdf');
      fakes.synced(a);
      fakes.api.dropNextUploads = 1;
      final report = await tester.runAsync(
        () => container.read(attachmentTransferProvider.notifier).kick(),
      );
      expect(report!.retryLater, contains(a.id));
      expect(find.textContaining('Ждёт загрузки'), findsWidgets);
    });

    testWidgets('файл другого устройства: ещё не загружен / на сервере', (
      tester,
    ) async {
      final fakes = StudyFakes();
      late String pending;
      late String uploaded;
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/subjects/${d.math}',
        fakes: fakes,
        files: false,
      );
      await tester.runAsync(() async {
        final repo = container.read(studyRepositoryProvider);
        pending = repo.newId();
        uploaded = repo.newId();
        for (final (id, name, status) in [
          (pending, 'Ждёт.pdf', UploadStatus.pending),
          (uploaded, 'Лежит.pdf', UploadStatus.uploaded),
        ]) {
          await repo.createAttachment(
            Attachment(
              id: id,
              subjectId: demo.math,
              fileName: name,
              mimeType: 'application/pdf',
              sizeBytes: 5,
              sha256: 'a' * 64,
              uploadStatus: status,
            ),
          );
        }
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Ещё не загружен на сервер'), findsOneWidget);
      expect(
        find.textContaining('На сервере · скачается при открытии'),
        findsOneWidget,
      );
    });
  });

  group('открытие файла', () {
    testWidgets('документ открывается системным просмотрщиком с настоящим '
        'именем', (tester) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes);
      final a = _attachmentNamed(container, 'Методичка.pdf');
      await tester.tap(find.byKey(Key('attachment-${a.id}')));
      await tester.pumpAndSettle();
      expect(fakes.opener.opened.single, (
        '/memory/${a.id}/Методичка.pdf',
        'application/pdf',
      ));
    });

    testWidgets('нет программы / сбой открытия: сообщение', (tester) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes);
      final a = _attachmentNamed(container, 'Методичка.pdf');
      fakes.opener.result = DocumentOpenResult.noApp;
      await tester.tap(find.byKey(Key('attachment-${a.id}')));
      await tester.pumpAndSettle();
      expect(
        find.text('На устройстве нет программы для этого файла.'),
        findsOneWidget,
      );
      fakes.opener.result = DocumentOpenResult.failed;
      await tester.tap(find.byKey(Key('attachment-${a.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось открыть файл.'), findsOneWidget);
    });

    testWidgets('картинка открывается в приложении', (tester) async {
      final fakes = StudyFakes();
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/debts/${d.practice2}',
        fakes: fakes,
        files: false,
      );
      fakes.picker.next = PickedAttachment(name: 'Задание.png', bytes: tinyPng);
      await tapKey(tester, 'attachment-add');
      await tapKey(tester, 'attach-source-gallery');
      final a = _attachmentNamed(container, 'Задание.png');
      expect(a.debtId, demo.practice2);
      await tester.tap(find.byKey(Key('attachment-${a.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('attachment-viewer')), findsOneWidget);
      expect(find.byKey(const Key('attachment-image')), findsOneWidget);
    });

    testWidgets('файл другого устройства скачивается при открытии', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/subjects/${d.math}',
        fakes: fakes,
        files: false,
      );
      final bytes = fakePdf('с другого устройства');
      late Attachment a;
      await tester.runAsync(() async {
        final repo = container.read(studyRepositoryProvider);
        a = Attachment(
          id: repo.newId(),
          subjectId: demo.math,
          fileName: 'Конспект.pdf',
          mimeType: 'application/pdf',
          sizeBytes: bytes.length,
          sha256: sha256Of(bytes),
          uploadStatus: UploadStatus.uploaded,
        );
        await repo.createAttachment(a);
      });
      fakes
        ..synced(a)
        ..api.stored[a.id] = bytes;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('attachment-${a.id}')));
      await tester.pumpAndSettle();
      expect(fakes.api.downloadCalls, [a.id]);
      expect(await fakes.files.exists(a.id), isTrue);
      expect(fakes.opener.opened.single.$1, endsWith('Конспект.pdf'));
      expect(find.textContaining('На устройстве и на сервере'), findsOneWidget);
    });

    testWidgets('скачать нельзя: файл ещё не загружен — понятное сообщение', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/subjects/${d.math}',
        fakes: fakes,
        files: false,
      );
      late Attachment a;
      await tester.runAsync(() async {
        final repo = container.read(studyRepositoryProvider);
        a = Attachment(
          id: repo.newId(),
          subjectId: demo.math,
          fileName: 'Конспект.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 5,
          sha256: 'a' * 64,
        );
        await repo.createAttachment(a);
      });
      fakes.synced(a);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('attachment-${a.id}')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('ещё не загружен на сервер с устройства'),
        findsOneWidget,
      );
      expect(fakes.opener.opened, isEmpty);
    });

    testWidgets('просмотрщик читает файл один раз, а не при каждой '
        'перерисовке', (tester) async {
      final counting = _CountingStore();
      final fakes = StudyFakes(files: counting);
      final (container, demo) = await pumpStudyDemo(
        tester,
        fakes: fakes,
        files: false,
      );
      late Attachment a;
      await tester.runAsync(() async {
        a = await container
            .read(attachmentServiceProvider)
            .add(fileName: 'Схема.png', bytes: tinyPng, subjectId: demo.math);
      });
      counting.reads = 0;
      await goTo(tester, container, '/study/files/${a.id}');
      expect(find.byKey(const Key('attachment-image')), findsOneWidget);
      final afterOpen = counting.reads;
      // Правка вложения перерисовывает экран, но файл не перечитывается.
      await tester.runAsync(
        () => container
            .read(studyRepositoryProvider)
            .renameAttachment(a.id, 'Схема 2.png'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Схема 2.png'), findsOneWidget);
      expect(counting.reads, afterOpen);
    });

    testWidgets('HEIC на Windows открывается системным просмотрщиком, а не '
        '«картинкой» приложения', (tester) async {
      final fakes = StudyFakes();
      final (container, demo) = await pumpStudyDemo(
        tester,
        at: (d) => '/study/subjects/${d.math}',
        fakes: fakes,
        files: false,
      );
      late Attachment a;
      await tester.runAsync(() async {
        a = await container
            .read(attachmentServiceProvider)
            .add(
              fileName: 'Снимок.heic',
              bytes: Uint8List.fromList([
                0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63, //
                ...List.filled(8, 0),
              ]),
              subjectId: demo.math,
            );
      });
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.tap(find.byKey(Key('attachment-${a.id}')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('attachment-viewer')), findsNothing);
        expect(fakes.opener.opened.single.$2, 'image/heic');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('просмотрщик: испорченная картинка и ошибка скачивания', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final (container, demo) = await pumpStudyDemo(
        tester,
        fakes: fakes,
        files: false,
      );
      late Attachment broken;
      late Attachment remote;
      await tester.runAsync(() async {
        final service = container.read(attachmentServiceProvider);
        broken = await service.add(
          fileName: 'битая.png',
          // Заголовок PNG есть (клиент пропускает), картинки — нет.
          bytes: Uint8List.fromList([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
            ...List.filled(12, 1),
          ]),
          subjectId: demo.math,
        );
        final repo = container.read(studyRepositoryProvider);
        remote = Attachment(
          id: repo.newId(),
          subjectId: demo.math,
          fileName: 'чужая.png',
          mimeType: 'image/png',
          sizeBytes: 5,
          sha256: 'a' * 64,
        );
        await repo.createAttachment(remote);
      });
      await goTo(tester, container, '/study/files/${broken.id}');
      expect(find.byKey(const Key('attachment-undecodable')), findsOneWidget);
      // Системный просмотрщик — запасной путь.
      await tapKey(tester, 'attachment-open-external');
      expect(fakes.opener.opened.single, (
        '/memory/${broken.id}/битая.png',
        'image/png',
      ));
      fakes.opener.result = DocumentOpenResult.noApp;
      await tapKey(tester, 'attachment-open-external');
      expect(
        find.text('На устройстве нет программы для этого файла.'),
        findsOneWidget,
      );
      fakes.synced(remote);
      await goTo(tester, container, '/study/files/${remote.id}');
      expect(find.text('Не удалось открыть файл'), findsOneWidget);
      await goTo(tester, container, '/study/files/нет-такого');
      expect(find.text('Файл не найден'), findsOneWidget);
    });
  });

  group('переименование и удаление', () {
    testWidgets('переименовать: расширение должно подходить к типу', (
      tester,
    ) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes);
      final a = _attachmentNamed(container, 'Методичка.pdf');
      await tester.tap(find.byKey(Key('attachment-menu-${a.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('attachment-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('attachment-rename-field')),
        'Лекции.docx',
      );
      await tapKey(tester, 'attachment-rename-ok');
      expect(
        find.text('Расширение файла не подходит к его типу'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(Key('attachment-menu-${a.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('attachment-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('attachment-rename-field')),
        'Лекции.pdf',
      );
      await tapKey(tester, 'attachment-rename-ok');
      expect(find.text('Лекции.pdf'), findsOneWidget);
    });

    testWidgets('убрать файл: подтверждение и корзина', (tester) async {
      final fakes = StudyFakes();
      final container = await _subject(tester, fakes);
      final a = _attachmentNamed(container, 'Методичка.pdf');
      await tester.tap(find.byKey(Key('attachment-menu-${a.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('attachment-delete')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'confirm-cancel');
      expect(find.text('Методичка.pdf'), findsOneWidget);
      await tester.tap(find.byKey(Key('attachment-menu-${a.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('attachment-delete')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'confirm-ok');
      expect(find.text('Методичка.pdf'), findsNothing);
      expect(
        container
            .read(studyDataProvider)
            .requireValue
            .attachments
            .where((x) => x.id == a.id),
        isEmpty,
      );
    });
  });
}
