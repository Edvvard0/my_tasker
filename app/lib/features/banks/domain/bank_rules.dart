/// Правила Банков (spec `stage6_banks.md`, разделы 3, 4, 8): нормализация
/// мерчанта, хеш дедупликации, сходство, сопоставление выписки с
/// существующими операциями, склейка переводов между своими счетами и
/// автокатегории. Чистые функции, один в один с эталоном
/// `backend/src/tasker/banks/reference.py`; поведение закреплено общими
/// векторами `shared-test-vectors/banks/`.
///
/// Всё целочисленное, без локале-зависимого `toLowerCase`: алфавит
/// нормализации — `a-z`, `0-9`, `а-я`; прочее — разделитель.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart'
    show compareCodePoints, moscowDay;
import 'package:my_tasker/features/finance/domain/finance_models.dart'
    show financeInstantText;
import 'package:my_tasker/features/finance/domain/finance_presets.dart'
    show categoryPresetId;

/// Порог сходства мерчантов (0..100), с которого они «одинаковые».
const int matchThreshold = 60;

/// Сходство, когда у одной из сторон имени нет: ровно порог.
const int unknownSimilarity = 60;

/// Одно имя — начало другого по словам.
const int prefixSimilarity = 90;

/// Окно сопоставления: 48 часов включительно.
const Duration matchWindow = Duration(hours: 48);

/// Окно склейки переводов между своими счетами (10 минут).
const int transferWindowSeconds = 600;

/// Строка «только дата» получает 12:00 по Москве = 09:00Z этой даты.
const int dateOnlyHourUtc = 9;

const int dedupHashLength = 32;
const String homeCurrency = 'RUB';

// ------------------------------------------------------------ нормализация

String _foldChar(int c) {
  if ((c >= 0x61 && c <= 0x7A) ||
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x430 && c <= 0x44F)) {
    return String.fromCharCode(c);
  }
  if ((c >= 0x41 && c <= 0x5A) || (c >= 0x410 && c <= 0x42F)) {
    return String.fromCharCode(c + 32);
  }
  if (c == 0x451 || c == 0x401) return 'е';
  return ' ';
}

/// Слова [text] в алфавите нормализации.
List<String> foldWords(String text) {
  final folded = StringBuffer();
  for (final c in text.runes) {
    folded.write(_foldChar(c));
  }
  return [
    for (final part in folded.toString().split(' '))
      if (part.isNotEmpty) part,
  ];
}

bool _isDigits(String word) =>
    word.isNotEmpty && word.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

bool _sameWords(List<String> a, int from, List<String> b) {
  for (var i = 0; i < b.length; i++) {
    if (a[from + i] != b[i]) return false;
  }
  return true;
}

List<String> _stripTail(
  List<String> tokens,
  List<List<String>> cities,
  Set<String> countries,
) {
  final out = [...tokens];
  while (out.isNotEmpty) {
    final last = out.last;
    if (countries.contains(last) || _isDigits(last)) {
      out.removeLast();
      continue;
    }
    var removed = false;
    for (final city in cities) {
      final size = city.length;
      if (size <= out.length && _sameWords(out, out.length - size, city)) {
        out.removeRange(out.length - size, out.length);
        removed = true;
        break;
      }
    }
    if (!removed) return out;
  }
  return out;
}

/// Ключ мерчанта: нижний регистр, только буквы и цифры, одно пробел между
/// словами, без юрформ, кодов стран, городов и номеров терминалов в конце.
/// Идемпотентна; если очистка оставила бы пустоту — берётся предыдущий шаг.
String normalizeMerchant(MerchantNormalizationData data, String text) {
  final tokens = foldWords(text);
  final withoutLegal = [
    for (final t in tokens)
      if (!data.legalForms.contains(t)) t,
  ];
  final base = withoutLegal.isEmpty ? tokens : withoutLegal;
  final stripped = _stripTail(base, data.cities, data.countryCodes);
  return (stripped.isEmpty ? base : stripped).join(' ');
}

// --------------------------------------------------------------- сходство

Map<String, int> _bigrams(String text) {
  final out = <String, int>{};
  for (var i = 0; i < text.length - 1; i++) {
    final gram = text.substring(i, i + 2);
    out[gram] = (out[gram] ?? 0) + 1;
  }
  return out;
}

int _sum(Iterable<int> values) => values.fold(0, (a, b) => a + b);

/// Насколько похожи два **нормализованных** имени, 0..100 (целое).
int similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 100;
  final wordsA = a.split(' ');
  final wordsB = b.split(' ');
  final shortWords = wordsA.length <= wordsB.length ? wordsA : wordsB;
  final longWords = wordsA.length <= wordsB.length ? wordsB : wordsA;
  var prefix = true;
  for (var i = 0; i < shortWords.length; i++) {
    if (longWords[i] != shortWords[i]) {
      prefix = false;
      break;
    }
  }
  if (prefix) return prefixSimilarity;
  final gramsA = _bigrams(a.replaceAll(' ', ''));
  final gramsB = _bigrams(b.replaceAll(' ', ''));
  final total = _sum(gramsA.values) + _sum(gramsB.values);
  if (total == 0) return 0;
  var common = 0;
  for (final e in gramsA.entries) {
    final other = gramsB[e.key];
    if (other != null) common += e.value < other ? e.value : other;
  }
  return 2 * common * 100 ~/ total;
}

/// Сходство сырых мерчантов; если у стороны имени нет — «не можем
/// сравнить» ([unknownSimilarity]).
int merchantSimilarity(MerchantNormalizationData data, String? a, String? b) {
  final normA = normalizeMerchant(data, a ?? '');
  final normB = normalizeMerchant(data, b ?? '');
  if (normA.isEmpty || normB.isEmpty) return unknownSimilarity;
  return similarity(normA, normB);
}

// ------------------------------------------------------------ хеш операции

String _pad(int v, [int width = 2]) => v.toString().padLeft(width, '0');

/// `YYYY-MM-DDTHH:MM` (UTC, секунды отброшены).
String minuteOf(DateTime instant) {
  final u = instant.toUtc();
  return '${_pad(u.year, 4)}-${_pad(u.month)}-${_pad(u.day)}T'
      '${_pad(u.hour)}:${_pad(u.minute)}';
}

/// `kind|amount|minute|merchant_norm` (+ `|ordinal` у 2-й, 3-й … одинаковой).
String dedupTail(
  MerchantNormalizationData data, {
  required String kind,
  required int amount,
  required DateTime occurredAt,
  String? merchant,
  int ordinal = 0,
}) {
  final tail =
      '$kind|$amount|${minuteOf(occurredAt)}|'
      '${normalizeMerchant(data, merchant ?? '')}';
  return ordinal > 0 ? '$tail|$ordinal' : tail;
}

/// `dedup_hash`: первые 32 hex-символа SHA-256 от `account_id|tail`.
String hashOf(String accountId, String tail) => sha256
    .convert(utf8.encode('$accountId|$tail'))
    .toString()
    .substring(0, dedupHashLength);

/// `dedup_hash` операции.
String dedupHash(
  MerchantNormalizationData data, {
  required String accountId,
  required String kind,
  required int amount,
  required DateTime occurredAt,
  String? merchant,
  int ordinal = 0,
}) => hashOf(
  accountId,
  dedupTail(
    data,
    kind: kind,
    amount: amount,
    occurredAt: occurredAt,
    merchant: merchant,
    ordinal: ordinal,
  ),
);

/// Кандидат из выписки (или уведомления).
@immutable
class StatementCandidate {
  const StatementCandidate({
    required this.kind,
    required this.amount,
    required this.occurredAt,
    this.currency = homeCurrency,
    this.dateOnly = false,
    this.merchant,
    this.externalId,
  });

  /// `expense` или `income`.
  final String kind;

  /// Копейки.
  final int amount;
  final DateTime occurredAt;
  final String currency;

  /// У строки выписки была только дата (момент — 12:00 по Москве).
  final bool dateOnly;
  final String? merchant;
  final String? externalId;
}

/// `dedup_tail` каждого кандидата; одинаковые в пачке получают порядковые
/// номера 0, 1, … (две настоящие одинаковые покупки не схлопываются).
List<String> withTails(
  MerchantNormalizationData data,
  List<StatementCandidate> candidates,
) {
  final seen = <String, int>{};
  final tails = <String>[];
  for (final item in candidates) {
    final base = dedupTail(
      data,
      kind: item.kind,
      amount: item.amount,
      occurredAt: item.occurredAt,
      merchant: item.merchant,
    );
    final n = seen[base] ?? 0;
    tails.add(n > 0 ? '$base|$n' : base);
    seen[base] = n + 1;
  }
  return tails;
}

// ------------------------------------------------------------ сопоставление

/// Существующая операция счёта (строка `transactions`).
@immutable
class ExistingOperation {
  const ExistingOperation({
    required this.id,
    required this.accountId,
    required this.kind,
    required this.amount,
    required this.occurredAt,
    this.merchant,
    this.source,
    this.externalId,
    this.dedupHash,
  });

  final String id;
  final String accountId;
  final String kind;
  final int amount;
  final DateTime occurredAt;
  final String? merchant;

  /// `manual` / `notification` / `statement` / `work_payment`.
  final String? source;
  final String? externalId;
  final String? dedupHash;
}

/// Что делать с кандидатом.
enum MatchAction {
  /// Создать операцию.
  create('new'),

  /// Такая операция уже есть: пропустить.
  duplicate('duplicate'),

  /// Выписка уточняет существующий черновик, а не создаёт вторую операцию.
  merge('merge');

  const MatchAction(this.wire);

  final String wire;
}

/// Результат сопоставления одного кандидата.
@immutable
class MatchResult {
  const MatchResult({
    required this.index,
    required this.action,
    required this.dedupHash,
    required this.needsReview,
    this.existingId,
    this.reason,
    this.similarity,
    this.reviewReason,
    this.refine,
  });

  final int index;
  final MatchAction action;
  final String? existingId;

  /// `external_id`, `hash` или `fuzzy`.
  final String? reason;
  final int? similarity;
  final String dedupHash;
  final bool needsReview;
  final String? reviewReason;

  /// Только у `merge`: что выписка уточняет (`occurred_at`, `merchant`).
  final Map<String, String>? refine;

  /// В виде JSON эталона (для общих векторов).
  Map<String, Object?> toJson() => {
    'index': index,
    'action': action.wire,
    'existing_id': existingId,
    'reason': reason,
    'similarity': similarity,
    'dedup_hash': dedupHash,
    'needs_review': needsReview,
    'review_reason': reviewReason,
    'refine': ?refine,
  };

  MatchResult copyWith({
    MatchAction? action,
    String? existingId,
    String? reason,
    int? similarity,
    Map<String, String>? refine,
  }) => MatchResult(
    index: index,
    action: action ?? this.action,
    dedupHash: dedupHash,
    needsReview: needsReview,
    reviewReason: reviewReason,
    existingId: existingId ?? this.existingId,
    reason: reason ?? this.reason,
    similarity: similarity ?? this.similarity,
    refine: refine ?? this.refine,
  );
}

bool _isForeign(String currency) =>
    (currency.isEmpty ? homeCurrency : currency) != homeCurrency;

/// Два разных банковских идентификатора — точно разные операции.
bool _clash(StatementCandidate c, ExistingOperation e) =>
    c.externalId != null &&
    e.externalId != null &&
    c.externalId != e.externalId;

/// Что делать с каждым кандидатом счёта [accountId] (spec 4.3):
/// `new`, `duplicate` или `merge`.
///
/// 1. Тот же внешний идентификатор или тот же `dedup_hash` — `duplicate`.
/// 2. Нечётко среди ещё не занятых строк: тот же вид и сумма, не дальше
///    48 часов, мерчанты похожи (>= 60; отсутствующий — ровно порог).
///    Пары берутся от лучшей (сходство, разница времени, id), одна строка
///    обслуживает одного кандидата. У строки источника `statement` —
///    `duplicate`, у остальных — `merge`.
/// 3. Чужая валюта нечётко не сопоставляется и получает `needs_review`.
List<MatchResult> classifyCandidates(
  MerchantNormalizationData data, {
  required String accountId,
  required List<StatementCandidate> candidates,
  required List<ExistingOperation> existing,
}) {
  final rows = [
    for (final e in existing)
      if (e.accountId == accountId) e,
  ];
  final tails = withTails(data, candidates);
  final hashes = [for (final tail in tails) hashOf(accountId, tail)];
  final results = <MatchResult>[
    for (var i = 0; i < candidates.length; i++)
      MatchResult(
        index: i,
        action: MatchAction.create,
        dedupHash: hashes[i],
        needsReview: _isForeign(candidates[i].currency),
        reviewReason: _isForeign(candidates[i].currency)
            ? 'foreign_currency'
            : null,
      ),
  ];
  final taken = <String>{};
  for (var i = 0; i < candidates.length; i++) {
    final candidate = candidates[i];
    final free = [
      for (final r in rows)
        if (!taken.contains(r.id) && !_clash(candidate, r)) r,
    ];
    final ext = candidate.externalId;
    ExistingOperation? byId;
    if (ext != null) {
      for (final r in free) {
        if (r.externalId == ext) {
          byId = r;
          break;
        }
      }
    }
    ExistingOperation? byHash;
    for (final r in free) {
      if (r.dedupHash == hashes[i]) {
        byHash = r;
        break;
      }
    }
    final found = byId ?? byHash;
    if (found != null) {
      taken.add(found.id);
      results[i] = results[i].copyWith(
        action: MatchAction.duplicate,
        existingId: found.id,
        reason: byId != null ? 'external_id' : 'hash',
      );
    }
  }

  final pairs = <_Pair>[];
  for (var i = 0; i < candidates.length; i++) {
    final candidate = candidates[i];
    if (results[i].action != MatchAction.create ||
        _isForeign(candidate.currency)) {
      continue;
    }
    final when = _seconds(candidate.occurredAt);
    for (final row in rows) {
      if (taken.contains(row.id) ||
          row.kind != candidate.kind ||
          row.amount != candidate.amount ||
          _clash(candidate, row)) {
        continue;
      }
      final gap = (_seconds(row.occurredAt) - when).abs();
      if (gap > matchWindow.inSeconds) continue;
      final score = merchantSimilarity(data, candidate.merchant, row.merchant);
      if (score >= matchThreshold) pairs.add(_Pair(-score, gap, row.id, i));
    }
  }
  pairs.sort();
  final byRowId = {for (final r in rows) r.id: r};
  for (final pair in pairs) {
    if (taken.contains(pair.rowId) ||
        results[pair.index].action != MatchAction.create) {
      continue;
    }
    taken.add(pair.rowId);
    final row = byRowId[pair.rowId]!;
    final merge = row.source != 'statement';
    results[pair.index] = results[pair.index].copyWith(
      action: merge ? MatchAction.merge : MatchAction.duplicate,
      existingId: pair.rowId,
      reason: 'fuzzy',
      similarity: -pair.negScore,
      refine: merge ? _refinement(candidates[pair.index], row) : null,
    );
  }
  return results;
}

int _seconds(DateTime instant) =>
    instant.toUtc().millisecondsSinceEpoch ~/ 1000;

class _Pair implements Comparable<_Pair> {
  _Pair(this.negScore, this.gap, this.rowId, this.index);

  final int negScore;
  final int gap;
  final String rowId;
  final int index;

  @override
  int compareTo(_Pair other) {
    if (negScore != other.negScore) return negScore.compareTo(other.negScore);
    if (gap != other.gap) return gap.compareTo(other.gap);
    final byId = compareCodePoints(rowId, other.rowId);
    if (byId != 0) return byId;
    return index.compareTo(other.index);
  }
}

/// Что строка выписки уточняет в черновике: точный момент (только если у
/// строки есть время) и мерчанта (только если строка его называет).
Map<String, String> _refinement(StatementCandidate c, ExistingOperation row) {
  final refine = <String, String>{};
  if (!c.dateOnly && _seconds(c.occurredAt) != _seconds(row.occurredAt)) {
    refine['occurred_at'] = financeInstantText(c.occurredAt);
  }
  final merchant = _trimSpaces(c.merchant ?? '');
  if (merchant.isNotEmpty && merchant != (row.merchant ?? '')) {
    refine['merchant'] = merchant;
  }
  return refine;
}

String _trimSpaces(String s) => s.trim();

/// Момент строки с одной датой: 12:00 по Москве этой даты.
DateTime dateOnlyInstant(String day) => DateTime.utc(
  int.parse(day.substring(0, 4)),
  int.parse(day.substring(5, 7)),
  int.parse(day.substring(8, 10)),
  dateOnlyHourUtc,
);

// -------------------------------------------------------- переводы своих

/// Операция для поиска переводов между своими счетами.
@immutable
class TransferRow {
  const TransferRow({
    required this.id,
    required this.kind,
    required this.accountId,
    required this.amount,
    required this.occurredAt,
    this.currency = homeCurrency,
    this.dateOnly = false,
    this.debtId,
  });

  final String id;
  final String kind;
  final String accountId;
  final int amount;
  final DateTime occurredAt;
  final String currency;
  final bool dateOnly;
  final String? debtId;
}

/// Предложение склеить расход и доход в один перевод.
@immutable
class TransferPair {
  const TransferPair({
    required this.expenseId,
    required this.incomeId,
    required this.deltaSeconds,
  });

  final String expenseId;
  final String incomeId;
  final int deltaSeconds;

  Map<String, Object?> toJson() => {
    'expense_id': expenseId,
    'income_id': incomeId,
    'delta_seconds': deltaSeconds,
  };
}

/// Предложения склеить перевод между своими счетами: расход на одном счёте
/// и доход на **другом** с той же суммой не дальше [windowSeconds] (для
/// строк с одной датой — та же московская дата). Чужая валюта и движения
/// по долгу не участвуют; каждая строка входит в одну пару, ближайшие
/// пары первыми.
List<TransferPair> matchTransfers(
  List<TransferRow> transactions, {
  int windowSeconds = transferWindowSeconds,
}) {
  final usable = [
    for (final t in transactions)
      if ((t.kind == 'expense' || t.kind == 'income') &&
          !_isForeign(t.currency) &&
          t.debtId == null)
        t,
  ];
  final pairs = <(int, String, String)>[];
  for (final out in usable.where((t) => t.kind == 'expense')) {
    for (final inc in usable.where((t) => t.kind == 'income')) {
      if (out.accountId == inc.accountId || out.amount != inc.amount) continue;
      final gap = (_seconds(out.occurredAt) - _seconds(inc.occurredAt)).abs();
      if (out.dateOnly || inc.dateOnly) {
        if (moscowDay(out.occurredAt) != moscowDay(inc.occurredAt)) continue;
      } else if (gap > windowSeconds) {
        continue;
      }
      pairs.add((gap, out.id, inc.id));
    }
  }
  pairs.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    final byOut = compareCodePoints(a.$2, b.$2);
    return byOut != 0 ? byOut : compareCodePoints(a.$3, b.$3);
  });
  final used = <String>{};
  final found = <TransferPair>[];
  for (final (gap, outId, inId) in pairs) {
    if (used.contains(outId) || used.contains(inId)) continue;
    used
      ..add(outId)
      ..add(inId);
    found.add(
      TransferPair(expenseId: outId, incomeId: inId, deltaSeconds: gap),
    );
  }
  return found;
}

// ------------------------------------------------------------ автокатегории

/// Правило пользователя «мерчант → категория» (таблица
/// `merchant_category_rules`).
@immutable
class UserCategoryRule {
  const UserCategoryRule({
    required this.id,
    required this.merchantKey,
    required this.matchType,
    required this.kind,
    required this.categoryId,
  });

  final String id;

  /// Уже нормализованное имя.
  final String merchantKey;

  /// `exact` или `contains`.
  final String matchType;

  /// `expense` или `income`.
  final String kind;
  final String categoryId;
}

/// Предложенная категория.
@immutable
class CategorySuggestion {
  const CategorySuggestion({this.source, this.categoryId, this.systemKey});

  /// `user`, `keyword`, `mcc` или `null`.
  final String? source;
  final String? categoryId;
  final String? systemKey;

  Map<String, Object?> toJson() => {
    'source': source,
    'category_id': categoryId,
    'system_key': systemKey,
  };
}

bool _containsWords(List<String> tokens, List<String> needle) {
  final size = needle.length;
  if (size == 0) return false;
  for (var i = 0; i + size <= tokens.length; i++) {
    if (_sameWords(tokens, i, needle)) return true;
  }
  return false;
}

String _kindOfKey(String systemKey) => systemKey.split('.').first;

CategorySuggestion _preset(String source, String key) => CategorySuggestion(
  source: source,
  categoryId: categoryPresetId(key),
  systemKey: key,
);

/// Категория операции: правила пользователя (`exact` раньше `contains`,
/// длинные ключи раньше), затем ключевые слова словаря (порядок файла),
/// затем MCC.
CategorySuggestion suggestCategory(
  BankData data, {
  required String? merchant,
  required String? mcc,
  required String kind,
  List<UserCategoryRule> userRules = const [],
}) {
  final norm = normalizeMerchant(data.normalization, merchant ?? '');
  final tokens = norm.isEmpty ? <String>[] : norm.split(' ');
  final mine = [
    for (final r in userRules)
      if (r.kind == kind) r,
  ];
  final exact = [
    for (final r in mine)
      if (r.matchType == 'exact' && r.merchantKey == norm) r,
  ]..sort((a, b) => compareCodePoints(a.id, b.id));
  final contained = [
    for (final r in mine)
      if (r.matchType == 'contains' &&
          _containsWords(tokens, r.merchantKey.split(' ')))
        r,
  ];
  int wordCount(UserCategoryRule r) => r.merchantKey.split(' ').length;
  contained.sort((a, b) {
    if (wordCount(a) != wordCount(b)) {
      return wordCount(b).compareTo(wordCount(a));
    }
    final byLength = b.merchantKey.runes.length.compareTo(
      a.merchantKey.runes.length,
    );
    return byLength != 0 ? byLength : compareCodePoints(a.id, b.id);
  });
  final chosen = [...exact, ...contained];
  if (chosen.isNotEmpty) {
    return CategorySuggestion(
      source: 'user',
      categoryId: chosen.first.categoryId,
    );
  }
  for (final entry in data.dictionary.keywords) {
    if (_kindOfKey(entry.key) == kind &&
        entry.words.any((w) => _containsWords(tokens, w.split(' ')))) {
      return _preset('keyword', entry.key);
    }
  }
  final key = mcc == null ? null : data.dictionary.mcc[mcc];
  if (key != null && _kindOfKey(key) == kind) return _preset('mcc', key);
  return const CategorySuggestion();
}
