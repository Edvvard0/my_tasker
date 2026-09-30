import 'dart:convert';

import 'package:my_tasker/core/sync/hlc.dart';

/// JSON-объект (операция outbox, строка таблицы).
typedef Json = Map<String, Object?>;

/// Состояния операции outbox (spec 5.1).
abstract final class OpState {
  /// Ещё ни разу не отправлялась.
  static const pending = 'pending';

  /// Отправлена хотя бы раз, подтверждения нет; результат неизвестен.
  static const inFlight = 'in_flight';

  /// Сервер отклонил.
  static const rejected = 'rejected';
}

/// Типы операций.
abstract final class OpType {
  static const upsert = 'upsert';
  static const delete = 'delete';
}

/// Глубокая копия JSON-значения.
T deepCopy<T extends Object?>(T value) => jsonDecode(jsonEncode(value)) as T;

/// `YYYY-MM-DDTHH:MM:SS.mmmZ` для миллисекунд Unix (spec 5.2, rebase).
String msIso(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

/// Состояние операции; отсутствие ключа = `pending`.
String opState(Json op) => (op['state'] as String?) ?? OpState.pending;

/// Добавляет [newOp] в outbox, схлопывая с последней операцией той же
/// строки, если она ещё `pending` (spec 5.1, `outbox.json`).
///
/// 1. `upsert` + `upsert` -> один `upsert`: поля объединены, `hlc` поздний,
///    `base_version` и `op_id` ранние.
/// 2. `upsert` (правка, `base_version > 0`) + `delete` -> один `delete`.
/// 3. Всё остальное (создание + удаление, `in_flight`, `rejected`,
///    предыдущий `delete`) — отдельная операция в конце.
///
/// Исходный список не меняется.
List<Json> collapseOutbox(List<Json> outbox, Json newOp) {
  final result = [for (final op in outbox) deepCopy(op)];
  final add = deepCopy(newOp);
  var last = -1;
  for (var i = result.length - 1; i >= 0; i--) {
    if (result[i]['table'] == add['table'] && result[i]['id'] == add['id']) {
      last = i;
      break;
    }
  }
  if (last == -1 || opState(result[last]) != OpState.pending) {
    return [...result, add];
  }
  final prev = result[last];
  if (prev['type'] == OpType.upsert && add['type'] == OpType.upsert) {
    prev
      ..['fields'] = <String, Object?>{
        ...(prev['fields']! as Map<String, Object?>),
        ...(add['fields']! as Map<String, Object?>),
      }
      ..['hlc'] = add['hlc'];
    return result;
  }
  if (prev['type'] == OpType.upsert &&
      add['type'] == OpType.delete &&
      (prev['base_version']! as int) > 0) {
    result[last] = <String, Object?>{
      for (final e in prev.entries)
        if (e.key != 'fields') e.key: e.value,
      'type': OpType.delete,
      'hlc': add['hlc'],
    };
    return result;
  }
  return [...result, add];
}

/// Накладывает не отклонённые операции по порядку на строку (rebase).
Json applyOpsToRow(Json row, List<Json> ops) {
  final merged = deepCopy(row);
  for (final op in ops) {
    if (opState(op) == OpState.rejected) continue;
    if (op['type'] == OpType.upsert) {
      merged.addAll(deepCopy(op['fields']! as Map<String, Object?>));
    } else {
      merged['deleted_at'] = msIso(hlcMs(op['hlc']! as String));
    }
    final current = merged['updated_at'] as String?;
    final hlc = op['hlc']! as String;
    if (current == null || hlc.compareTo(current) > 0) {
      merged['updated_at'] = hlc;
    }
  }
  return merged;
}

/// Серверная строка + неподтверждённые операции этой строки поверх неё.
Json rebaseRow(Json serverRow, List<Json> outbox) {
  final same = [
    for (final op in outbox)
      if (op['id'] == serverRow['id']) op,
  ];
  return applyOpsToRow(serverRow, same);
}
