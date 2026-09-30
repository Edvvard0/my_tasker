import 'package:my_tasker/core/sync/hlc.dart';

/// Запись сервера о поле: версия и HLC последнего изменения (spec 3.1).
class FieldEntry {
  const FieldEntry(this.v, this.h);

  factory FieldEntry.fromJson(Map<String, Object?> json) =>
      FieldEntry(json['v']! as int, json['h']! as String);

  final int v;
  final String h;
}

/// Поле конкурентно: изменено после базы клиента **другим** устройством.
bool isConcurrent(FieldEntry? entry, int baseVersion, String device) =>
    entry != null && entry.v > baseVersion && hlcDevice(entry.h) != device;

/// Одно поле `upsert`: `noop | touch | apply | apply_conflict |
/// keep_conflict` (spec 3.4). Порт `tasker.sync.merge.field_decision`.
/// `touch`: значение уже такое, но запись новее — метка поля обновляется.
String fieldDecision({
  required bool sameValue,
  required FieldEntry? entry,
  required String opHlc,
  required int baseVersion,
}) {
  if (sameValue) {
    return entry == null || opHlc.compareTo(entry.h) > 0 ? 'touch' : 'noop';
  }
  if (!isConcurrent(entry, baseVersion, hlcDevice(opHlc))) return 'apply';
  return opHlc.compareTo(entry!.h) > 0 ? 'apply_conflict' : 'keep_conflict';
}

/// Операция `delete`: `noop | delete | delete_edit_conflict | delete_lost`.
String deleteDecision({
  required bool alreadyDeleted,
  required Map<String, FieldEntry> fieldEntries,
  required String opHlc,
  required int baseVersion,
}) {
  if (alreadyDeleted) return 'noop';
  final device = hlcDevice(opHlc);
  final concurrent = [
    for (final e in fieldEntries.entries)
      if (e.key != 'deleted_at' && isConcurrent(e.value, baseVersion, device))
        e.value,
  ];
  if (concurrent.isEmpty) return 'delete';
  if (concurrent.any((e) => e.h.compareTo(opHlc) > 0)) return 'delete_lost';
  return 'delete_edit_conflict';
}

/// Правка или восстановление строки в корзине:
/// `restore | stay_deleted | resurrect_conflict | stay_deleted_conflict`.
String tombstoneEditDecision({
  required FieldEntry entryDeleted,
  required String opHlc,
  required int baseVersion,
  required bool restore,
}) {
  if (!isConcurrent(entryDeleted, baseVersion, hlcDevice(opHlc))) {
    return restore ? 'restore' : 'stay_deleted';
  }
  return opHlc.compareTo(entryDeleted.h) > 0
      ? 'resurrect_conflict'
      : 'stay_deleted_conflict';
}
