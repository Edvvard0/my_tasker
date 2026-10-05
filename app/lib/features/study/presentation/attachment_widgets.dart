import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/study/application/attachment_providers.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/files_api.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/platform/attachment_picker.dart';
import 'package:my_tasker/features/study/platform/document_opener.dart';
import 'package:my_tasker/features/study/presentation/study_widgets.dart';

void _say(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Выбирает файл из [source] и добавляет его владельцу (предмету или
/// долгу): файл сохраняется на устройстве сразу, загрузка на сервер идёт
/// в фоне.
Future<void> addAttachmentFrom(
  BuildContext context,
  WidgetRef ref, {
  required AttachmentSource source,
  String? subjectId,
  String? debtId,
}) async {
  final picker = ref.read(attachmentPickerProvider);
  final service = ref.read(attachmentServiceProvider);
  final transfer = ref.read(attachmentTransferProvider.notifier);
  PickedAttachment? picked;
  try {
    picked = await picker.pick(source);
  } on AttachmentTooLargeException {
    if (context.mounted) _say(context, 'Файл больше 25 МБ.');
    return;
  } on Object {
    if (context.mounted) _say(context, 'Не удалось выбрать файл.');
    return;
  }
  if (picked == null) return;
  try {
    await service.add(
      fileName: picked.name,
      bytes: picked.bytes,
      subjectId: subjectId,
      debtId: debtId,
    );
  } on ValidationError catch (e) {
    if (context.mounted) _say(context, e.message);
    return;
  }
  unawaited(transfer.kick());
}

/// Лист «Добавить файл»: камера, галерея, документ (доступные на этой
/// платформе).
Future<AttachmentSource?> pickAttachmentSource(
  BuildContext context,
  Set<AttachmentSource> sources,
) => showEditorSheet<AttachmentSource>(
  context,
  builder: (sheetContext) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SheetHeader(title: 'Добавить файл'),
      for (final s in AttachmentSource.values)
        if (sources.contains(s))
          ListTile(
            key: Key('attach-source-${s.name}'),
            leading: Icon(switch (s) {
              AttachmentSource.camera => LucideIcons.camera,
              AttachmentSource.gallery => LucideIcons.image,
              AttachmentSource.document => LucideIcons.fileText,
            }),
            title: Text(s.label),
            onTap: () => Navigator.of(sheetContext).pop(s),
          ),
      const SizedBox(height: AppSpacing.s4),
    ],
  ),
);

/// Секция вложений владельца: список файлов и кнопка «Добавить». Для
/// предмета — «Документы», для долга — «Фото заданий и документы».
class AttachmentSection extends ConsumerWidget {
  const AttachmentSection({this.subjectId, this.debtId, super.key})
    : assert(
        (subjectId == null) != (debtId == null),
        'Владелец — предмет или долг',
      );

  final String? subjectId;
  final String? debtId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(studyDataProvider).value;
    final items = data == null
        ? const <Attachment>[]
        : (subjectId != null
              ? data.attachmentsOfSubject(subjectId!)
              : data.attachmentsOfDebt(debtId!));
    final picker = ref.watch(attachmentPickerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (items.isEmpty)
          AppCard(
            child: Text(
              debtId != null
                  ? 'Фото заданий и документы пока не добавлены.'
                  : 'Документов пока нет.',
              key: const Key('attachments-empty'),
              style: context.text.bodyS.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          )
        else
          ListCard(
            child: Column(
              children: [for (final a in items) AttachmentTile(attachment: a)],
            ),
          ),
        const SizedBox(height: AppSpacing.s2),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('attachment-add'),
            onPressed: () async {
              final source = await pickAttachmentSource(
                context,
                picker.sources,
              );
              if (source == null || !context.mounted) return;
              await addAttachmentFrom(
                context,
                ref,
                source: source,
                subjectId: subjectId,
                debtId: debtId,
              );
            },
            icon: const Icon(LucideIcons.paperclip, size: 18),
            label: Text(
              debtId != null
                  ? 'Добавить фото или документ'
                  : 'Добавить документ',
            ),
          ),
        ),
      ],
    );
  }
}

/// Файл вложения: имя, размер, где лежит; нажатие открывает (картинку — в
/// приложении, документ — системным просмотрщиком), недостающий файл
/// скачивается с сервера.
class AttachmentTile extends ConsumerStatefulWidget {
  const AttachmentTile({required this.attachment, super.key});

  final Attachment attachment;

  @override
  ConsumerState<AttachmentTile> createState() => _AttachmentTileState();
}

class _AttachmentTileState extends ConsumerState<AttachmentTile> {
  bool _busy = false;

  Future<void> _open() async {
    if (_busy) return;
    final a = widget.attachment;
    setState(() => _busy = true);
    try {
      final service = ref.read(attachmentServiceProvider);
      // HEIC на Windows Flutter не декодирует: сразу системный просмотрщик.
      final inApp =
          a.isImage &&
          !(defaultTargetPlatform == TargetPlatform.windows &&
              a.mimeType.startsWith('image/he'));
      if (inApp) {
        await service.bytesOf(a);
        ref.invalidate(attachmentLocalProvider(a.id));
        if (mounted) unawaited(context.push('/study/files/${a.id}'));
      } else {
        final path = await service.pathForViewing(a);
        ref.invalidate(attachmentLocalProvider(a.id));
        final result = await ref
            .read(documentOpenerProvider)
            .open(path, a.mimeType);
        if (mounted && result != DocumentOpenResult.opened) {
          _say(
            context,
            result == DocumentOpenResult.noApp
                ? 'На устройстве нет программы для этого файла.'
                : 'Не удалось открыть файл.',
          );
        }
      }
    } on Object catch (e) {
      if (mounted) _say(context, fileErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _actions() async {
    final failed =
        ref.read(attachmentTransferProvider).failureOf(widget.attachment.id) !=
        null;
    final choice = await showEditorSheet<String>(
      context,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: widget.attachment.fileName),
          if (failed)
            ListTile(
              key: const Key('attachment-retry'),
              leading: const Icon(LucideIcons.refreshCw),
              title: const Text('Повторить загрузку'),
              onTap: () => Navigator.of(sheetContext).pop('retry'),
            ),
          ListTile(
            key: const Key('attachment-rename'),
            leading: const Icon(LucideIcons.pencil),
            title: const Text('Переименовать'),
            onTap: () => Navigator.of(sheetContext).pop('rename'),
          ),
          ListTile(
            key: const Key('attachment-delete'),
            leading: const Icon(LucideIcons.trash2),
            title: const Text('Убрать'),
            onTap: () => Navigator.of(sheetContext).pop('delete'),
          ),
          const SizedBox(height: AppSpacing.s4),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'retry':
        unawaited(
          ref
              .read(attachmentTransferProvider.notifier)
              .retry(widget.attachment.id),
        );
      case 'rename':
        await _rename();
      default:
        await _remove();
    }
  }

  Future<void> _remove() async {
    final a = widget.attachment;
    final ok = await showConfirmDialog(
      context,
      title: 'Убрать «${a.fileName}»?',
      message: 'Файл попадёт в корзину на 30 дней.',
      confirmLabel: 'Убрать',
      danger: true,
    );
    if (!ok) return;
    await ref.read(attachmentServiceProvider).remove(a.id);
  }

  Future<void> _rename() async {
    final a = widget.attachment;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: a.fileName),
    );
    if (name == null || !mounted) return;
    try {
      await ref.read(studyRepositoryProvider).renameAttachment(a.id, name);
    } on ValidationError catch (e) {
      if (mounted) _say(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final c = context.colors;
    final t = context.text;
    final local = ref.watch(attachmentLocalProvider(a.id)).value;
    final failure = ref.watch(attachmentTransferProvider).failureOf(a.id);
    final uploading = ref.watch(attachmentTransferProvider).uploading;
    final String where;
    if (failure != null) {
      where = failure;
    } else if (a.uploadStatus == UploadStatus.pending) {
      where = local == false
          ? 'Ещё не загружен на сервер'
          : (uploading ? 'Загружается…' : 'Ждёт загрузки на сервер');
    } else {
      where = local == false
          ? 'На сервере · скачается при открытии'
          : 'На устройстве и на сервере';
    }
    return ListTile(
      key: Key('attachment-${a.id}'),
      onTap: _open,
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderL),
      leading: _busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              a.isImage ? LucideIcons.image : LucideIcons.fileText,
              color: c.textSecondary,
            ),
      title: Text(a.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${formatFileSize(a.sizeBytes)} · $where',
        style: t.caption.copyWith(
          color: failure != null ? c.danger : c.textSecondary,
        ),
      ),
      trailing: IconButton(
        key: Key('attachment-menu-${a.id}'),
        tooltip: 'Действия',
        onPressed: _actions,
        icon: Icon(
          LucideIcons.ellipsisVertical,
          size: 20,
          color: c.textSecondary,
        ),
      ),
    );
  }
}

/// Диалог переименования файла: поле с именем и «Сохранить».
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Переименовать', style: context.text.h3),
    content: TextField(
      key: const Key('attachment-rename-field'),
      controller: _controller,
      autofocus: true,
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Отмена'),
      ),
      FilledButton(
        key: const Key('attachment-rename-ok'),
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Сохранить'),
      ),
    ],
  );
}
