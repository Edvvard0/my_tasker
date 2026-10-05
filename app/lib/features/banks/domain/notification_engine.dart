/// Движок правил уведомлений банков (spec `stage6_banks.md`, раздел 2): один
/// на все банки, правила — данные (`notification_rules.json`). Порт
/// `backend/src/tasker/banks/notifications.py`; результат на общих
/// векторах `shared-test-vectors/banks/notification_parse.json` совпадает
/// с эталоном.
library;

import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart'
    show homeCurrency, trimEdgeSpaces;

/// Пробелы очистки: U+0020 U+00A0 U+202F U+2009 U+2007 U+0009 U+000D U+000A
/// U+2028 U+2029 U+000B U+000C (`trim()` и `\s` здесь не подходят: они
/// различаются между средами).
const Set<int> _spaces = {
  0x20,
  0xA0,
  0x202F,
  0x2009,
  0x2007,
  0x09,
  0x0D,
  0x0A,
  0x2028,
  0x2029,
  0x0B,
  0x0C,
};

/// Очистка текста перед сопоставлением (2.3): перечисленные пробелы и
/// переводы строк — одним обычным пробелом, серии схлопываются, края
/// обрезаются.
String normalizeNotificationText(String text) {
  final flat = StringBuffer();
  for (final c in text.runes) {
    flat.writeCharCode(_spaces.contains(c) ? 0x20 : c);
  }
  return [
    for (final part in flat.toString().split(' '))
      if (part.isNotEmpty) part,
  ].join(' ');
}

/// Статус разбора.
enum NotificationStatus {
  parsed('parsed'),
  ignored('ignored'),
  unrecognized('unrecognized');

  const NotificationStatus(this.wire);

  final String wire;
}

/// Результат разбора одного уведомления (2.4).
@immutable
class NotificationParse {
  const NotificationParse({
    required this.status,
    this.bank,
    this.ruleId,
    this.reason,
    this.kind,
    this.refund = false,
    this.amount,
    this.currency,
    this.cardLast4,
    this.merchant,
    this.balance,
    this.time,
    this.needsReview = false,
    this.reviewReason,
  });

  /// Из сохранённого JSON (черновик «нужен счёт»).
  factory NotificationParse.fromJson(Map<String, Object?> json) =>
      NotificationParse(
        status: NotificationStatus.values.firstWhere(
          (s) => s.wire == json['status'],
          orElse: () => NotificationStatus.unrecognized,
        ),
        bank: json['bank'] as String?,
        ruleId: json['rule_id'] as String?,
        reason: json['reason'] as String?,
        kind: json['kind'] as String?,
        refund: json['refund'] == true,
        amount: json['amount'] as int?,
        currency: json['currency'] as String?,
        cardLast4: json['card_last4'] as String?,
        merchant: json['merchant'] as String?,
        balance: json['balance'] as int?,
        time: json['time'] as String?,
        needsReview: json['needs_review'] == true,
        reviewReason: json['review_reason'] as String?,
      );

  final NotificationStatus status;
  final String? bank;
  final String? ruleId;

  /// У `ignored` (неизвестный пакет) и `unrecognized`: `unknown_package`,
  /// `no_rule`, `bad_amount`, `unknown_currency`.
  final String? reason;

  /// Только у `parsed`: `expense` или `income`.
  final String? kind;
  final bool refund;

  /// Копейки, > 0.
  final int? amount;
  final String? currency;
  final String? cardLast4;
  final String? merchant;

  /// Остаток после операции (копейки).
  final int? balance;

  /// `HH:MM` или `null`.
  final String? time;
  final bool needsReview;
  final String? reviewReason;

  bool get isParsed => status == NotificationStatus.parsed;

  /// В виде JSON эталона (общие векторы, хранение).
  Map<String, Object?> toJson() {
    if (status == NotificationStatus.parsed) {
      return {
        'status': 'parsed',
        'bank': bank,
        'rule_id': ruleId,
        'kind': kind,
        'refund': refund,
        'amount': amount,
        'currency': currency,
        'card_last4': cardLast4,
        'merchant': merchant,
        'balance': balance,
        'time': time,
        'needs_review': needsReview,
        'review_reason': reviewReason,
      };
    }
    return {
      'status': status.wire,
      'bank': bank,
      'rule_id': ruleId,
      'reason': ?reason,
    };
  }
}

const Set<String> _escapable = {
  '.',
  '*',
  '+',
  '?',
  '(',
  ')',
  '[',
  ']',
  '{',
  '}',
  '|',
  '^',
  r'$',
  r'\',
  '-',
  '/',
};

final RegExp _braces = RegExp(r'^\{[0-9]+(?:,[0-9]*)?\}');

/// Почему [pattern] вне переносимого подмножества (2.2), или `null`.
/// Правило вне подмножества — ошибка данных.
String? patternProblem(String pattern) {
  var i = 0;
  var inClass = false;
  // 1: предыдущий токен — квантификатор (допустим один ленивый `?`),
  // 2: ленивый.
  var quantified = 0;
  while (i < pattern.length) {
    final char = pattern[i];
    if (char == r'\') {
      if (i + 1 >= pattern.length || !_escapable.contains(pattern[i + 1])) {
        return 'escape at $i is not allowed';
      }
      quantified = 0;
      i += 2;
      continue;
    }
    if (inClass) {
      if (char == '[') {
        return 'nested character class at $i is not allowed (escape the bracket)';
      }
      inClass = char != ']';
      i++;
      continue;
    }
    if (char == '[') {
      final start = i + 1 < pattern.length && pattern[i + 1] == '^'
          ? i + 2
          : i + 1;
      if (start < pattern.length && pattern[start] == ']') {
        return 'empty character class at $i is not allowed (escape the bracket)';
      }
      inClass = true;
      quantified = 0;
      i = start;
      continue;
    }
    if (char == '(' &&
        i + 1 < pattern.length &&
        pattern[i + 1] == '?' &&
        !(i + 2 < pattern.length && pattern[i + 2] == ':')) {
      return 'group construct at $i is not allowed';
    }
    if (char == '*' || char == '+' || char == '?' || char == '{') {
      var width = 1;
      if (char == '{') {
        final m = _braces.firstMatch(pattern.substring(i));
        if (m == null) {
          return 'brace at $i is not a {m}, {m,} or {m,n} quantifier';
        }
        width = m.end;
      }
      if (quantified == 1 && char == '?') {
        quantified = 2;
      } else if (quantified != 0) {
        return 'quantifier at $i follows another quantifier '
            '(possessive or repeated)';
      } else {
        quantified = 1;
      }
      i += width;
      continue;
    }
    quantified = 0;
    i++;
  }
  return inClass ? 'character class is not closed' : null;
}

final RegExp _card = RegExp(r'^[0-9]{4}$');
final RegExp _time = RegExp(r'^([0-9]{2}):([0-9]{2})$');

/// Разбор уведомления: правила банка, которому принадлежит [package]
/// (`onlyRule` — проверка одного правила на образце, пакет не нужен).
NotificationParse parseNotification(
  NotificationRules rules, {
  required String? package,
  required String title,
  required String text,
  NotificationRule? onlyRule,
}) {
  final bank = rules.bankOfPackage(package);
  final List<NotificationRule> candidates;
  final String? bankId;
  if (onlyRule != null) {
    candidates = [onlyRule];
    bankId = null;
  } else if (bank == null) {
    return const NotificationParse(
      status: NotificationStatus.ignored,
      reason: 'unknown_package',
    );
  } else {
    candidates = bank.rules;
    bankId = bank.id;
  }
  final cleanTitle = normalizeNotificationText(title);
  final cleanText = normalizeNotificationText(text);
  for (final rule in candidates) {
    final titles = rule.titles;
    if (titles != null && !titles.contains(cleanTitle)) continue;
    final match = rule.regex.firstMatch(cleanText);
    if (match == null) continue;
    return _result(rules, bankId, rule, match);
  }
  return NotificationParse(
    status: NotificationStatus.unrecognized,
    bank: bankId,
    reason: 'no_rule',
  );
}

NotificationParse _result(
  NotificationRules rules,
  String? bankId,
  NotificationRule rule,
  RegExpMatch match,
) {
  if (rule.kind == 'ignore') {
    return NotificationParse(
      status: NotificationStatus.ignored,
      bank: bankId,
      ruleId: rule.id,
    );
  }
  String? group(String name) {
    final index = rule.groups[name];
    final found = index == null ? null : match.group(index);
    return found == null ? null : trimEdgeSpaces(found);
  }

  NotificationParse unrecognized(String reason) => NotificationParse(
    status: NotificationStatus.unrecognized,
    bank: bankId,
    ruleId: rule.id,
    reason: reason,
  );

  final int amount;
  int? balance;
  try {
    amount = parseAmount(group('amount') ?? '');
    final rawBalance = group('balance');
    balance = rawBalance == null ? null : parseAmount(rawBalance);
    // Сумма операции строго положительная (2.4): «Покупка на 0 ₽» — не
    // операция. Остаток после операции может быть любым, в том числе нулём.
    if (amount <= 0) return unrecognized('bad_amount');
  } on FormatException {
    return unrecognized('bad_amount');
  }
  final symbol = group('currency');
  final fixed = rule.currencyFixed;
  final currency = (fixed != null && fixed.isNotEmpty)
      ? fixed
      : (symbol != null ? rules.currencies[symbol] : homeCurrency);
  if (currency == null) return unrecognized('unknown_currency');
  final card = group('card_last4');
  final moment = _time.firstMatch(group('time') ?? '');
  final foreign = currency != homeCurrency;
  final fixedMerchant = rule.merchantFixed;
  final merchant = (fixedMerchant != null && fixedMerchant.isNotEmpty)
      ? fixedMerchant
      : group('merchant');
  final hour = moment == null ? 0 : int.parse(moment[1]!);
  final minute = moment == null ? 0 : int.parse(moment[2]!);
  return NotificationParse(
    status: NotificationStatus.parsed,
    bank: bankId,
    ruleId: rule.id,
    kind: rule.kind,
    refund: rule.refund,
    amount: amount,
    currency: currency,
    cardLast4: card != null && _card.hasMatch(card) ? card : null,
    merchant: merchant == null || merchant.isEmpty ? null : merchant,
    balance: balance,
    time: moment != null && hour < 24 && minute < 60
        ? '${moment[1]}:${moment[2]}'
        : null,
    needsReview: foreign,
    reviewReason: foreign ? 'foreign_currency' : null,
  );
}

/// Проблемы файла правил (CI данных и тесты): подмножество выражений,
/// группы, образцы, уникальность.
List<String> rulesProblems(NotificationRules rules) {
  final problems = <String>[];
  final ids = <String>{};
  final packages = <String>{};
  for (final bank in rules.banks) {
    for (final p in bank.packages) {
      if (!packages.add(p)) problems.add('package $p listed twice');
    }
    for (final rule in bank.rules) {
      if (!ids.add(rule.id)) problems.add('${rule.id}: duplicate id');
      final bad = patternProblem(rule.pattern);
      if (bad != null) problems.add('${rule.id}: $bad');
      if (rule.kind != 'ignore' && !rule.groups.containsKey('amount')) {
        problems.add('${rule.id}: a financial rule needs an amount group');
      }
      if (rule.samples.isEmpty) problems.add('${rule.id}: no samples');
      for (final s in rule.samples) {
        final r = parseNotification(
          rules,
          package: null,
          title: s.title,
          text: s.text,
          onlyRule: rule,
        );
        if (r.ruleId != rule.id) {
          problems.add('${rule.id}: sample "${s.text}" is not matched');
        }
      }
    }
  }
  return problems;
}
