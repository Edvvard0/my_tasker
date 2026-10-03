import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/finance/finance_calc.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';

/// Данные Работы, нужные слагаемому `receivables` (spec 6.2): проекты,
/// доработки и распределения платежей. Клиента «Работы» в приложении пока
/// нет, поэтому по умолчанию все списки пусты и ожидаемые поступления
/// считаются как 0; когда Работа появится, достаточно подставить её строки.
@immutable
class WorkData {
  const WorkData({
    this.projects = const [],
    this.changeRequests = const [],
    this.allocations = const [],
  }) : connected = true;

  /// Работа не подключена: данных нет, `receivables` = 0.
  const WorkData.empty()
    : projects = const [],
      changeRequests = const [],
      allocations = const [],
      connected = false;

  final List<Json> projects;
  final List<Json> changeRequests;
  final List<Json> allocations;

  /// Данные Работы настоящие (а не заглушка): пометка «Работа ещё не
  /// подключена» не нужна.
  final bool connected;
}

/// Подписанное значение одного слагаемого (элемент `terms` результата
/// `goal_progress`): вычет — отрицательное число.
@immutable
class GoalTermValue {
  const GoalTermValue({required this.term, required this.value});

  final GoalTerm term;

  /// Копейки со знаком (знак слагаемого уже применён).
  final int value;
}

/// Прогресс цели (`goal_progress`, spec 6.2).
@immutable
class GoalProgress {
  const GoalProgress({
    required this.have,
    required this.target,
    required this.missing,
    required this.reached,
    required this.surplus,
    required this.progressBp,
    required this.terms,
  });

  /// Из результата доменной функции `goalProgress` и формулы цели
  /// ([terms] в том же порядке, что `terms` результата).
  factory GoalProgress.fromJson(Json json, List<GoalTerm> terms) {
    final values = (json['terms']! as List<Object?>).cast<Json>();
    return GoalProgress(
      have: json['have']! as int,
      target: json['target']! as int,
      missing: json['missing']! as int,
      reached: json['reached']! as bool,
      surplus: json['surplus']! as int,
      progressBp: json['progress_bp']! as int,
      terms: [
        for (var i = 0; i < terms.length && i < values.length; i++)
          GoalTermValue(term: terms[i], value: values[i]['value']! as int),
      ],
    );
  }

  /// «Есть»: сумма слагаемых со знаками, копейки.
  final int have;
  final int target;

  /// `target − have` со знаком: положительное — «не хватает», отрицательное
  /// — цель достигнута с запасом.
  final int missing;
  final bool reached;

  /// `max(0, −missing)`.
  final int surplus;

  /// Доля в сотых долях процента, вниз; больше 10 000 при перевыполнении.
  final int progressBp;
  final List<GoalTermValue> terms;

  /// Доля для полосы: обрезана на 100 %.
  double get barFraction => (progressBp / 10000).clamp(0.0, 1.0);

  /// Процент усечением до одной цифры: `11365` -> «113,6» (spec 6.2).
  String get percentText => basisPointsText(progressBp);
}

/// `progress_bp` как процент усечением до одной цифры после запятой:
/// `11365` -> «113,6», `7030` -> «70,3», `5` -> «0,0». Только целые числа.
String basisPointsText(int bp) {
  final safe = bp < 0 ? 0 : bp;
  return '${safe ~/ 100},${safe % 100 ~/ 10}';
}

/// Цель вместе с прогрессом.
@immutable
class GoalState {
  const GoalState({required this.goal, required this.progress});

  final Goal goal;
  final GoalProgress progress;
}

/// Все цели с прогрессом: активные и архивные отдельно.
@immutable
class GoalsOverview {
  const GoalsOverview(this.goals);

  /// Считает прогресс каждой цели по **видимым** строкам (spec 2) и данным
  /// Работы [work] (по умолчанию пустым).
  factory GoalsOverview.compute({
    required List<Json> goals,
    required List<Json> accounts,
    required List<Json> transactions,
    required List<Json> checkpoints,
    required List<Json> debts,
    required List<Json> repayments,
    WorkData work = const WorkData.empty(),
  }) {
    final states = <GoalState>[];
    for (final row in goals) {
      final goal = Goal.fromRow(row);
      final result = goalProgress(
        goal.toRow(),
        accounts,
        transactions,
        checkpoints,
        debts,
        repayments,
        work.projects,
        work.changeRequests,
        work.allocations,
      );
      states.add(
        GoalState(
          goal: goal,
          progress: GoalProgress.fromJson(result, goal.formula),
        ),
      );
    }
    return GoalsOverview(states);
  }

  /// В порядке создания.
  final List<GoalState> goals;

  bool get isEmpty => goals.isEmpty;

  /// Не архивные: ближайший срок выше, затем без срока; при равных — по
  /// порядку создания.
  List<GoalState> get active => _sorted([
    for (final s in goals)
      if (!s.goal.archived) s,
  ]);

  List<GoalState> get archived => [
    for (final s in goals)
      if (s.goal.archived) s,
  ];

  GoalState? byId(String id) {
    for (final s in goals) {
      if (s.goal.id == id) return s;
    }
    return null;
  }

  static List<GoalState> _sorted(List<GoalState> list) {
    final indexed = list.indexed.toList()
      ..sort((a, b) {
        final da = a.$2.goal.deadlineDate;
        final db = b.$2.goal.deadlineDate;
        if ((da == null) != (db == null)) return da == null ? 1 : -1;
        final byDeadline = (da ?? '').compareTo(db ?? '');
        return byDeadline != 0 ? byDeadline : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }
}

/// Счета, которые формула учитывает дважды: они есть и в слагаемом
/// `accounts`, и в общем балансе слагаемого `all_accounts` (счёт с флагом
/// «в общем балансе»). Конструктор формулы предупреждает об этом
/// (spec 6.2); пустое множество — пересечения нет.
Set<String> formulaOverlap(List<GoalTerm> terms, Iterable<Account> accounts) {
  if (!terms.any((t) => t.kind == GoalTermKind.allAccounts)) return const {};
  final inTotal = {
    for (final a in accounts)
      if (a.includeInTotal) a.id,
  };
  return {
    for (final t in terms)
      if (t.kind == GoalTermKind.accounts)
        for (final id in t.accountIds ?? const <String>[])
          if (inTotal.contains(id)) id,
  };
}
