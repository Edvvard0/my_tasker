import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;
import 'package:my_tasker/features/calendar/domain/calendar_models.dart'
    show parseStoredInstant, storedInstant;

/// Строка задачи для расчётов «Сна» (связь с задачами, перенос из чек-ина):
/// только нужные колонки; момент приводится к строгой форме
/// `YYYY-MM-DDTHH:MM:SSZ`, неизвестная зона — к `UTC` (расчёт не должен
/// падать на старых или чужих данных).
Json taskLinkRow(Json row) {
  final at = parseStoredInstant(row['due_at']);
  final tz = row['due_tz'] as String?;
  return {
    'id': row['id'],
    'status': row['status'],
    'due_date': row['due_date'],
    'due_at': storedInstant(at),
    'due_tz': at == null ? null : (findLocation(tz ?? '') == null ? 'UTC' : tz),
    'rrule': row['rrule'],
  };
}
