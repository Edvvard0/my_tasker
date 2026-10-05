// coverage:ignore-file
// Тонкая платформенная прослойка: камера и системные диалоги выбора файла
// без устройства не проверяются. Вся логика вложений — в `attachment_service`.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
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
        final name = shot.name.contains('.') ? shot.name : '${shot.name}.jpg';
        return PickedAttachment(name: name, bytes: await shot.readAsBytes());
      case AttachmentSource.gallery:
        final file = await FilePicker.pickFile(
          dialogTitle: 'Фото',
          type: FileType.image,
        );
        return file == null
            ? null
            : PickedAttachment(
                name: file.name,
                bytes: await file.readAsBytes(),
              );
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
        return file == null
            ? null
            : PickedAttachment(
                name: file.name,
                bytes: await file.readAsBytes(),
              );
    }
  }
}
