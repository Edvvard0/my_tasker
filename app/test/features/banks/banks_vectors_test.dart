import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/banks/domain/notification_engine.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart'
    show parseFinanceInstant;

import '../../support/banks_data.dart';
import '../../support/vectors.dart';

typedef _Json = Map<String, Object?>;

List<_Json> _list(Object? v) => [
  for (final r in (v as List<Object?>? ?? const [])) (r! as Map).cast(),
];

StatementCandidate _candidate(_Json c) => StatementCandidate(
  kind: c['kind']! as String,
  amount: c['amount']! as int,
  currency: (c['currency'] as String?) ?? 'RUB',
  occurredAt: parseFinanceInstant(c['occurred_at']),
  dateOnly: c['date_only'] == true,
  merchant: c['merchant'] as String?,
  externalId: c['external_id'] as String?,
);

ExistingOperation _existing(_Json e) => ExistingOperation(
  id: e['id']! as String,
  accountId: e['account_id']! as String,
  kind: e['kind']! as String,
  amount: e['amount']! as int,
  occurredAt: parseFinanceInstant(e['occurred_at']),
  merchant: e['merchant'] as String?,
  source: e['source'] as String?,
  externalId: e['external_id'] as String?,
  dedupHash: e['dedup_hash'] as String?,
);

/// Общие векторы Банков (`shared-test-vectors/banks/`): Dart обязан пройти
/// каждый случай каждого файла; ожидаемое — эталон Python.
void main() {
  final data = loadBankDataSync();

  test('каталог векторов: все файлы домена и не меньше 174 случаев', () {
    expect(vectorFiles('banks'), [
      'category_suggest.json',
      'dedup_hash.json',
      'matching.json',
      'merchants.json',
      'notification_parse.json',
      'similarity.json',
      'transfers.json',
    ]);
    var total = 0;
    for (final f in vectorFiles('banks')) {
      total += loadVectors('banks', f).length;
    }
    expect(total, greaterThanOrEqualTo(174));
  });

  test('merchants.json: нормализация мерчанта', () {
    final cases = loadVectors('banks', 'merchants.json');
    expect(cases.length, greaterThanOrEqualTo(37));
    for (final c in cases) {
      final input = c['input']! as _Json;
      final once = normalizeMerchant(
        data.normalization,
        input['text']! as String,
      );
      expect(once, c['expected'], reason: '${c['name']}');
      // Идемпотентность.
      expect(normalizeMerchant(data.normalization, once), once);
    }
  });

  test('similarity.json: сходство нормализованных имён', () {
    final cases = loadVectors('banks', 'similarity.json');
    expect(cases.length, greaterThanOrEqualTo(15));
    for (final c in cases) {
      final input = c['input']! as _Json;
      final a = input['a']! as String;
      final b = input['b']! as String;
      expect(similarity(a, b), c['expected'], reason: '${c['name']}');
      expect(similarity(b, a), c['expected'], reason: '${c['name']} (b, a)');
    }
  });

  test('dedup_hash.json: хвост и хеш', () {
    final cases = loadVectors('banks', 'dedup_hash.json');
    expect(cases.length, greaterThanOrEqualTo(11));
    for (final c in cases) {
      final i = c['input']! as _Json;
      final tail = dedupTail(
        data.normalization,
        kind: i['kind']! as String,
        amount: i['amount']! as int,
        occurredAt: parseFinanceInstant(i['occurred_at']),
        merchant: i['merchant'] as String?,
        ordinal: i['ordinal']! as int,
      );
      final expected = c['expected']! as _Json;
      expect(tail, expected['tail'], reason: '${c['name']}');
      expect(
        hashOf(i['account_id']! as String, tail),
        expected['hash'],
        reason: '${c['name']}',
      );
    }
  });

  test('matching.json: сопоставление кандидатов с существующими', () {
    final cases = loadVectors('banks', 'matching.json');
    expect(cases.length, greaterThanOrEqualTo(31));
    for (final c in cases) {
      final i = c['input']! as _Json;
      final results = classifyCandidates(
        data.normalization,
        accountId: i['account_id']! as String,
        candidates: [for (final x in _list(i['candidates'])) _candidate(x)],
        existing: [for (final x in _list(i['existing'])) _existing(x)],
      );
      expect(
        [for (final r in results) r.toJson()],
        c['expected'],
        reason: '${c['name']}',
      );
    }
  });

  test('transfers.json: переводы между своими счетами', () {
    final cases = loadVectors('banks', 'transfers.json');
    expect(cases.length, greaterThanOrEqualTo(17));
    for (final c in cases) {
      final i = c['input']! as _Json;
      final found = matchTransfers([
        for (final t in _list(i['transactions']))
          TransferRow(
            id: t['id']! as String,
            kind: t['kind']! as String,
            accountId: t['account_id']! as String,
            amount: t['amount']! as int,
            occurredAt: parseFinanceInstant(t['occurred_at']),
            currency: (t['currency'] as String?) ?? 'RUB',
            dateOnly: t['date_only'] == true,
            debtId: t['debt_id'] as String?,
          ),
      ], windowSeconds: i['window_seconds']! as int);
      expect(
        [for (final p in found) p.toJson()],
        c['expected'],
        reason: '${c['name']}',
      );
    }
  });

  test('notification_parse.json: разбор уведомлений по правилам', () {
    final cases = loadVectors('banks', 'notification_parse.json');
    expect(cases.length, greaterThanOrEqualTo(36));
    for (final c in cases) {
      final i = c['input']! as _Json;
      final result = parseNotification(
        data.notifications,
        package: i['package'] as String?,
        title: i['title']! as String,
        text: i['text']! as String,
      );
      expect(result.toJson(), c['expected'], reason: '${c['name']}');
    }
  });

  test('category_suggest.json: автокатегории', () {
    final cases = loadVectors('banks', 'category_suggest.json');
    expect(cases.length, greaterThanOrEqualTo(20));
    for (final c in cases) {
      final i = c['input']! as _Json;
      final result = suggestCategory(
        data,
        merchant: i['merchant'] as String?,
        mcc: i['mcc'] as String?,
        kind: i['kind']! as String,
        userRules: [
          for (final r in _list(i['user_rules']))
            UserCategoryRule(
              id: r['id']! as String,
              merchantKey: r['merchant_key']! as String,
              matchType: r['match_type']! as String,
              kind: r['kind']! as String,
              categoryId: r['category_id']! as String,
            ),
        ],
      );
      expect(result.toJson(), c['expected'], reason: '${c['name']}');
    }
  });
}
