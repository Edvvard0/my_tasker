/// План импорта выписки: к каждой строке — счёт, результат сопоставления с
/// существующими операциями (дубликат / уточнение черновика / новая),
/// категория и отметка «импортировать».
library;

import 'package:flutter/foundation.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/bank_operations.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/banks/domain/statement_models.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

const Object _unset = Object();

/// Строка плана импорта.
@immutable
class ImportItem {
  const ImportItem({
    required this.line,
    required this.selected,
    this.accountId,
    this.match,
    this.categoryId,
  });

  final StatementLine line;

  /// `null` — счёт для карты строки не выбран.
  final String? accountId;

  /// Результат сопоставления; `null`, если счёта нет.
  final MatchResult? match;
  final String? categoryId;

  /// Создать/уточнить операцию при подтверждении.
  final bool selected;

  MatchAction get action => match?.action ?? MatchAction.create;

  /// Дубликат (или «уточнение» без изменений): такая операция уже есть.
  bool get isDuplicate =>
      match != null &&
      (match!.action == MatchAction.duplicate ||
          (match!.action == MatchAction.merge &&
              (match!.refine?.isEmpty ?? true)));

  /// Выписка уточняет существующий черновик.
  bool get isRefinement =>
      match != null &&
      match!.action == MatchAction.merge &&
      (match!.refine?.isNotEmpty ?? false);

  ImportItem copyWith({bool? selected, Object? categoryId = _unset}) =>
      ImportItem(
        line: line,
        accountId: accountId,
        match: match,
        categoryId: identical(categoryId, _unset)
            ? this.categoryId
            : categoryId as String?,
        selected: selected ?? this.selected,
      );
}

/// Сводка плана для экрана подтверждения.
@immutable
class ImportSummary {
  const ImportSummary({
    required this.toCreate,
    required this.toRefine,
    required this.duplicates,
    required this.foreign,
    required this.withoutAccount,
  });

  final int toCreate;
  final int toRefine;
  final int duplicates;

  /// Среди создаваемых: в чужой валюте (станут «Требует проверки»).
  final int foreign;
  final int withoutAccount;

  int get total => toCreate + toRefine;
}

ImportSummary summarize(List<ImportItem> items) {
  var create = 0;
  var refine = 0;
  var duplicates = 0;
  var foreign = 0;
  var noAccount = 0;
  for (final item in items) {
    if (item.accountId == null) {
      noAccount++;
      continue;
    }
    if (item.isDuplicate && !item.selected) {
      duplicates++;
      continue;
    }
    if (!item.selected) continue;
    if (item.isRefinement) {
      refine++;
    } else if (item.match?.action == MatchAction.create || item.match == null) {
      create++;
      if (item.line.needsReview) foreign++;
    } else {
      // Дубликат, который пользователь всё же отметил.
      create++;
    }
  }
  return ImportSummary(
    toCreate: create,
    toRefine: refine,
    duplicates: duplicates,
    foreign: foreign,
    withoutAccount: noAccount,
  );
}

/// Счёт для карты строки: [accountOfCard] по `card_last4`; ключ `null` —
/// счёт для строк без номера карты.
String? accountForLine(
  StatementLine line,
  Map<String?, String?> accountOfCard,
) => accountOfCard[line.cardLast4] ?? accountOfCard[null];

/// Строит план: сопоставляет строки каждого счёта с его операциями.
List<ImportItem> planImport({
  required BankData data,
  required List<StatementLine> lines,
  required Map<String?, String?> accountOfCard,
  required Iterable<FinTransaction> transactions,
  required List<UserCategoryRule> rules,
}) {
  final byAccount = <String, List<int>>{};
  for (var i = 0; i < lines.length; i++) {
    final account = accountForLine(lines[i], accountOfCard);
    if (account != null) byAccount.putIfAbsent(account, () => []).add(i);
  }
  final matches = <int, MatchResult>{};
  for (final entry in byAccount.entries) {
    final results = classifyCandidates(
      data.normalization,
      accountId: entry.key,
      candidates: [
        for (final i in entry.value)
          StatementCandidate(
            kind: lines[i].kind,
            amount: lines[i].amount,
            currency: lines[i].currency,
            occurredAt: lines[i].occurredAt,
            dateOnly: lines[i].dateOnly,
            merchant: lines[i].merchant,
            externalId: lines[i].externalId,
          ),
      ],
      existing: existingOperationsFor(entry.key, transactions),
    );
    for (var k = 0; k < entry.value.length; k++) {
      matches[entry.value[k]] = results[k];
    }
  }
  return [
    for (var i = 0; i < lines.length; i++)
      _item(
        data,
        lines[i],
        accountForLine(lines[i], accountOfCard),
        matches[i],
        rules,
      ),
  ];
}

ImportItem _item(
  BankData data,
  StatementLine line,
  String? accountId,
  MatchResult? match,
  List<UserCategoryRule> rules,
) {
  final suggestion = suggestCategory(
    data,
    merchant: line.merchant,
    mcc: line.mcc,
    kind: line.kind,
    userRules: rules,
  );
  final category = suggestion.categoryId ?? line.suggestedCategoryId;
  final selected =
      accountId != null &&
      match != null &&
      (match.action == MatchAction.create ||
          (match.action == MatchAction.merge &&
              (match.refine?.isNotEmpty ?? false)));
  return ImportItem(
    line: line,
    accountId: accountId,
    match: match,
    categoryId: category,
    selected: selected,
  );
}
