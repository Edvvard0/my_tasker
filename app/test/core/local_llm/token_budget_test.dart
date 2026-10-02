import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';
import 'package:my_tasker/core/local_llm/token_budget.dart';

/// Оценка «1 знак = 1 токен»: арифметика бюджета в тестах прозрачна.
int _chars(String s) => s.length;

TokenBudget _budget({int window = 1000, int reserve = 200, int app = 300}) =>
    TokenBudget(
      contextTokens: window,
      reserveOutputTokens: reserve,
      appContextTokens: app,
      safetyTokens: 0,
      estimate: _chars,
    );

int _cost(String s) => s.length + turnOverheadTokens;

void main() {
  test('оценка русского текста консервативнее облачной (знак/3)', () {
    expect(estimateLocalTokens('а' * 25), 10);
    expect(estimateLocalTokens(''), 0);
  });

  test('всё помещается: запрос целиком, ничего не отброшено', () {
    final b = _budget();
    final p = b.fit(
      system: 'sys',
      history: const [LlmTurn.user('q1'), LlmTurn.model('a1')],
      userMessage: 'вопрос',
      contextText: 'ctx',
    );
    expect(p.droppedHistoryTurns, 0);
    expect(p.contextTrimmed, isFalse);
    expect(p.userTruncated, isFalse);
    expect(p.turns.first.role, LlmRole.system);
    expect(p.turns.first.text, 'sys\n\nctx');
    expect(p.turns.last, const LlmTurn.user('вопрос'));
    expect(p.turns.length, 4);
    expect(p.estimatedInputTokens, lessThanOrEqualTo(b.inputBudget));
  });

  test('контекст приложения режется по строкам до своего лимита', () {
    final b = _budget(app: 60);
    final lines = [for (var i = 0; i < 20; i++) 'строка номер $i'];
    final p = b.fit(
      system: 's',
      history: const [],
      userMessage: 'q',
      contextText: lines.join('\n'),
    );
    expect(p.contextTrimmed, isTrue);
    final system = p.turns.first.text;
    expect(system, contains('строка номер 0'));
    expect(system, isNot(contains('строка номер 19')));
    expect(system, contains('остальное не поместилось'));
    expect(system.length, lessThan(60 + 40));
  });

  test('история вытесняется с начала, последний ход остаётся', () {
    final b = _budget(window: 300, reserve: 100);
    final history = [
      for (var i = 0; i < 10; i++) ...[
        LlmTurn.user('вопрос ${'x' * 30} $i'),
        LlmTurn.model('ответ ${'y' * 30} $i'),
      ],
    ];
    final p = b.fit(system: 'sys', history: history, userMessage: 'новый');
    expect(p.droppedHistoryTurns, greaterThan(0));
    expect(p.turns.last.text, 'новый');
    expect(p.estimatedInputTokens, lessThanOrEqualTo(b.inputBudget));
    // Диалог начинается с реплики пользователя, свежие реплики на месте.
    final dialog = p.turns.sublist(1, p.turns.length - 1);
    expect(dialog.first.role, LlmRole.user);
    expect(dialog.last.text, contains(' 9'));
  });

  test('сначала уходит история, потом контекст, потом режется вопрос', () {
    // Окно почти целиком занято системой и вопросом.
    final b = _budget(window: 400, reserve: 100);
    final p = b.fit(
      system: 's' * 120,
      history: [const LlmTurn.user('старый'), const LlmTurn.model('ответ')],
      userMessage: 'в' * 100,
      contextText: List.generate(30, (i) => 'задача $i').join('\n'),
    );
    expect(p.droppedHistoryTurns, 2);
    expect(p.contextTrimmed, isTrue);
    expect(p.estimatedInputTokens, lessThanOrEqualTo(b.inputBudget));
  });

  test('слишком длинный вопрос обрезается до половины входа', () {
    final b = _budget(window: 600, reserve: 100);
    final p = b.fit(system: 'sys', history: const [], userMessage: 'ы' * 5000);
    expect(p.userTruncated, isTrue);
    expect(p.turns.last.text.endsWith('…'), isTrue);
    expect(_cost(p.turns.last.text), lessThanOrEqualTo(b.inputBudget ~/ 2 + 1));
    expect(p.estimatedInputTokens, lessThanOrEqualTo(b.inputBudget));
  });

  test('нет места под контекст: он пропадает целиком', () {
    final b = _budget(window: 200, reserve: 100);
    final p = b.fit(
      system: 's' * 60,
      history: const [],
      userMessage: 'q' * 20,
      contextText: 'данные\nещё данные',
    );
    expect(p.contextTrimmed, isTrue);
    expect(p.turns.first.text, 's' * 60);
  });

  test('реальные пропорции: контекст ~1500 токенов в окне 4096', () {
    const b = TokenBudget();
    final context = List.generate(
      200,
      (i) => '- задача $i · срок 2026-10-0${i % 9}',
    ).join('\n');
    final p = b.fit(
      system: 'системная часть ' * 40,
      history: const [],
      userMessage: 'Что у меня сегодня?',
      contextText: context,
    );
    expect(p.contextTrimmed, isTrue);
    expect(p.estimatedInputTokens, lessThanOrEqualTo(b.inputBudget));
    // Блок данных не больше потолка 1500 токенов (+ запас на подпись).
    expect(
      estimateLocalTokens(p.turns.first.text),
      lessThanOrEqualTo(
        estimateLocalTokens('системная часть ' * 40) + 1500 + 20,
      ),
    );
  });
}
