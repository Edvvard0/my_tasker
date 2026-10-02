import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/local_llm/device_resources.dart';
import 'package:my_tasker/core/local_llm/local_benchmark.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';

import '../../support/fake_llm.dart';

const _stats = LlmRuntimeStats(
  outputTokens: 10,
  timeToFirstTokenMs: 400,
  tokensPerSecond: 8,
);

/// Правильные аргументы по ожиданиям фразы.
Map<String, Object?> _right(BenchmarkPrompt p) => {
  'title': 'Задача ${p.id}',
  for (final e in p.expected.entries)
    if (e.value.first != null) e.key: e.value.first,
};

LocalBenchmarkRunner _runner(FakeLlmEngine engine, FakeResources resources) {
  var t = 0;
  return LocalBenchmarkRunner(
    engine: engine,
    resources: resources,
    zone: requireLocation('Europe/Moscow'),
    modelLabel: 'Тестовая модель',
    nowMicros: () => t += 1000,
    now: () => DateTime.utc(2026, 10, 2, 12),
  );
}

void main() {
  setUpAll(ensureTimeZones);

  test('набор фраз: 20 штук, из них 10 на задачу, id уникальны', () {
    expect(benchmarkPrompts.length, 20);
    expect(benchmarkPrompts.where((p) => p.isTask).length, 10);
    expect({for (final p in benchmarkPrompts) p.id}.length, 20);
    // Все ожидаемые даты — настоящие.
    for (final p in benchmarkPrompts) {
      final date = p.expected['due_date']?.first;
      if (date != null) expect(parseDate('$date'), isNotNull, reason: p.text);
    }
    // «Сейчас» замеров — понедельник 5 октября 2026, 10:00 по Москве.
    final wall = utcToWall(requireLocation('Europe/Moscow'), benchmarkNowUtc);
    expect((wall.year, wall.month, wall.day, wall.hour), (2026, 10, 5, 10));
    expect(wall.weekday, DateTime.monday);
  });

  test(
    'полный прогон: метрики JSON, повтор, ложные вызовы, русский язык',
    () async {
      final engine = FakeLlmEngine()..markLoaded();
      final resources = FakeResources(
        thermalValue: const ThermalSample(
          maxCelsius: 41.5,
          source: 'thermal_zone3',
        ),
      );
      for (final p in benchmarkPrompts) {
        if (p.isTask) {
          switch (p.id) {
            case 3: // мусор, затем верно: «после повтора»
              engine.replies
                ..add(FakeReply.truncatedJson())
                ..add(FakeReply.task(_right(p)));
            case 5: // JSON корректный, но дата неверная
              engine.replies.add(
                FakeReply.task({..._right(p), 'due_date': '2026-10-01'}),
              );
            case 8: // мусор дважды: JSON так и не получен
              engine.replies
                ..add(FakeReply.truncatedJson())
                ..add(FakeReply.truncatedJson());
            default:
              engine.replies.add(FakeReply.task(_right(p)));
          }
        } else {
          switch (p.id) {
            case 12:
              engine.replies.add(
                FakeReply(['Просрочен счёт заказчику.'], stats: _stats),
              );
            case 13: // ложный вызов инструмента на обычный вопрос
              engine.replies.add(FakeReply.task({'title': 'Встречи'}));
            case 15: // ответ не по-русски
              engine.replies.add(FakeReply(['Plan the morning carefully']));
            case 20:
              engine.replies.add(FakeReply(['Будет ', '391.'], stats: _stats));
            default:
              engine.replies.add(
                FakeReply(['Ответ ', 'на ', 'вопрос'], stats: _stats),
              );
          }
        }
      }

      final progress = <int>[];
      final report = await _runner(
        engine,
        resources,
      ).run(onProgress: (done, total, _) => progress.add(done));

      expect(progress, List.generate(20, (i) => i + 1));
      expect(report.items.length, 20);
      expect(report.cancelled, isFalse);
      expect(report.errors, 0);
      // Первая попытка: задачи 1,2,4,5,6,7,9,10 = 8 из 10.
      expect(report.validJsonRate, 0.8);
      // После повтора добавляется задача 3: 9 из 10.
      expect(report.validAfterRetryRate, 0.9);
      // Поля верны у 1,2,3,4,6,7,9,10 (у 5 дата не та, у 8 JSON нет).
      expect(report.fieldsOkRate, 0.8);
      expect(report.falseToolCalls, 1);

      final byId = {for (final i in report.items) i.prompt.id: i};
      expect(byId[3]!.validJson, isFalse);
      expect(byId[3]!.validAfterRetry, isTrue);
      expect(byId[5]!.validJson, isTrue);
      expect(byId[5]!.fieldsOk, isFalse);
      expect(byId[8]!.validJson || byId[8]!.validAfterRetry, isFalse);
      expect(byId[6]!.fieldsOk, isTrue, reason: 'проект Дом и без срока');
      expect(byId[12]!.contentOk, isTrue);
      expect(byId[13]!.falseToolCall, isTrue);
      expect(byId[15]!.russian, isFalse);
      expect(byId[20]!.contentOk, isTrue);
      expect(byId[11]!.contentOk, isTrue);

      expect(report.meanTokensPerSecond, greaterThan(0));
      expect(report.medianFirstTokenMs, isNotNull);
      expect(report.peakRssBytes, resources.peak);
      expect(report.rssBeforeBytes, resources.rss);
      expect(report.backend, 'cpu');
      expect(report.modelLabel, 'Тестовая модель');

      final text = report.toText();
      for (final needle in [
        'Тест локальной модели',
        'Модель: Тестовая модель, бэкенд: cpu',
        'Фраз: 20, ошибок: 0',
        'Валидный JSON (первая попытка): 80%',
        'Валидный JSON (после повтора): 90%',
        'Верные поля задачи: 80%',
        'Ложные вызовы инструмента на обычных вопросах: 1',
        'ток/с',
        '41.5 °C (thermal_zone3)',
        'пик 3072 МБ',
        '3. ',
        'json после повтора',
        'ложный вызов инструмента',
        'не по-русски',
      ]) {
        expect(text, contains(needle));
      }
      expect(text.split('\n').length, greaterThan(30));
    },
  );

  test(
    'запрос собран как в чате: правила, «сейчас», контекст, бюджет',
    () async {
      final engine = FakeLlmEngine()..markLoaded();
      await _runner(
        engine,
        FakeResources(),
      ).run(prompts: [benchmarkPrompts.first]);
      final turns = engine.requests.single;
      expect(
        turns.first.text,
        contains('Сейчас: 2026-10-05, понедельник, 10:00'),
      );
      expect(turns.first.text, contains('create_task'));
      expect(turns.first.text, contains('Подготовить смету'));
      expect(turns.last.text, benchmarkPrompts.first.text);
    },
  );

  test('отмена: прогон прерывается, отчёт помечен', () async {
    final engine = FakeLlmEngine()..markLoaded();
    final cancel = BenchmarkCancel();
    final report = await _runner(engine, FakeResources()).run(
      cancel: cancel,
      onProgress: (done, _, _) {
        if (done == 3) cancel.cancel();
      },
    );
    expect(report.items.length, 3);
    expect(report.cancelled, isTrue);
    expect(report.toText(), contains('(прерван)'));
  });

  test('сбой на одной фразе: отмечается, прогон продолжается', () async {
    final engine = FakeLlmEngine()..markLoaded();
    engine.replies
      ..add(
        FakeReply(
          ['x'],
          failAfter: 0,
          failWith: const LocalLlmException(
            LocalLlmErrorKind.outOfMemory,
            'Не хватило памяти',
          ),
        ),
      )
      ..add(FakeReply.task({'title': 'Т'}));
    final report = await _runner(
      engine,
      FakeResources(),
    ).run(prompts: benchmarkPrompts.take(2).toList());
    expect(report.errors, 1);
    expect(report.items.first.error, 'Не хватило памяти');
    expect(report.items.last.validJson, isTrue);
    expect(report.toText(), contains('ошибка: Не хватило памяти'));
  });

  test(
    'скорость считается по токенам, если рантайм метрик не отдаёт',
    () async {
      final engine = FakeLlmEngine()..markLoaded();
      engine.replies.add(FakeReply(List.filled(10, 'т ')));
      final report = await _runner(
        engine,
        FakeResources(),
      ).run(prompts: [benchmarkPrompts[10]]);
      final item = report.items.single;
      expect(item.outputTokens, 10);
      expect(item.firstTokenMs, greaterThan(0));
      expect(item.tokensPerSecond, greaterThan(0));
    },
  );

  test('перцентили и пустой отчёт', () {
    BenchmarkItemResult item(int id, double? ttft, double? tps) =>
        BenchmarkItemResult(
          prompt: BenchmarkPrompt(id: id, text: 'x'),
          reply: '',
          totalMs: 1,
          outputTokens: 1,
          firstTokenMs: ttft,
          tokensPerSecond: tps,
        );
    final report = BenchmarkReport(
      items: [
        for (var i = 1; i <= 20; i++) item(i, i * 100.0, i.toDouble()),
        item(21, null, null),
      ],
      modelLabel: 'м',
      startedAt: DateTime.utc(2026),
      totalMs: 1000,
    );
    expect(report.meanFirstTokenMs, 1050);
    expect(report.medianFirstTokenMs, 1000);
    expect(report.p95FirstTokenMs, 1900);
    expect(report.meanTokensPerSecond, 10.5);
    expect(report.validJsonRate, 0);

    final empty = BenchmarkReport(
      items: const [],
      modelLabel: 'м',
      startedAt: DateTime.utc(2026),
      totalMs: 0,
    );
    expect(empty.meanFirstTokenMs, isNull);
    expect(empty.p95FirstTokenMs, isNull);
    expect(empty.meanTokensPerSecond, isNull);
    expect(empty.fieldsOkRate, 0);
    expect(empty.validAfterRetryRate, 0);
    expect(empty.toText(), contains('—'));
    expect(empty.toText(), contains('недоступно'));
  });
}
