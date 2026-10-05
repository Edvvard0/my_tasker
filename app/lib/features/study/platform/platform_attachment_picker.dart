// coverage:ignore-file
// Тонкая платформенная прослойка: камера и системные диалоги выбора файла
// без устройства не проверяются. Вся логика вложений — в `attachment_service`.

import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_tasker/features/study/domain/study_validation.dart'
    show maxFileBytes;
import 'package:my_tasker/features/study/platform/attachment_picker.dart';

/// Камера — `image_picker` (Android и iOS); галерея и документы —
/// `file_picker` (Android — системный выбор файлов, Windows — проводник).
class PlatformAttachmentPicker implements AttachmentPicker {
  const PlatformAttachmentPicker();

  static bool get _hasCamera => Platform.isAndroid || Platform.isIOS;

  @override
  Set<AttachmentSource> get sources => {
    if (_hasCamera) AttachmentSource.camera,
    AttachmentSource.gallery,
    AttachmentSource.document,
  };

  @override
  Future<PickedAttachment?> pick(AttachmentSource source) async {
    switch (source) {
      case AttachmentSource.camera:
        final shot = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 90,
        );
        if (shot == null) return null;
        if (await shot.length() > maxFileBytes) {
          throw const AttachmentTooLargeException();
        }
        final name = shot.name.contains('.') ? shot.name : '${shot.name}.jpg';
        return PickedAttachment(name: name, bytes: await shot.readAsBytes());
      case AttachmentSource.gallery:
        final file = await FilePicker.pickFile(
          dialogTitle: 'Фото',
          type: FileType.image,
        );
        return file == null ? null : await _read(file);
      case AttachmentSource.document:
        final file = await FilePicker.pickFile(
          dialogTitle: 'Документ',
          type: FileType.custom,
          allowedExtensions: const [
            'pdf',
            'doc',
            'docx',
            'xls',
            'xlsx',
            'ppt',
            'pptx',
            'txt',
            'zip',
          ],
        );
        return file == null ? null : await _read(file);
    }
  }

  /// Размер проверяется до чтения: файл больше лимита в память не грузится.
  /// Если размер неизвестен, содержимое читается потоком и обрывается на
  /// лимите.
  static Future<PickedAttachment> _read(PlatformFile file) async {
    final size = file.lengthSync() ?? await file.length();
    if (size != null) {
      if (size > maxFileBytes) throw const AttachmentTooLargeException();
      return PickedAttachment(name: file.name, bytes: await file.readAsBytes());
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      builder.add(chunk);
      if (builder.length > maxFileBytes) {
        throw const AttachmentTooLargeException();
      }
    }
    return PickedAttachment(name: file.name, bytes: builder.takeBytes());
  }
}
