import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/study/data/attachment_service.dart';
import 'package:my_tasker/features/study/data/attachment_store.dart';
import 'package:my_tasker/features/study/data/files_api.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/platform/attachment_directory.dart';

/// Локальное хранилище файлов вложений. Тесты подставляют своё.
final Provider<AttachmentFileStore> attachmentStoreProvider =
    Provider<AttachmentFileStore>(
      (ref) => DirectoryAttachmentStore(attachmentRoot),
    );

final Provider<AttachmentService> attachmentServiceProvider =
    Provider<AttachmentService>(
      (ref) => AttachmentService(
        repository: ref.watch(studyRepositoryProvider),
        files: ref.watch(attachmentStoreProvider),
        api: ref.watch(filesApiProvider),
        syncNow: () async {
          await ref.read(syncCoordinatorProvider).syncNow();
        },
      ),
    );

/// Состояние фоновой загрузки вложений.
@immutable
class TransferState {
  const TransferState({this.uploading = false, this.failed = const {}});

  /// Идёт загрузка.
  final bool uploading;

  /// Окончательные отказы сервера: `id вложения -> код ошибки`.
  final Map<String, String> failed;

  /// Понятный текст отказа для вложения [id] или `null`.
  String? failureOf(String id) {
    final code = failed[id];
    if (code == null) return null;
    return fileErrorText(
      ApiException(kind: ApiErrorKind.http, code: code, status: 422),
    );
  }
}

/// Запускает фоновую загрузку вложений и помнит окончательные отказы.
class AttachmentTransferNotifier extends Notifier<TransferState> {
  @override
  TransferState build() => const TransferState();

  /// Загружает вложения со статусом `pending`, файлы которых есть на
  /// устройстве. Безопасно вызывать часто: параллельные запуски
  /// объединяются, повтор идемпотентен.
  Future<UploadReport> kick() async {
    final service = ref.read(attachmentServiceProvider);
    state = TransferState(uploading: true, failed: state.failed);
    try {
      final report = await service.uploadPending();
      if (!ref.mounted) return report;
      final failed = {...state.failed, ...report.failed}
        ..removeWhere((id, _) => report.uploaded.contains(id));
      state = TransferState(failed: failed);
      return report;
    } on Object {
      if (ref.mounted) state = TransferState(failed: state.failed);
      return const UploadReport();
    }
  }
}

final NotifierProvider<AttachmentTransferNotifier, TransferState>
attachmentTransferProvider =
    NotifierProvider<AttachmentTransferNotifier, TransferState>(
      AttachmentTransferNotifier.new,
    );

/// Следит, чтобы файлы доезжали до сервера: при старте и после каждого
/// успешного обмена синхронизацией (метаданные уже на сервере). Следит
/// корень приложения; виджет-тесты отключают вместе с синхронизацией.
final Provider<void> attachmentLifecycleProvider = Provider<void>((ref) {
  if (!ref.watch(syncAutostartProvider)) return;
  final notifier = ref.read(attachmentTransferProvider.notifier);
  ref.listen(syncStatusProvider.select((s) => s.run.lastSuccessAt), (
    previous,
    next,
  ) {
    if (next != null && next != previous) unawaited(notifier.kick());
  }, fireImmediately: true);
});

/// Файл вложения есть на устройстве (иначе его можно скачать).
final FutureProviderFamily<bool, String> attachmentLocalProvider =
    FutureProvider.autoDispose.family<bool, String>(
      (ref, id) => ref.watch(attachmentStoreProvider).exists(id),
    );
