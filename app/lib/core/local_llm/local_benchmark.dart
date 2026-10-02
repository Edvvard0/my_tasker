import 'dart:async';

import 'package:my_tasker/core/local_llm/create_task_parser.dart';
import 'package:my_tasker/core/local_llm/device_resources.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';
import 'package:my_tasker/core/local_llm/local_prompts.dart';
import 'package:my_tasker/core/local_llm/token_budget.dart';
import 'package:timezone/timezone.dart' as tz;

/// «Сейчас» для замеров: понедельник, 5 октября 2026, 10:00 по Москве.
/// Фиксировано, чтобы относительные даты («завтра», «в пятницу») имели
/// проверяемый правильный ответ и прогоны были сравнимы.
final DateTime benchmarkNowUtc = DateTime.utc(2026, 10, 5, 7);

/// Фиксированный блок «данных приложения» для замеров (≈ 250 токенов): вопросы
/// про расписание всегда получают один и тот же контекст.
const String benchmarkContext =
    '# Данные пользователя из приложения (собраны на устройстве)\n\n'
    '## Задачи (на 7 дней и просроченные)\n'
    '- Отправить счёт заказчику · срок 2026-10-03 (просрочено) · P1 · '
    'к выполнению · проект «Creora»\n'
    '- Подготовить смету · срок 2026-10-05 15:00 · P2 · к выполнению\n'
    '- Оплатить интернет · срок 2026-10-05 · P3 · к выполнению\n'
    '- Купить подарок · срок 2026-10-08 · P3 · к выполнению\n'
    '- Записаться к врачу · срок 2026-10-09 · P2 · к выполнению\n\n'
    '## Расписание (на 3 дн.)\n'
    '- 2026-10-05 11:00–12:00 · Планёрка (Работа)\n'
    '- 2026-10-06 09:30–10:30 · Лекция по статистике (Учёба)\n'
    '- 2026-10-06 19:00–20:00 · Тренировка\n'
    '- 2026-10-07 весь день · День рождения Ани';

/// Одна фраза набора замеров.
class BenchmarkPrompt {
  const BenchmarkPrompt({
    required this.id,
    required this.text,
    this.isTask = false,
    this.expected = const {},
    this.containsAny = const [],
  });

  final int id;
  final String text;

  /// Фраза просит создать задачу (проверяем JSON).
  final bool isTask;

  /// Ожидаемые поля аргументов: `поле -> допустимые значения`;
  /// значение `null` в списке означает «поля быть не должно».
  final Map<String, List<Object?>> expected;

  /// Для обычных вопросов: ответ должен содержать одну из подстрок.
  final List<String> containsAny;
}

/// 20 фиксированных русских фраз: 10 на создание задачи, 10 обычных.
const List<BenchmarkPrompt> benchmarkPrompts = [
  BenchmarkPrompt(
    id: 1,
    text: 'Добавь задачу: купить молоко завтра',
    isTask: true,
    expected: {
      'due_date': ['2026-10-06'],
    },
  ),
  BenchmarkPrompt(
    id: 2,
    text: 'Напомни позвонить маме в пятницу в 18:30',
    isTask: true,
    expected: {
      'due_date': ['2026-10-09'],
      'due_time': ['18:30'],
    },
  ),
  BenchmarkPrompt(
    id: 3,
    text:
        'Создай задачу сдать отчёт по проекту Creora до 15 октября, '
        'приоритет высокий',
    isTask: true,
    expected: {
      'due_date': ['2026-10-15'],
      'priority': [1, 2],
    },
  ),
  BenchmarkPrompt(
    id: 4,
    text: 'Запланируй стоматолога послезавтра в 9 утра на 45 минут',
    isTask: true,
    expected: {
      'due_date': ['2026-10-07'],
      'due_time': ['09:00'],
      'duration_minutes': [45],
    },
  ),
  BenchmarkPrompt(
    id: 5,
    text: 'Задача: оплатить интернет сегодня, приоритет 2',
    isTask: true,
    expected: {
      'due_date': ['2026-10-05'],
      'priority': [2],
    },
  ),
  BenchmarkPrompt(
    id: 6,
    text: 'Добавь в проект Дом задачу починить кран, без срока',
    isTask: true,
    expected: {
      'project': ['Дом'],
      'due_date': [null],
    },
  ),
  BenchmarkPrompt(
    id: 7,
    text: 'Поставь задачу подготовить презентацию в субботу в 12:00',
    isTask: true,
    expected: {
      'due_date': ['2026-10-10'],
      'due_time': ['12:00'],
    },
  ),
  BenchmarkPrompt(
    id: 8,
    text: 'Создай задачу прочитать главу 3 с тегами учёба и книги',
    isTask: true,
  ),
  BenchmarkPrompt(
    id: 9,
    text: 'Добавь задачу через неделю записаться на ТО машины',
    isTask: true,
    expected: {
      'due_date': ['2026-10-12'],
    },
  ),
  BenchmarkPrompt(
    id: 10,
    text: 'Напомни завтра в 8:15 выпить таблетки',
    isTask: true,
    expected: {
      'due_date': ['2026-10-06'],
      'due_time': ['08:15'],
    },
  ),
  BenchmarkPrompt(id: 11, text: 'Что у меня сегодня по задачам?'),
  BenchmarkPrompt(
    id: 12,
    text: 'Какие задачи просрочены?',
    containsAny: ['счёт', 'счет'],
  ),
  BenchmarkPrompt(id: 13, text: 'Сколько у меня встреч завтра?'),
  BenchmarkPrompt(id: 14, text: 'Что у меня на ближайшие три дня?'),
  BenchmarkPrompt(
    id: 15,
    text: 'Как лучше распланировать утро, если у меня две важные задачи?',
  ),
  BenchmarkPrompt(
    id: 16,
    text: 'Объясни простыми словами, что такое матрица Эйзенхауэра.',
  ),
  BenchmarkPrompt(
    id: 17,
    text: 'Составь короткий план подготовки к экзамену на 3 дня.',
  ),
  BenchmarkPrompt(
    id: 18,
    text: 'Придумай три названия для проекта по ремонту квартиры.',
  ),
  BenchmarkPrompt(
    id: 19,
    text: 'Перефразируй: нужно срочно сделать отчёт, пока не ушёл начальник.',
  ),
  BenchmarkPrompt(
    id: 20,
    text: 'Сколько будет 17 умножить на 23?',
    containsAny: ['391'],
  ),
];

/// Результат по одной фразе.
class BenchmarkItemResult {
  const BenchmarkItemResult({
    required this.prompt,
    required this.reply,
    required this.totalMs,
    required this.outputTokens,
    this.firstTokenMs,
    this.tokensPerSecond,
    this.validJson = false,
    this.validAfterRetry = false,
    this.fieldsOk = false,
    this.falseToolCall = false,
    this.russian = true,
    this.contentOk = true,
    this.error,
    this.peakRssBytes,
  });

  final BenchmarkPrompt prompt;
  final String reply;
  final int totalMs;
  final int outputTokens;

  /// Время до первого токена; `null`, если токенов не было.
  final double? firstTokenMs;

  /// Скорость генерации после первого токена.
  final double? tokensPerSecond;

  /// Фраза на задачу: JSON с первой попытки прошёл разбор и проверку.
  final bool validJson;

  /// Прошёл только после единственного повтора.
  final bool validAfterRetry;

  /// Проверяемые поля совпали с ожидаемыми.
  final bool fieldsOk;

  /// Обычный вопрос, а модель вернула вызов инструмента.
  final bool falseToolCall;

  /// Ответ в основном кириллицей.
  final bool russian;
  final bool contentOk;
  final String? error;
  final int? peakRssBytes;
}

/// Сводка прогона.
class BenchmarkReport {
  const BenchmarkReport({
    required this.items,
    required this.modelLabel,
    required this.startedAt,
    required this.totalMs,
    this.backend,
    this.thermalBefore,
    this.thermalAfter,
    this.peakRssBytes,
    this.rssBeforeBytes,
    this.cancelled = false,
  });

  final List<BenchmarkItemResult> items;
  final String modelLabel;
  final String? backend;
  final DateTime startedAt;
  final int totalMs;
  final ThermalSample? thermalBefore;
  final ThermalSample? thermalAfter;
  final int? peakRssBytes;
  final int? rssBeforeBytes;
  final bool cancelled;

  Iterable<BenchmarkItemResult> get _tasks =>
      items.where((i) => i.prompt.isTask);
  Iterable<BenchmarkItemResult> get _general =>
      items.where((i) => !i.prompt.isTask);

  int get errors => items.where((i) => i.error != null).length;

  /// Доля задач с валидным JSON с первой попытки (0..1).
  double get validJsonRate {
    final tasks = _tasks.toList();
    if (tasks.isEmpty) return 0;
    return tasks.where((i) => i.validJson).length / tasks.length;
  }

  /// Доля задач с валидным JSON после одного повтора (как в продукте).
  double get validAfterRetryRate {
    final tasks = _tasks.toList();
    if (tasks.isEmpty) return 0;
    return tasks.where((i) => i.validJson || i.validAfterRetry).length /
        tasks.length;
  }

  /// Доля задач, где проверяемые поля (даты, время, приоритет) верны.
  double get fieldsOkRate {
    final tasks = _tasks.toList();
    if (tasks.isEmpty) return 0;
    return tasks.where((i) => i.fieldsOk).length / tasks.length;
  }

  /// Обычные вопросы, на которые модель ответила вызовом инструмента.
  int get falseToolCalls => _general.where((i) => i.falseToolCall).length;

  List<double> get _firstTokens => [
    for (final i in items)
      if (i.firstTokenMs != null) i.firstTokenMs!,
  ]..sort();

  double? get meanFirstTokenMs => _mean(_firstTokens);

  double? get medianFirstTokenMs => _percentile(_firstTokens, 0.5);

  double? get p95FirstTokenMs => _percentile(_firstTokens, 0.95);

  double? get meanTokensPerSecond => _mean([
    for (final i in items)
      if (i.tokensPerSecond != null) i.tokensPerSecond!,
  ]);

  static double? _mean(List<double> values) =>
      values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;

  /// Перцентиль по ближайшему рангу (список отсортирован).
  static double? _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return null;
    final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  String _mb(int? bytes) =>
      bytes == null ? '—' : '${(bytes / (1024 * 1024)).round()} МБ';

  String _ms(double? value) => value == null ? '—' : '${value.round()} мс';

  String _pct(double value) => '${(value * 100).round()}%';

  String _thermal(ThermalSample? t) => t == null
      ? 'недоступно'
      : '${t.maxCelsius.toStringAsFixed(1)} °C (${t.source})';

  /// Текст для копирования (отправить разработчику).
  String toText() {
    final tps = meanTokensPerSecond;
    final lines = <String>[
      'Тест локальной модели${cancelled ? ' (прерван)' : ''}',
      'Модель: $modelLabel${backend == null ? '' : ', бэкенд: $backend'}',
      'Начало: ${startedAt.toUtc().toIso8601String()}',
      'Фраз: ${items.length}, ошибок: $errors, всего: ${(totalMs / 1000).toStringAsFixed(1)} с',
      'Время до первого токена: среднее ${_ms(meanFirstTokenMs)}, медиана ${_ms(medianFirstTokenMs)}, p95 ${_ms(p95FirstTokenMs)}',
      'Скорость генерации: ${tps == null ? '—' : '${tps.toStringAsFixed(1)} ток/с'}',
      'Память процесса: до ${_mb(rssBeforeBytes)}, пик ${_mb(peakRssBytes)}',
      'Температура: до ${_thermal(thermalBefore)}, после ${_thermal(thermalAfter)}',
      'Валидный JSON (первая попытка): ${_pct(validJsonRate)}',
      'Валидный JSON (после повтора): ${_pct(validAfterRetryRate)}',
      'Верные поля задачи: ${_pct(fieldsOkRate)}',
      'Ложные вызовы инструмента на обычных вопросах: $falseToolCalls',
      '',
      'По фразам (№, первый токен, ток/с, итог):',
    ];
    for (final i in items) {
      final verdict = i.error != null
          ? 'ошибка: ${i.error}'
          : i.prompt.isTask
          ? (i.validJson
                ? 'json ok${i.fieldsOk ? '' : ', поля неверны'}'
                : i.validAfterRetry
                ? 'json после повтора${i.fieldsOk ? '' : ', поля неверны'}'
                : 'json не получен')
          : [
              if (i.falseToolCall) 'ложный вызов инструмента',
              if (!i.russian) 'не по-русски',
              if (!i.contentOk) 'ответ не по существу',
              if (!i.falseToolCall && i.russian && i.contentOk) 'ok',
            ].join(', ');
      lines.add(
        '${i.prompt.id}. ${_ms(i.firstTokenMs)}, '
        '${i.tokensPerSecond?.toStringAsFixed(1) ?? '—'}, $verdict',
      );
    }
    return lines.join('\n');
  }
}

/// Остановка прогона замеров.
class BenchmarkCancel {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Прогоняет набор [benchmarkPrompts] через движок и считает метрики
/// (решение этапа 10, п. 9). Запрос собирается так же, как в чате: системная
/// часть с правилами `create_task`, фиксированный контекст, бюджет токенов.
class LocalBenchmarkRunner {
  LocalBenchmarkRunner({
    required this.engine,
    required this.resources,
    required this.zone,
    this.modelLabel = '',
    this.params = const LlmGenerationParams(),
    this.budget,
    int Function()? nowMicros,
    DateTime Function()? now,
  }) : _micros = nowMicros ?? (() => DateTime.now().microsecondsSinceEpoch),
       _now = now ?? DateTime.now;

  final LocalLlmEngine engine;
  final DeviceResources resources;
  final tz.Location zone;
  final String modelLabel;
  final LlmGenerationParams params;
  final TokenBudget? budget;
  final int Function() _micros;
  final DateTime Function() _now;

  /// Прогон. [onProgress] вызывается после каждой фразы.
  Future<BenchmarkReport> run({
    BenchmarkCancel? cancel,
    void Function(int done, int total, BenchmarkItemResult result)? onProgress,
    List<BenchmarkPrompt> prompts = benchmarkPrompts,
  }) async {
    final started = _now();
    final startMicros = _micros();
    final rssBefore = await resources.currentRssBytes();
    final thermalBefore = await resources.thermal();
    final effective =
        budget ??
        TokenBudget(
          contextTokens: engine.loadedModel?.contextTokens ?? 4096,
          reserveOutputTokens: params.maxOutputTokens,
        );
    final items = <BenchmarkItemResult>[];
    var cancelled = false;
    for (final prompt in prompts) {
      if (cancel?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      final result = await _runOne(prompt, effective);
      items.add(result);
      onProgress?.call(items.length, prompts.length, result);
    }
    if (cancel?.isCancelled ?? false) cancelled = true;
    final model = engine.loadedModel;
    return BenchmarkReport(
      items: items,
      modelLabel: modelLabel.isEmpty ? (model?.modelId ?? '') : modelLabel,
      backend: model?.backend,
      startedAt: started,
      totalMs: (_micros() - startMicros) ~/ 1000,
      thermalBefore: thermalBefore,
      thermalAfter: await resources.thermal(),
      peakRssBytes: await resources.peakRssBytes(),
      rssBeforeBytes: rssBefore,
      cancelled: cancelled,
    );
  }

  Future<({String text, double? ttftMs, double? tps, int tokens})> _generate(
    List<LlmTurn> turns,
  ) async {
    final begin = _micros();
    int? first;
    var chunks = 0;
    final buffer = StringBuffer();
    await for (final token in engine.generate(turns, params)) {
      first ??= _micros();
      chunks++;
      buffer.write(token);
    }
    final end = _micros();
    final stats = engine.lastStats;
    final tokens = stats?.outputTokens ?? chunks;
    final ttft =
        stats?.timeToFirstTokenMs ??
        (first == null ? null : (first - begin) / 1000);
    var tps = stats?.tokensPerSecond;
    if (tps == null && first != null && tokens > 1 && end > first) {
      tps = (tokens - 1) / ((end - first) / 1e6);
    }
    return (text: buffer.toString(), ttftMs: ttft, tps: tps, tokens: tokens);
  }

  Future<BenchmarkItemResult> _runOne(
    BenchmarkPrompt prompt,
    TokenBudget effective,
  ) async {
    final begin = _micros();
    try {
      final system = buildLocalSystemPrompt(
        nowUtc: benchmarkNowUtc,
        zone: zone,
      );
      final fitted = effective.fit(
        system: system,
        history: const [],
        userMessage: prompt.text,
        contextText: benchmarkContext,
      );
      final first = await _generate(fitted.turns);
      var tokens = first.tokens;
      var text = first.text;
      final parsed = parseCreateTaskReply(first.text);
      var validJson = false;
      var afterRetry = false;
      Map<String, Object?>? arguments;
      var falseTool = false;
      if (prompt.isTask) {
        if (parsed is ParsedToolCall) {
          validJson = true;
          arguments = parsed.arguments;
        } else if (parsed is InvalidToolCall) {
          final retry = await _generate([
            ...fitted.turns,
            LlmTurn.model(
              first.text.length > 800
                  ? first.text.substring(0, 800)
                  : first.text,
            ),
            LlmTurn.user(createTaskRetryHint(parsed.problems)),
          ]);
          tokens += retry.tokens;
          text = retry.text;
          final again = parseCreateTaskReply(retry.text);
          if (again is ParsedToolCall) {
            afterRetry = true;
            arguments = again.arguments;
          }
        }
      } else {
        falseTool = parsed is! NoToolCall;
      }
      final lower = text.toLowerCase();
      return BenchmarkItemResult(
        prompt: prompt,
        reply: text,
        totalMs: (_micros() - begin) ~/ 1000,
        outputTokens: tokens,
        firstTokenMs: first.ttftMs,
        tokensPerSecond: first.tps,
        validJson: validJson,
        validAfterRetry: afterRetry,
        fieldsOk:
            prompt.isTask &&
            arguments != null &&
            _fieldsMatch(prompt.expected, arguments),
        falseToolCall: falseTool,
        russian: _mostlyCyrillic(prompt.isTask ? '' : text),
        contentOk:
            prompt.containsAny.isEmpty ||
            prompt.containsAny.any((s) => lower.contains(s.toLowerCase())),
        peakRssBytes: await resources.peakRssBytes(),
      );
    } on Object catch (e) {
      return BenchmarkItemResult(
        prompt: prompt,
        reply: '',
        totalMs: (_micros() - begin) ~/ 1000,
        outputTokens: 0,
        error: e is LocalLlmException ? e.message : '$e',
      );
    }
  }

  static bool _fieldsMatch(
    Map<String, List<Object?>> expected,
    Map<String, Object?> arguments,
  ) {
    for (final entry in expected.entries) {
      if (!entry.value.contains(arguments[entry.key])) return false;
    }
    return true;
  }

  /// Не менее половины букв — кириллица (для коротких ответов без букв —
  /// считается русским).
  static bool _mostlyCyrillic(String text) {
    var cyr = 0;
    var latin = 0;
    for (final unit in text.runes) {
      if (unit >= 0x0400 && unit <= 0x04FF) {
        cyr++;
      } else if ((unit >= 0x41 && unit <= 0x5A) ||
          (unit >= 0x61 && unit <= 0x7A)) {
        latin++;
      }
    }
    if (cyr + latin == 0) return true;
    return cyr / (cyr + latin) >= 0.5;
  }
}
