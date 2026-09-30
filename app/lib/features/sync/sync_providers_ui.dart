import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';

/// Отклонённые сервером операции (`rejected`) — для экрана «Синхронизация».
final StreamProvider<List<OutboxOp>> rejectedOpsProvider =
    StreamProvider.autoDispose<List<OutboxOp>>(
      (ref) => ref.watch(syncStoreProvider).watchRejected(),
    );

/// Курсор pull; пересчитывается после каждой загрузки.
final FutureProvider<int> syncCursorProvider = FutureProvider.autoDispose<int>((
  ref,
) {
  ref.watch(syncStatusProvider.select((s) => s.run.lastPullAt));
  return ref.watch(syncStoreProvider).cursor();
});

/// Подпись записи (по локальной строке) для журнала конфликтов.
// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final rowTitleProvider = FutureProvider.autoDispose
    .family<String?, ({String table, String id})>((ref, key) async {
      final store = ref.watch(syncStoreProvider);
      final spec = store.registry.maybeSpec(key.table);
      if (spec == null) return null;
      final row = await store.getRow(key.table, key.id);
      return row == null ? null : spec.titleOf(row);
    });

/// Состояние журнала конфликтов.
class ConflictsState {
  const ConflictsState({
    this.items = const [],
    this.nextBefore,
    this.loadingMore = false,
    this.revertingId,
  });

  final List<SyncConflict> items;
  final String? nextBefore;
  final bool loadingMore;

  /// Конфликт, для которого сейчас идёт «Вернуть моё».
  final String? revertingId;

  ConflictsState copyWith({
    List<SyncConflict>? items,
    String? nextBefore,
    bool clearNext = false,
    bool? loadingMore,
    String? revertingId,
    bool clearReverting = false,
  }) => ConflictsState(
    items: items ?? this.items,
    nextBefore: clearNext ? null : (nextBefore ?? this.nextBefore),
    loadingMore: loadingMore ?? this.loadingMore,
    revertingId: clearReverting ? null : (revertingId ?? this.revertingId),
  );
}

/// Журнал конфликтов с сервера (spec 3.9): загрузка, «Показать ещё»,
/// «Вернуть моё».
class ConflictsNotifier extends AsyncNotifier<ConflictsState> {
  static const pageSize = 50;

  @override
  Future<ConflictsState> build() async {
    final page = await ref.read(syncRemoteProvider).conflicts();
    return ConflictsState(items: page.conflicts, nextBefore: page.nextBefore);
  }

  /// Следующая страница (старые конфликты). Ошибки — [ApiException].
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.nextBefore == null || current.loadingMore) {
      return;
    }
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await ref
          .read(syncRemoteProvider)
          .conflicts(before: current.nextBefore);
      state = AsyncData(
        current.copyWith(
          items: [...current.items, ...page.conflicts],
          nextBefore: page.nextBefore,
          clearNext: page.nextBefore == null,
          loadingMore: false,
        ),
      );
    } on ApiException {
      state = AsyncData(current.copyWith(loadingMore: false));
      rethrow;
    }
  }

  /// «Вернуть моё»: сервер применяет проигравшее значение новой операцией;
  /// полученная строка применяется локально как строка из pull. Ошибки —
  /// [ApiException] (`conflict_already_reverted`, `row_not_found`,
  /// `not_revertable`, `revert_rejected`).
  Future<void> revert(SyncConflict conflict) async {
    final current = state.value;
    if (current == null || current.revertingId != null) return;
    state = AsyncData(current.copyWith(revertingId: conflict.id));
    try {
      final result = await ref.read(syncRemoteProvider).revert(conflict.id);
      await ref.read(syncStoreProvider).applyChange(result.change);
      final latest = state.value ?? current;
      state = AsyncData(
        latest.copyWith(
          items: [
            for (final c in latest.items)
              if (c.id == conflict.id) result.conflict else c,
          ],
          clearReverting: true,
        ),
      );
      // Остальные устройства узнают об изменении через обычный цикл.
      await ref.read(syncCoordinatorProvider).syncNow();
    } on ApiException {
      state = AsyncData(
        (state.value ?? current).copyWith(clearReverting: true),
      );
      rethrow;
    }
  }
}

final AsyncNotifierProvider<ConflictsNotifier, ConflictsState>
conflictsProvider =
    AsyncNotifierProvider.autoDispose<ConflictsNotifier, ConflictsState>(
      ConflictsNotifier.new,
      retry: (_, _) => null,
    );
