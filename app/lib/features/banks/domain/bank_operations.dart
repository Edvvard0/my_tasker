/// Связка правил Банков с операциями «Финансов»: какие строки считаются
/// «существующими» при сопоставлении, момент операции по уведомлению и
/// кандидаты в переводы между своими счетами.
library;

import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart'
    show moscowDay;
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Строки счёта [accountId] для `classifyCandidates`.
///
/// Перевод между своими счетами — это две «стороны» одной строки: у счёта
/// «откуда» он выглядит расходом, у счёта «куда» — доходом. Источник у
/// таких строк `statement`: совпавшая с ними строка выписки — дубликат, а
/// не «уточнение черновика» (переводы не уточняются).
List<ExistingOperation> existingOperationsFor(
  String accountId,
  Iterable<FinTransaction> transactions,
) {
  final out = <ExistingOperation>[];
  for (final t in transactions) {
    if (t.kind == TxKind.transfer) {
      final side = t.accountId == accountId
          ? 'expense'
          : (t.toAccountId == accountId ? 'income' : null);
      if (side == null) continue;
      out.add(
        ExistingOperation(
          id: t.id,
          accountId: accountId,
          kind: side,
          amount: t.amount,
          occurredAt: t.occurredAt,
          // У получателя строка выписки называет отправителя по-своему:
          // имя не сравниваем («не можем сравнить»), решают сумма и время.
          merchant: side == 'expense' ? t.merchant : null,
          source: 'statement',
          externalId: t.accountId == accountId ? t.externalId : null,
          dedupHash: t.accountId == accountId ? t.dedupHash : null,
        ),
      );
      continue;
    }
    if (t.accountId != accountId) continue;
    out.add(
      ExistingOperation(
        id: t.id,
        accountId: accountId,
        kind: t.kind.wire,
        amount: t.amount,
        occurredAt: t.occurredAt,
        merchant: t.merchant,
        source: t.source.wire,
        externalId: t.externalId,
        dedupHash: t.dedupHash,
      ),
    );
  }
  return out;
}

/// Момент операции по уведомлению: время публикации; если правило
/// прочитало `HH:MM` (московское), то оно в тот же московский день. Время
/// позже публикации больше чем на 10 минут — это «вчера» (уведомление
/// пришло после полуночи).
DateTime notificationMoment(DateTime postedAt, String? time) {
  if (time == null) return postedAt.toUtc();
  final day = moscowDay(postedAt);
  final hour = int.parse(time.substring(0, 2));
  final minute = int.parse(time.substring(3, 5));
  var moment = DateTime.utc(
    int.parse(day.substring(0, 4)),
    int.parse(day.substring(5, 7)),
    int.parse(day.substring(8, 10)),
    hour - 3,
    minute,
  );
  if (moment.isAfter(postedAt.toUtc().add(const Duration(minutes: 10)))) {
    moment = moment.subtract(const Duration(days: 1));
  }
  return moment;
}

/// Строка выписки с одной датой хранится в 12:00 по Москве (09:00Z).
bool isDateOnlyMoment(FinTransaction t) =>
    t.source == TxSource.statement &&
    t.occurredAt.toUtc().hour == dateOnlyHourUtc &&
    t.occurredAt.toUtc().minute == 0 &&
    t.occurredAt.toUtc().second == 0;

/// Предложения склеить перевод между своими счетами среди операций банков
/// (источники «уведомление» и «выписка»): расход и доход с одной суммой на
/// разных счетах в окне 10 минут. Пары из [dismissed] (ключ
/// `<id расхода>|<id дохода>`) не предлагаются.
List<TransferPair> transferSuggestions(
  Iterable<FinTransaction> transactions, {
  Set<String> dismissed = const {},
}) {
  final rows = [
    for (final t in transactions)
      if ((t.kind == TxKind.expense || t.kind == TxKind.income) &&
          t.debtId == null &&
          // «Требует проверки» — в том числе чужая валюта: не склеиваем.
          t.status != TxStatus.needsReview &&
          (t.source == TxSource.notification || t.source == TxSource.statement))
        TransferRow(
          id: t.id,
          kind: t.kind.wire,
          accountId: t.accountId,
          amount: t.amount,
          occurredAt: t.occurredAt,
          dateOnly: isDateOnlyMoment(t),
        ),
  ];
  return [
    for (final p in matchTransfers(rows))
      if (!dismissed.contains(transferPairKey(p))) p,
  ];
}

/// Ключ пары для списка «не склеивать».
String transferPairKey(TransferPair pair) =>
    '${pair.expenseId}|${pair.incomeId}';
