import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';

/// Грубая оценка числа токенов русского текста для Gemma: ~2,5 знака на
/// токен (с запасом; облачная оценка — 3 знака). Точные значения даёт
/// рантайм (метрики на экране замеров); бюджет специально консервативен,
/// потому что переполнение контекста на телефоне — это сбой, а не обрезка.
int estimateLocalTokens(String text) => (text.length / 2.5).ceil();

/// Накладные расходы на служебные токены одной реплики (`<start_of_turn>`...).
const int turnOverheadTokens = 6;

/// Итог подгонки запроса под бюджет.
@immutable
class BudgetedPrompt {
  const BudgetedPrompt({
    required this.turns,
    required this.estimatedInputTokens,
    required this.droppedHistoryTurns,
    required this.contextTrimmed,
    required this.userTruncated,
  });

  /// Реплики запроса: система, история, последний вопрос пользователя.
  final List<LlmTurn> turns;
  final int estimatedInputTokens;

  /// Сколько самых старых реплик истории не поместилось.
  final int droppedHistoryTurns;

  /// Блок контекста приложения пришлось сократить.
  final bool contextTrimmed;

  /// Сообщение пользователя было слишком длинным и обрезано.
  final bool userTruncated;
}

/// Жёсткий бюджет токенов локального запроса (решение этапа 10, п. 5:
/// контекст приложения ≈ 1500 токенов).
///
/// Окно модели делится так: `[вход: система + контекст + история + вопрос]
/// [запас под ответ] [страховка]`. Порядок вытеснения при нехватке: сначала
/// самая старая история, затем контекст приложения, и только потом режется
/// сам вопрос.
class TokenBudget {
  const TokenBudget({
    this.contextTokens = 4096,
    this.reserveOutputTokens = 512,
    this.appContextTokens = 1500,
    this.safetyTokens = 96,
    this.estimate = estimateLocalTokens,
  });

  /// Окно модели (вход + выход).
  final int contextTokens;

  /// Резерв под ответ.
  final int reserveOutputTokens;

  /// Потолок блока данных приложения (задачи, расписание).
  final int appContextTokens;
  final int safetyTokens;
  final int Function(String text) estimate;

  /// Сколько токенов можно потратить на вход.
  int get inputBudget => contextTokens - reserveOutputTokens - safetyTokens;

  int _turnCost(String text) => estimate(text) + turnOverheadTokens;

  /// Обрезает блок контекста по строкам до [limit] токенов; возвращает
  /// текст и признак сокращения.
  (String, bool) fitContext(String contextText, int limit) {
    if (contextText.isEmpty || limit <= 0) {
      return ('', contextText.isNotEmpty);
    }
    if (estimate(contextText) <= limit) return (contextText, false);
    const marker = '… (остальное не поместилось)';
    final kept = StringBuffer();
    var used = estimate(marker);
    for (final line in contextText.split('\n')) {
      final cost = estimate('$line\n');
      if (used + cost > limit) break;
      kept.writeln(line);
      used += cost;
    }
    final text = kept.toString().trimRight();
    return (text.isEmpty ? '' : '$text\n$marker', true);
  }

  /// Собирает запрос: [system] — системная часть (агент, «сейчас», правила
  /// инструмента), [contextText] — данные приложения, [history] — прежние
  /// реплики (по порядку), [userMessage] — текущий вопрос.
  BudgetedPrompt fit({
    required String system,
    required List<LlmTurn> history,
    required String userMessage,
    String contextText = '',
  }) {
    var user = userMessage;
    var userTruncated = false;
    final systemCost = _turnCost(system);
    var userCost = _turnCost(user);

    // Вопрос не должен съесть всё окно: ему не больше половины входа.
    final userCap = inputBudget ~/ 2;
    if (userCost > userCap) {
      var keepChars = (user.length * userCap / userCost).floor().clamp(
        1,
        user.length,
      );
      var cut = '${user.substring(0, keepChars)}…';
      while (keepChars > 1 && _turnCost(cut) > userCap) {
        keepChars = (keepChars * 0.9).floor();
        cut = '${user.substring(0, keepChars)}…';
      }
      user = cut;
      userTruncated = true;
      userCost = _turnCost(user);
    }

    final mandatory = systemCost + userCost;
    var contextLimit = appContextTokens;
    final room = inputBudget - mandatory;
    if (contextLimit > room) contextLimit = room;
    final (fittedContext, contextTrimmed) = fitContext(
      contextText,
      contextLimit,
    );

    final systemText = fittedContext.isEmpty
        ? system
        : '$system\n\n$fittedContext';
    var used =
        systemCost +
        userCost +
        (fittedContext.isEmpty ? 0 : estimate('\n\n$fittedContext'));

    // История: с конца, пока помещается.
    final kept = <LlmTurn>[];
    for (final turn in history.reversed) {
      final cost = _turnCost(turn.text);
      if (used + cost > inputBudget) break;
      kept.insert(0, turn);
      used += cost;
    }
    // Диалог начинается с реплики пользователя (шаблонам нужно чередование).
    while (kept.isNotEmpty && kept.first.role != LlmRole.user) {
      used -= _turnCost(kept.first.text);
      kept.removeAt(0);
    }
    final dropped = history.length - kept.length;
    // Две реплики пользователя подряд (результат инструмента + новый вопрос)
    // склеиваются: шаблоны требуют чередования ролей.
    final tail = kept.isNotEmpty && kept.last.role == LlmRole.user
        ? kept.removeLast()
        : null;
    return BudgetedPrompt(
      turns: [
        LlmTurn.system(systemText),
        ...kept,
        LlmTurn.user(tail == null ? user : '${tail.text}\n\n$user'),
      ],
      estimatedInputTokens: used,
      droppedHistoryTurns: dropped,
      contextTrimmed: contextTrimmed,
      userTruncated: userTruncated,
    );
  }
}
