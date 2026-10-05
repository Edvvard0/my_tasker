import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/study/application/attachment_providers.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/files_api.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/platform/document_opener.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';

/// Открывает вложение системным просмотрщиком (файл при необходимости
/// скачивается).
Future<DocumentOpenResult> openAttachmentExternally(
  WidgetRef ref,
  Attachment attachment,
) async {
  try {
    final path = await ref
        .read(attachmentServiceProvider)
        .pathForViewing(attachment);
    return await ref
        .read(documentOpenerProvider)
        .open(path, attachment.mimeType);
  } on Object {
    return DocumentOpenResult.failed;
  }
}

/// Просмотр картинки вложения в приложении (масштаб щипком). Файл берётся
/// с устройства или скачивается с сервера (с проверкой размера и SHA-256).
class AttachmentViewerScreen extends ConsumerWidget {
  const AttachmentViewerScreen({required this.attachmentId, super.key});

  final String attachmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(studyDataProvider);
    final attachment = data.value?.attachments
        .where((a) => a.id == attachmentId)
        .firstOrNull;
    return ScreenScaffold(
      key: const Key('attachment-viewer'),
      title: attachment?.fileName ?? 'Файл',
      onBack: () => studyBack(context),
      scrollable: false,
      child: attachment == null
          ? const EmptyState(
              icon: LucideIcons.fileQuestionMark,
              title: 'Файл не найден',
              message: 'Возможно, его удалили на другом устройстве.',
            )
          : ref
                .watch(attachmentBytesProvider(attachmentId))
                .when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => EmptyState(
                    icon: LucideIcons.triangleAlert,
                    title: 'Не удалось открыть файл',
                    message: fileErrorText(error),
                  ),
                  data: (bytes) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s6),
                    child: InteractiveViewer(
                      maxScale: 6,
                      child: Center(
                        child: Image.memory(
                          bytes,
                          key: const Key('attachment-image'),
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stack) =>
                              _Undecodable(attachment: attachment),
                        ),
                      ),
                    ),
                  ),
                ),
    );
  }
}

/// Картинку не удалось декодировать (например, HEIC на Windows): предлагаем
/// системный просмотрщик.
class _Undecodable extends ConsumerWidget {
  const _Undecodable({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'Эту картинку нельзя показать здесь.',
        key: const Key('attachment-undecodable'),
        style: context.text.body,
      ),
      const SizedBox(height: AppSpacing.s2),
      TextButton(
        key: const Key('attachment-open-external'),
        onPressed: () async {
          final result = await openAttachmentExternally(ref, attachment);
          if (!context.mounted || result == DocumentOpenResult.opened) return;
          ScaffoldMessenger.maybeOf(context)
            ?..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  result == DocumentOpenResult.noApp
                      ? 'На устройстве нет программы для этого файла.'
                      : 'Не удалось открыть файл.',
                ),
              ),
            );
        },
        child: const Text('Открыть в другой программе'),
      ),
    ],
  );
}
