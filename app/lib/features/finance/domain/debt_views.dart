import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/finance/finance_calc.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Статус долга (spec 6.1): вычисляется из погашений, не хранится.
enum DebtStatus {
  open('Открыт', 'open'),
  partial('Частично', 'partial'),
  closed('Закрыт', 'closed');

  const DebtStatus(this.label, this.wire);

  final String label;
  final String wire;

  static DebtStatus parse(Object? value) => DebtStatus.values.firstWhere(
    (s) => s.wire == value,
    orElse: () => DebtStatus.open,
  );
}

/// Состояние одного долга (`debt_state`, spec 6.1) вместе с самим долгом.
@immutable
class DebtState {
  const DebtState({
    required this.debt,
    required this.repaid,
    required this.remaining,
    required this.overpaid,
    required this.status,
    required this.overdue,
    this.today,
  });

  /// Из результата доменной функции `debtState`.
  factory DebtState.fromJson(Debt debt, Json json, {String? today}) =>
      DebtState(
        debt: debt,
        repaid: json['repaid']! as int,
        remaining: json['remaining']! as int,
        overpaid: json['overpaid']! as int,
        status: DebtStatus.parse(json['status']),
        overdue: json['overdue']! as bool,
        today: today,
      );

  final Debt debt;

  /// Сумма погашений, копейки.
  final int repaid;

  /// `max(0, amount − repaid)`.
  final int remaining;

  /// `max(0, repaid − amount)`.
  final int overpaid;
  final DebtStatus status;

  /// Срок прошёл (в день срока ещё нет) и долг не закрыт — по московской
  /// дате [today].
  final bool overdue;

  /// Московская дата расчёта `YYYY-MM-DD`.
  final String? today;

  bool get isClosed => status == DebtStatus.closed;

  /// Сколько дней долг просрочен (0, если нет).
  int get overdueDays {
    final due = debt.dueDate;
    final now = today;
    if (!overdue || due == null || now == null) return 0;
    final dueDay = parseDate(due);
    final nowDay = parseDate(now);
    if (dueDay == null || nowDay == null) return 0;
    return daysBetween(dueDay, nowDay);
  }
}

/// «Долги»: состояния всех долгов и открытые остатки по направлениям
/// (`debts_summary`, spec 6.1).
@immutable
class DebtsOverview {
  const DebtsOverview({
    required this.owedToMe,
    required this.iOwe,
    required this.debts,
  });

  /// Считает обзор по видимым строкам; [today] — московская дата.
  factory DebtsOverview.compute(
    List<Json> debtRows,
    List<Json> repaymentRows, {
    required String today,
  }) {
    final summary = debtsSummary(debtRows, repaymentRows, today: today);
    final states = (summary['debts']! as List<Object?>).cast<Json>();
    final list = [
      for (var i = 0; i < debtRows.length; i++)
        DebtState.fromJson(Debt.fromRow(debtRows[i]), states[i], today: today),
    ];
    return DebtsOverview(
      owedToMe: summary['owed_to_me']! as int,
      iOwe: summary['i_owe']! as int,
      debts: list,
    );
  }

  /// Σ открытых остатков «мне должны».
  final int owedToMe;

  /// Σ открытых остатков «я должен».
  final int iOwe;

  /// Состояния в порядке входа.
  final List<DebtState> debts;

  bool get isEmpty => debts.isEmpty;

  /// Долги направления: [closed] выбирает закрытые или нет. Не закрытые —
  /// больший остаток выше (при равных — по дате долга и id); закрытые —
  /// новые сверху.
  List<DebtState> of(DebtDirection direction, {required bool closed}) {
    final list =
        [
          for (final s in debts)
            if (s.debt.direction == direction && s.isClosed == closed) s,
        ]..sort((a, b) {
          if (closed) {
            final byDate = b.debt.debtDate.compareTo(a.debt.debtDate);
            return byDate != 0 ? byDate : b.debt.id.compareTo(a.debt.id);
          }
          final byRemaining = b.remaining.compareTo(a.remaining);
          if (byRemaining != 0) return byRemaining;
          final byDate = a.debt.debtDate.compareTo(b.debt.debtDate);
          return byDate != 0 ? byDate : a.debt.id.compareTo(b.debt.id);
        });
    return list;
  }

  /// Число не закрытых долгов направления.
  int openCount(DebtDirection direction) =>
      debts.where((s) => s.debt.direction == direction && !s.isClosed).length;

  DebtState? byId(String id) {
    for (final s in debts) {
      if (s.debt.id == id) return s;
    }
    return null;
  }
}

/// Карточка долга: состояние и история погашений (новые сверху).
@immutable
class DebtDetail {
  const DebtDetail({required this.state, required this.repayments});

  final DebtState state;
  final List<DebtRepayment> repayments;

  Debt get debt => state.debt;
}

/// Погашения долга [debtId]: новые сверху (дата, затем id по убыванию).
List<DebtRepayment> repaymentsOfDebt(List<Json> rows, String debtId) {
  final list =
      [
        for (final r in rows)
          if (r['debt_id'] == debtId) DebtRepayment.fromRow(r),
      ]..sort((a, b) {
        final byDate = b.repaidOn.compareTo(a.repaidOn);
        return byDate != 0 ? byDate : b.id.compareTo(a.id);
      });
  return list;
}
