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
import 'package:my_tasker/features/study/presentation/study_forms.dart';

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
          : FutureBuilder(
              future: ref.read(attachmentServiceProvider).bytesOf(attachment),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return EmptyState(
                    icon: LucideIcons.triangleAlert,
                    title: 'Не удалось открыть файл',
                    message: fileErrorText(snapshot.error!),
                  );
                }
                final bytes = snapshot.data;
                if (bytes == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.s6),
                  child: InteractiveViewer(
                    maxScale: 6,
                    child: Center(
                      child: Image.memory(
                        bytes,
                        key: const Key('attachment-image'),
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stack) => Text(
                          'Это не картинка, которую можно показать.',
                          style: context.text.body,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
