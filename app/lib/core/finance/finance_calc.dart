/// Расчёты Финансов (spec Этапа 5, разделы 4–8): чистые функции над
/// «JSON-строками» таблиц (имена колонок как в spec 1; `id` — строчные
/// строки uuid; моменты `YYYY-MM-DDTHH:MM:SSZ`, даты `YYYY-MM-DD`).
///
/// Побайтно те же результаты, что у `backend/src/tasker/finance/reference.py`
/// (проверяется общими векторами `shared-test-vectors/finance/`). Деньги —
/// только целые копейки и никогда не округляются; деление одно
/// ([progressBasisPoints], вниз). Клиент передаёт **видимые** строки
/// (spec 2): живые и с живыми родителями.
library;

import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/finance/finance_time.dart';
import 'package:my_tasker/core/finance/work_receivables.dart';

/// Строка таблицы в виде JSON-объекта.
typedef Row = Map<String, Object?>;

/// Список строк.
typedef Rows = List<Row>;

final RegExp _spaces = RegExp('[ \t\n\r ]+');

int _int(Object? value) => (value! as num).toInt();

// ---------------------------------------------------------------- text

/// Ключ мерчанта: пробельные символы схлопнуты и обрезаны, заглавные ASCII и
/// кириллица понижены (остальное не трогается: `toLowerCase` в разных
/// средах расходится).
String foldMerchant(String text) =>
    foldTagName(text.replaceAll(_spaces, ' ').trim());

String _cleanMerchant(Object? merchant) =>
    ((merchant as String?) ?? '').replaceAll(_spaces, ' ').trim();

/// Ключ уникальности операции банка (spec 7.2) или `null`.
String? dedupKey(Row tx) {
  if (tx['external_id'] != null) {
    return 'ext|${tx['account_id']}|${tx['external_id']}';
  }
  if (tx['dedup_hash'] != null) {
    return 'hash|${tx['account_id']}|${tx['dedup_hash']}';
  }
  return null;
}

/// Доля цели в сотых долях процента, вниз; `0` при `have <= 0`.
int progressBasisPoints(int have, int target) =>
    target <= 0 || have <= 0 ? 0 : have * 10000 ~/ target;

// ---------------------------------------------------------------- balances

bool _confirmed(Row tx) => tx['status'] == 'confirmed';

/// Что подтверждённая операция делает с балансом счёта [accountId]
/// (копейки со знаком); неподтверждённая — `0`.
int effect(Row tx, String accountId) {
  if (!_confirmed(tx)) return 0;
  final amount = _int(tx['amount']);
  switch (tx['kind']) {
    case 'income':
      return tx['account_id'] == accountId ? amount : 0;
    case 'expense':
      return tx['account_id'] == accountId ? -amount : 0;
    default:
      var total =
          0; // перевод: списание с account_id, зачисление на to_account_id
      if (tx['account_id'] == accountId) total -= amount;
      if (tx['to_account_id'] == accountId) total += amount;
      return total;
  }
}

int _compareKeys((int, String) a, (int, String) b) {
  final c = a.$1.compareTo(b.$1);
  return c != 0 ? c : a.$2.compareTo(b.$2);
}

(int, String) _checkpointKey(Row cp) =>
    (instantSeconds(cp['checked_at']! as String), cp['id']! as String);

/// Баланс счёта на момент [at] (`null` = сейчас, все данные), spec 4.2.
///
/// Опорная точка — позднейшая из открытия (начало московских суток
/// `opening_date`) и точек сверки счёта до [at]; при равных моментах точка
/// сверки сильнее открытия, среди точек — большая пара `(checked_at, id)`.
/// Баланс = опорная сумма + эффекты подтверждённых операций после точки
/// (после точки сверки — строго, от открытия — включительно) по [at]
/// включительно. До открытия баланс `0`.
int balanceAt(Row account, Rows transactions, Rows checkpoints, {String? at}) {
  final limit = at == null ? null : instantSeconds(at);
  final opened = openingSeconds(account['opening_date']! as String);
  if (limit != null && limit < opened) return 0;
  Row? best;
  (int, String)? bestKey;
  for (final cp in checkpoints) {
    if (cp['account_id'] != account['id']) continue;
    final key = _checkpointKey(cp);
    if (limit != null && key.$1 > limit) continue;
    if (bestKey == null || _compareKeys(key, bestKey) > 0) {
      best = cp;
      bestKey = key;
    }
  }
  var start = opened;
  var amount = _int(account['opening_balance']);
  var strict = false;
  if (best != null && bestKey!.$1 >= opened) {
    start = bestKey.$1;
    amount = _int(best['actual_balance']);
    strict = true;
  }
  final id = account['id']! as String;
  var balance = amount;
  for (final tx in transactions) {
    final when = instantSeconds(tx['occurred_at']! as String);
    if ((strict ? when <= start : when < start) ||
        (limit != null && when > limit)) {
      continue;
    }
    balance += effect(tx, id);
  }
  return balance;
}

/// Баланс по счетам (в порядке входа) и `total` по счетам с
/// `include_in_total` (архив на общий баланс не влияет).
Row accountBalances(
  Rows accounts,
  Rows transactions,
  Rows checkpoints, {
  String? at,
}) {
  final lines = <Row>[
    for (final a in accounts)
      {
        'id': a['id'],
        'balance': balanceAt(a, transactions, checkpoints, at: at),
        'in_total': a['include_in_total'] == true,
      },
  ];
  var total = 0;
  for (final line in lines) {
    if (line['in_total']! as bool) total += line['balance']! as int;
  }
  return {'accounts': lines, 'total': total};
}

/// Общий баланс на конец каждой переданной московской даты (порядок входа).
List<Row> balanceDynamics(
  Rows accounts,
  Rows transactions,
  Rows checkpoints,
  List<String> dates,
) => [
  for (final day in dates)
    {
      'date': day,
      'total': accountBalances(
        accounts,
        transactions,
        checkpoints,
        at: endOfDay(day),
      )['total'],
    },
];

/// Для каждой точки сверки (по возрастанию `(checked_at, id)`): что ожидали
/// по учёту и расхождение; точки раньше открытия не показываются (spec 4.4).
List<Row> adjustments(Row account, Rows transactions, Rows checkpoints) {
  final opened = openingSeconds(account['opening_date']! as String);
  final mine = [
    for (final cp in checkpoints)
      if (cp['account_id'] == account['id']) cp,
  ]..sort((a, b) => _compareKeys(_checkpointKey(a), _checkpointKey(b)));
  final out = <Row>[];
  for (var index = 0; index < mine.length; index++) {
    final cp = mine[index];
    if (instantSeconds(cp['checked_at']! as String) < opened) continue;
    final expected = balanceAt(
      account,
      transactions,
      mine.sublist(0, index),
      at: cp['checked_at']! as String,
    );
    final actual = _int(cp['actual_balance']);
    out.add({
      'checkpoint_id': cp['id'],
      'checked_at': cp['checked_at'],
      'actual': actual,
      'expected': expected,
      'adjustment': actual - expected,
    });
  }
  return out;
}

// ---------------------------------------------------------------- analytics

/// Подтверждённый доход/расход без `debt_id` (не перевод, не движение долга).
bool countsInAnalytics(Row tx) =>
    _confirmed(tx) &&
    (tx['kind'] == 'income' || tx['kind'] == 'expense') &&
    tx['debt_id'] == null;

/// Доход и расход по московским месяцам (`YYYY-MM`, по возрастанию, только
/// месяцы с операциями). [accountIds] — фильтр по `account_id`, [period] —
/// `{from, to}` московских дат включительно.
List<Row> monthlyTotals(
  Rows transactions, {
  List<String>? accountIds,
  Row? period,
}) {
  final sums = <String, ({int income, int expense})>{};
  for (final tx in transactions) {
    if (!countsInAnalytics(tx)) continue;
    if (accountIds != null && !accountIds.contains(tx['account_id'])) continue;
    final day = moscowDate(tx['occurred_at']! as String);
    if (!inPeriod(day, period)) continue;
    final month = day.substring(0, 7);
    final now = sums[month] ?? (income: 0, expense: 0);
    final amount = _int(tx['amount']);
    sums[month] = tx['kind'] == 'income'
        ? (income: now.income + amount, expense: now.expense)
        : (income: now.income, expense: now.expense + amount);
  }
  final months = sums.keys.toList()..sort();
  return [
    for (final m in months)
      {
        'month': m,
        'income': sums[m]!.income,
        'expense': sums[m]!.expense,
        'net': sums[m]!.income - sums[m]!.expense,
      },
  ];
}

/// Суммы вида [kind] по категориям верхнего уровня с подкатегориями
/// (spec 5.2). [categories] — живые категории. Отсутствующая, удалённая или
/// пустая категория — группа `category_id = null`.
Row categoryBreakdown(
  Rows transactions,
  Rows categories,
  String kind, {
  Row? period,
}) {
  final parentOf = <String, String?>{
    for (final c in categories) c['id']! as String: c['parent_id'] as String?,
  };
  final groups = <String?, Row>{};
  final children = <String?, Map<String, ({int total, int count})>>{};
  var grand = 0;
  for (final tx in transactions) {
    if (!countsInAnalytics(tx) || tx['kind'] != kind) continue;
    if (!inPeriod(moscowDate(tx['occurred_at']! as String), period)) continue;
    final amount = _int(tx['amount']);
    var cid = tx['category_id'] as String?;
    if (cid != null && !parentOf.containsKey(cid)) cid = null;
    final parent = cid == null ? null : parentOf[cid];
    final top = parent != null && parentOf.containsKey(parent) ? parent : cid;
    final group = groups.putIfAbsent(
      top,
      () => {'category_id': top, 'total': 0, 'own': 0, 'count': 0},
    );
    group['total'] = (group['total']! as int) + amount;
    group['count'] = (group['count']! as int) + 1;
    grand += amount;
    if (top == cid) {
      group['own'] = (group['own']! as int) + amount;
    } else {
      final kids = children.putIfAbsent(top, () => {});
      final row = kids[cid] ?? (total: 0, count: 0);
      kids[cid!] = (total: row.total + amount, count: row.count + 1);
    }
  }
  final ordered = groups.values.toList()
    ..sort((a, b) {
      final byTotal = (b['total']! as int).compareTo(a['total']! as int);
      if (byTotal != 0) return byTotal;
      final ida = a['category_id'] as String?;
      final idb = b['category_id'] as String?;
      if ((ida == null) != (idb == null)) return ida == null ? 1 : -1;
      return (ida ?? '').compareTo(idb ?? '');
    });
  for (final group in ordered) {
    final kids = children[group['category_id']] ?? {};
    final ids = kids.keys.toList()
      ..sort((a, b) {
        final byTotal = kids[b]!.total.compareTo(kids[a]!.total);
        return byTotal != 0 ? byTotal : a.compareTo(b);
      });
    group['children'] = [
      for (final id in ids)
        {'category_id': id, 'total': kids[id]!.total, 'count': kids[id]!.count},
    ];
  }
  return {'total': grand, 'groups': ordered};
}

/// Мерчанты по сумме (ключ — [foldMerchant]; показывается написание самой
/// ранней операции по `(occurred_at, id)`); пустые мерчанты пропускаются.
List<Row> topMerchants(
  Rows transactions, {
  String kind = 'expense',
  Row? period,
  int limit = 10,
}) {
  final found = <String, ({String merchant, int total, int count})>{};
  final ordered =
      [
        for (final tx in transactions)
          if (countsInAnalytics(tx) && tx['kind'] == kind) tx,
      ]..sort(
        (a, b) => _compareKeys(
          (instantSeconds(a['occurred_at']! as String), a['id']! as String),
          (instantSeconds(b['occurred_at']! as String), b['id']! as String),
        ),
      );
  for (final tx in ordered) {
    final name = _cleanMerchant(tx['merchant']);
    if (name.isEmpty ||
        !inPeriod(moscowDate(tx['occurred_at']! as String), period)) {
      continue;
    }
    final key = foldMerchant(name);
    final row = found[key] ?? (merchant: name, total: 0, count: 0);
    found[key] = (
      merchant: row.merchant,
      total: row.total + _int(tx['amount']),
      count: row.count + 1,
    );
  }
  final keys = found.keys.toList()
    ..sort((a, b) {
      final x = found[a]!;
      final y = found[b]!;
      final byTotal = y.total.compareTo(x.total);
      if (byTotal != 0) return byTotal;
      final byCount = y.count.compareTo(x.count);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return [
    for (final key in keys.take(limit))
      {
        'merchant': found[key]!.merchant,
        'total': found[key]!.total,
        'count': found[key]!.count,
      },
  ];
}

// ---------------------------------------------------------------- debts

/// Погашено и остаток, статус (`open`/`partial`/`closed`) и просрочка
/// (spec 6.1). [today] — московская дата; в день срока долг ещё не просрочен.
Row debtState(Row debt, Rows repayments, {String? today}) {
  var repaid = 0;
  for (final r in repayments) {
    if (r['debt_id'] == debt['id']) repaid += _int(r['amount']);
  }
  final amount = _int(debt['amount']);
  final status = repaid >= amount
      ? 'closed'
      : repaid > 0
      ? 'partial'
      : 'open';
  final due = debt['due_date'] as String?;
  return {
    'id': debt['id'],
    'direction': debt['direction'],
    'amount': amount,
    'repaid': repaid,
    'remaining': amount > repaid ? amount - repaid : 0,
    'overpaid': repaid > amount ? repaid - amount : 0,
    'status': status,
    'overdue':
        today != null &&
        today.isNotEmpty &&
        due != null &&
        due.isNotEmpty &&
        status != 'closed' &&
        due.compareTo(today) < 0,
  };
}

/// Состояния всех долгов (порядок входа) и открытые остатки по направлениям.
Row debtsSummary(Rows debts, Rows repayments, {String? today}) {
  final states = [
    for (final d in debts) debtState(d, repayments, today: today),
  ];
  var owedToMe = 0;
  var iOwe = 0;
  for (final s in states) {
    if (s['direction'] == 'owed_to_me') owedToMe += s['remaining']! as int;
    if (s['direction'] == 'i_owe') iOwe += s['remaining']! as int;
  }
  return {'owed_to_me': owedToMe, 'i_owe': iOwe, 'debts': states};
}

// ---------------------------------------------------------------- goals

/// Формула «Есть» цели (spec 6.2). Слагаемые: `accounts` (балансы
/// перечисленных счетов, каждый id один раз, удалённый — 0), `all_accounts`
/// (общий баланс), `debts_to_me`, `my_debts`, `receivables` (дебиторка
/// Работы; `client_ids == null` — вся). `missing = target - have` со знаком.
Row goalProgress(
  Row goal,
  Rows accounts,
  Rows transactions,
  Rows checkpoints,
  Rows debts,
  Rows repayments,
  Rows projects,
  Rows changeRequests,
  Rows allocations,
) {
  final balances = <String, int>{
    for (final a in accounts)
      a['id']! as String: balanceAt(a, transactions, checkpoints),
  };
  var inTotal = 0;
  for (final a in accounts) {
    if (a['include_in_total'] == true) inTotal += balances[a['id']]!;
  }
  final summary = debtsSummary(debts, repayments);
  final owed = workReceivables(projects, changeRequests, allocations);
  final lines = <Row>[];
  for (final term in (goal['formula']! as List<Object?>).cast<Row>()) {
    final kind = term['kind']! as String;
    final int value;
    switch (kind) {
      case 'accounts':
        value = [
          for (final id in (term['account_ids']! as List<Object?>).toSet())
            balances[id] ?? 0,
        ].fold(0, (a, b) => a + b);
      case 'all_accounts':
        value = inTotal;
      case 'debts_to_me':
        value = summary['owed_to_me']! as int;
      case 'my_debts':
        value = summary['i_owe']! as int;
      default:
        final chosen = term['client_ids'] as List<Object?>?;
        value = chosen == null
            ? owed['total']! as int
            : [
                for (final c in (owed['clients']! as List<Object?>).cast<Row>())
                  if (chosen.contains(c['client_id'])) c['remaining']! as int,
              ].fold(0, (a, b) => a + b);
    }
    lines.add({'kind': kind, 'value': term['sign'] == '+' ? value : -value});
  }
  final have = lines.fold<int>(0, (a, l) => a + (l['value']! as int));
  final target = _int(goal['target_amount']);
  final missing = target - have;
  return {
    'have': have,
    'target': target,
    'missing': missing,
    'reached': missing <= 0,
    'surplus': missing < 0 ? -missing : 0,
    'progress_bp': progressBasisPoints(have, target),
    'terms': lines,
  };
}

// ---------------------------------------------------------------- Work links

/// Какая часть платежа Работы уже отражена подтверждённым доходом на счёте
/// (spec 7.1): `unlinked = amount - linked` со знаком (порядок входа).
List<Row> workPaymentCoverage(Rows payments, Rows transactions) {
  final linked = <String, int>{};
  for (final tx in transactions) {
    final link = tx['work_payment_id'];
    if (_confirmed(tx) && tx['kind'] == 'income' && link != null) {
      linked[link as String] = (linked[link] ?? 0) + _int(tx['amount']);
    }
  }
  return [
    for (final p in payments)
      {
        'payment_id': p['id'],
        'amount': _int(p['amount']),
        'linked': linked[p['id']] ?? 0,
        'unlinked': _int(p['amount']) - (linked[p['id']] ?? 0),
      },
  ];
}

// ---------------------------------------------------------------- integrity

/// Предупреждения о том, чего сервер не отклоняет построчно (spec 8);
/// порядок — по `code`, затем `id`.
List<Row> integrityProblems(
  Rows categories,
  Rows transactions,
  Rows debts,
  Rows repayments,
  Rows payments,
) {
  final found = <Row>[];
  Row problem(String code, Object? id, [int? excess]) => {
    'code': code,
    'id': id,
    'excess': excess,
  };
  final byId = <String, Row>{for (final c in categories) c['id']! as String: c};
  for (final c in categories) {
    final parentId = c['parent_id'] as String?;
    final parent = parentId == null ? null : byId[parentId];
    if (parent == null) continue;
    final grand = parent['parent_id'] as String?;
    if ((grand != null && byId.containsKey(grand)) ||
        parent['kind'] != c['kind']) {
      found.add(problem('category_parent_invalid', c['id']));
    }
  }
  (int, String) rank(Row tx) =>
      (instantSeconds(tx['occurred_at']! as String), tx['id']! as String);
  final first = <String, (int, String)>{};
  for (final tx in transactions) {
    final key = dedupKey(tx);
    if (key == null) continue;
    final mine = rank(tx);
    final known = first[key];
    first[key] = known == null || _compareKeys(mine, known) < 0 ? mine : known;
  }
  for (final tx in transactions) {
    final key = dedupKey(tx);
    if (key != null && _compareKeys(first[key]!, rank(tx)) != 0) {
      found.add(problem('duplicate_external_id', tx['id']));
    }
    final categoryId = tx['category_id'] as String?;
    final category = categoryId == null ? null : byId[categoryId];
    if (category != null && tx['kind'] != category['kind']) {
      found.add(problem('category_kind_mismatch', tx['id']));
    }
  }
  final debtOf = <String, Object?>{
    for (final tx in transactions) tx['id']! as String: tx['debt_id'],
  };
  for (final r in repayments) {
    final link = r['transaction_id'] as String?;
    if (link != null &&
        debtOf.containsKey(link) &&
        debtOf[link] != r['debt_id']) {
      found.add(problem('repayment_transaction_mismatch', r['id']));
    }
  }
  for (final d in debts) {
    final over = debtState(d, repayments)['overpaid']! as int;
    if (over != 0) found.add(problem('over_repaid', d['id'], over));
  }
  for (final line in workPaymentCoverage(payments, transactions)) {
    final unlinked = line['unlinked']! as int;
    if (unlinked < 0) {
      found.add(
        problem('work_payment_over_linked', line['payment_id'], -unlinked),
      );
    }
  }
  found.sort((a, b) {
    final byCode = (a['code']! as String).compareTo(b['code']! as String);
    return byCode != 0
        ? byCode
        : (a['id']! as String).compareTo(b['id']! as String);
  });
  return found;
}
