import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/study/platform/platform_attachment_picker.dart';

/// Откуда взять файл вложения.
enum AttachmentSource {
  /// Снимок камерой (фото задания).
  camera('Камера'),

  /// Фото из галереи.
  gallery('Галерея'),

  /// Документ: PDF, Office, TXT, ZIP.
  document('Документ');

  const AttachmentSource(this.label);

  final String label;
}

/// Выбранный файл.
@immutable
class PickedAttachment {
  const PickedAttachment({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Выбор файла вложения: камера, галерея и документ. Реализация —
/// `image_picker` (камера) и `file_picker`; тесты подставляют поддельный
/// выбор. Недоступный источник (камера на Windows) в [sources] не входит.
abstract interface class AttachmentPicker {
  Set<AttachmentSource> get sources;

  /// `null`, если человек закрыл диалог.
  Future<PickedAttachment?> pick(AttachmentSource source);
}

final Provider<AttachmentPicker> attachmentPickerProvider =
    Provider<AttachmentPicker>((ref) => const PlatformAttachmentPicker());
