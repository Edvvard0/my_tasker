/// Дебиторка Работы (spec Этапа 4, 4.4) в объёме, нужном формуле «Есть» цели
/// (spec Этапа 5, 6.2): кто сколько должен по проектам. Порт
/// `receivables` из `backend/src/tasker/work/reference.py`; пока в клиенте
/// нет модуля «Работа», функция живёт здесь (при появлении — перенести).
library;

/// Проекты с этими статусами создают долг; лиды и отменённые — нет.
const Set<String> _debtStatuses = {'active', 'paused', 'completed'};

int _int(Object? value) => (value as num?)?.toInt() ?? 0;

String _status(Map<String, Object?> project) =>
    (project['status'] as String?) ?? 'active';

/// База проекта плюс не отменённые доп. работы.
int _projectTotal(
  Map<String, Object?> project,
  List<Map<String, Object?>> changeRequests,
) {
  var extra = 0;
  for (final cr in changeRequests) {
    if (cr['project_id'] == project['id'] && cr['status'] != 'cancelled') {
      extra += _int(cr['amount']);
    }
  }
  return _int(project['base_amount']) + extra;
}

/// Кто должен: по заказчикам, по проектам `active`/`paused`/`completed`.
/// Проект должен `max(0, итого - получено)`; заказчики без долга опущены,
/// `client_id` может быть `null`. Порядок — часть результата.
Map<String, Object?> workReceivables(
  List<Map<String, Object?>> projects,
  List<Map<String, Object?>> changeRequests,
  List<Map<String, Object?>> allocations,
) {
  final groups = <String?, List<Map<String, Object?>>>{};
  for (final project in projects) {
    if (!_debtStatuses.contains(_status(project))) continue;
    var received = 0;
    for (final a in allocations) {
      if (a['project_id'] == project['id']) received += _int(a['amount']);
    }
    final debt = _projectTotal(project, changeRequests) - received;
    if (debt > 0) {
      groups.putIfAbsent(project['client_id'] as String?, () => []).add({
        'id': project['id'],
        'remaining': debt,
      });
    }
  }
  final clients = <Map<String, Object?>>[];
  for (final entry in groups.entries) {
    final rows = entry.value
      ..sort((a, b) {
        final byDebt = (b['remaining']! as int).compareTo(
          a['remaining']! as int,
        );
        return byDebt != 0
            ? byDebt
            : (a['id']! as String).compareTo(b['id']! as String);
      });
    clients.add({
      'client_id': entry.key,
      'remaining': rows.fold<int>(0, (s, r) => s + (r['remaining']! as int)),
      'projects': rows,
    });
  }
  clients.sort((a, b) {
    final byDebt = (b['remaining']! as int).compareTo(a['remaining']! as int);
    if (byDebt != 0) return byDebt;
    final ca = a['client_id'] as String?;
    final cb = b['client_id'] as String?;
    if ((ca == null) != (cb == null)) return ca == null ? 1 : -1;
    return (ca ?? '').compareTo(cb ?? '');
  });
  return {
    'total': clients.fold<int>(0, (s, c) => s + (c['remaining']! as int)),
    'clients': clients,
  };
}
