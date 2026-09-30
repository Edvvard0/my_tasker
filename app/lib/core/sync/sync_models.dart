import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';

/// Константы протокола (spec 0).
abstract final class SyncLimits {
  static const int pushBatchMax = 500;
  static const int pullPageMax = 1000;
  static const int trashDays = 30;
}

/// Результат одной операции push (spec 3.3).
@immutable
class PushOpResult {
  const PushOpResult({
    required this.opId,
    required this.applied,
    this.code,
    this.message,
    this.serverVersion,
    this.conflicts = 0,
    this.duplicate = false,
  });

  factory PushOpResult.fromJson(Json json) => PushOpResult(
    opId: json['op_id']! as String,
    applied: json['status'] == 'applied',
    code: json['code'] as String?,
    message: json['message'] as String?,
    serverVersion: json['server_version'] as int?,
    conflicts: (json['conflicts'] as int?) ?? 0,
    duplicate: (json['duplicate'] as bool?) ?? false,
  );

  final String opId;
  final bool applied;
  final String? code;
  final String? message;
  final int? serverVersion;
  final int conflicts;
  final bool duplicate;
}

/// Ответ `POST /sync/push`.
@immutable
class PushResponse {
  const PushResponse({
    required this.results,
    required this.headVersion,
    this.serverEpoch,
  });

  factory PushResponse.fromJson(Json json) => PushResponse(
    results: [
      for (final r in json['results']! as List<Object?>)
        PushOpResult.fromJson(r! as Json),
    ],
    headVersion: (json['head_version'] as int?) ?? 0,
    serverEpoch: json['server_epoch']?.toString(),
  );

  final List<PushOpResult> results;
  final int headVersion;

  /// Идентификатор «эпохи» сервера: меняется, если сервер восстановили из
  /// резервной копии. `null` — сервер его не присылает.
  final String? serverEpoch;
}

/// Одна строка из pull (или из ответа revert).
@immutable
class SyncChange {
  const SyncChange({
    required this.table,
    required this.id,
    required this.serverVersion,
    required this.row,
  });

  factory SyncChange.fromJson(Json json) => SyncChange(
    table: json['table']! as String,
    id: json['id']! as String,
    serverVersion: json['server_version']! as int,
    row: (json['row']! as Map).cast<String, Object?>(),
  );

  final String table;
  final String id;
  final int serverVersion;
  final Json row;
}

/// Ответ `GET /sync/pull`.
@immutable
class PullPage {
  const PullPage({
    required this.changes,
    required this.nextSince,
    required this.hasMore,
    required this.headVersion,
    this.purgeWatermark = 0,
    this.serverEpoch,
  });

  factory PullPage.fromJson(Json json) => PullPage(
    changes: [
      for (final c in json['changes']! as List<Object?>)
        SyncChange.fromJson((c! as Map).cast<String, Object?>()),
    ],
    nextSince: json['next_since']! as int,
    hasMore: json['has_more']! as bool,
    headVersion: (json['head_version'] as int?) ?? 0,
    purgeWatermark: (json['purge_watermark'] as int?) ?? 0,
    serverEpoch: json['server_epoch']?.toString(),
  );

  final List<SyncChange> changes;
  final int nextSince;
  final bool hasMore;
  final int headVersion;
  final int purgeWatermark;

  /// См. [PushResponse.serverEpoch].
  final String? serverEpoch;
}

/// Вид конфликта (spec 3.9).
enum ConflictKind {
  field('field'),
  resurrected('resurrected'),
  editVsDelete('edit_vs_delete'),
  parentDeleted('parent_deleted'),
  unknown('');

  const ConflictKind(this.wire);

  final String wire;

  static ConflictKind parse(String? value) => values.firstWhere(
    (k) => k.wire == value,
    orElse: () => ConflictKind.unknown,
  );
}

/// Запись журнала конфликтов (spec 3.9).
@immutable
class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.createdAt,
    required this.table,
    required this.rowId,
    required this.field,
    required this.kind,
    required this.losingValue,
    required this.winningValue,
    this.losingDeviceId,
    this.winningDeviceId,
    this.losingHlc,
    this.winningHlc,
    this.revertedAt,
  });

  factory SyncConflict.fromJson(Json json) => SyncConflict(
    id: json['id']! as String,
    createdAt: DateTime.parse(json['created_at']! as String),
    table: json['table']! as String,
    rowId: json['row_id']! as String,
    field: json['field']! as String,
    kind: ConflictKind.parse(json['kind'] as String?),
    losingValue: json['losing_value'],
    winningValue: json['winning_value'],
    losingDeviceId: json['losing_device_id'] as String?,
    winningDeviceId: json['winning_device_id'] as String?,
    losingHlc: json['losing_hlc'] as String?,
    winningHlc: json['winning_hlc'] as String?,
    revertedAt: json['reverted_at'] == null
        ? null
        : DateTime.parse(json['reverted_at']! as String),
  );

  final String id;
  final DateTime createdAt;
  final String table;
  final String rowId;
  final String field;
  final ConflictKind kind;
  final Object? losingValue;
  final Object? winningValue;
  final String? losingDeviceId;
  final String? winningDeviceId;
  final String? losingHlc;
  final String? winningHlc;
  final DateTime? revertedAt;

  bool get isReverted => revertedAt != null;

  /// «Вернуть моё» не поддерживается для `parent_deleted` (spec 3.9).
  bool get canRevert => !isReverted && kind != ConflictKind.parentDeleted;
}

/// Страница журнала конфликтов.
@immutable
class ConflictsPage {
  const ConflictsPage({required this.conflicts, this.nextBefore});

  factory ConflictsPage.fromJson(Json json) => ConflictsPage(
    conflicts: [
      for (final c in json['conflicts']! as List<Object?>)
        SyncConflict.fromJson((c! as Map).cast<String, Object?>()),
    ],
    nextBefore: json['next_before'] as String?,
  );

  final List<SyncConflict> conflicts;
  final String? nextBefore;
}

/// Ответ `POST /sync/conflicts/{id}/revert`.
@immutable
class RevertResult {
  const RevertResult({required this.conflict, required this.change});

  factory RevertResult.fromJson(Json json) => RevertResult(
    conflict: SyncConflict.fromJson(
      (json['conflict']! as Map).cast<String, Object?>(),
    ),
    change: SyncChange.fromJson(
      (json['change']! as Map).cast<String, Object?>(),
    ),
  );

  final SyncConflict conflict;
  final SyncChange change;
}

/// Операция outbox для показа и отправки.
@immutable
class OutboxOp {
  const OutboxOp({
    required this.seq,
    required this.opId,
    required this.table,
    required this.rowId,
    required this.type,
    required this.baseVersion,
    required this.hlc,
    required this.state,
    required this.createdAtMs,
    this.fields,
    this.rejectCode,
    this.rejectMessage,
  });

  final int seq;
  final String opId;
  final String table;
  final String rowId;
  final String type;
  final Json? fields;
  final int baseVersion;
  final String hlc;
  final String state;
  final String? rejectCode;
  final String? rejectMessage;
  final int createdAtMs;

  /// Форма операции для `POST /sync/push` (spec 3.2).
  Json toWire() => {
    'op_id': opId,
    'table': table,
    'id': rowId,
    'type': type,
    if (type == OpType.upsert) 'fields': fields ?? const <String, Object?>{},
    'base_version': baseVersion,
    'hlc': hlc,
  };

  /// Форма для чистых функций `collapse`/`rebase` (с `state`).
  Json toLogic() => {...toWire(), 'state': state};
}

/// Сводка очереди для интерфейса.
@immutable
class OutboxSummary {
  const OutboxSummary({this.pending = 0, this.inFlight = 0, this.rejected = 0});

  final int pending;
  final int inFlight;
  final int rejected;

  /// Ждут отправки (в том числе с неизвестным результатом).
  int get unsent => pending + inFlight;

  @override
  bool operator ==(Object other) =>
      other is OutboxSummary &&
      other.pending == pending &&
      other.inFlight == inFlight &&
      other.rejected == rejected;

  @override
  int get hashCode => Object.hash(pending, inFlight, rejected);
}

/// Элемент корзины.
@immutable
class TrashItem {
  const TrashItem({
    required this.table,
    required this.label,
    required this.id,
    required this.title,
    required this.deletedAt,
    required this.daysLeft,
  });

  final String table;
  final String label;
  final String id;
  final String title;
  final DateTime deletedAt;

  /// Сколько полных суток осталось хранения (0 — удалится сегодня).
  final int daysLeft;
}
