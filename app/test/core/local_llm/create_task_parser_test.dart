import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/create_task_parser.dart';

ParsedToolCall _ok(String raw) {
  final result = parseCreateTaskReply(raw);
  expect(result, isA<ParsedToolCall>(), reason: 'ожидали разбор: $raw');
  return result as ParsedToolCall;
}

InvalidToolCall _bad(String raw) {
  final result = parseCreateTaskReply(raw);
  expect(result, isA<InvalidToolCall>(), reason: 'ожидали отказ: $raw');
  return result as InvalidToolCall;
}

NoToolCall _plain(String raw) {
  final result = parseCreateTaskReply(raw);
  expect(result, isA<NoToolCall>(), reason: 'ожидали текст: $raw');
  return result as NoToolCall;
}

String _wrap(String args) => '{"tool":"create_task","arguments":$args}';

void main() {
  group('валидные ответы', () {
    test('1. минимальный: только title', () {
      final r = _ok(_wrap('{"title":"Купить молоко"}'));
      expect(r.arguments, {'title': 'Купить молоко'});
      expect(r.text, isEmpty);
    });

    test('2. все поля схемы', () {
      final r = _ok(
        _wrap(
          '{"title":"Сдать отчёт","notes":"Для Елены","priority":2,"due_date":"2026-10-09","due_time":"18:30","duration_minutes":60,"project":"Creora","tags":["работа","смета"]}',
        ),
      );
      expect(r.arguments, {
        'title': 'Сдать отчёт',
        'notes': 'Для Елены',
        'priority': 2,
        'due_date': '2026-10-09',
        'due_time': '18:30',
        'duration_minutes': 60,
        'project': 'Creora',
        'tags': ['работа', 'смета'],
      });
    });

    test('3. в блоке кода ```json', () {
      final r = _ok('```json\n${_wrap('{"title":"Позвонить"}')}\n```');
      expect(r.arguments['title'], 'Позвонить');
      expect(r.text, isEmpty);
    });

    test('4. текст до и после JSON сохраняется', () {
      final r = _ok('Хорошо, создаю.\n${_wrap('{"title":"Тест"}')}\nГотово!');
      expect(r.arguments['title'], 'Тест');
      expect(r.text, contains('Хорошо, создаю.'));
      expect(r.text, contains('Готово!'));
      expect(r.text, isNot(contains('create_task')));
    });

    test('5. «голый» объект аргументов с title', () {
      final r = _ok('{"title":"Оплатить интернет","priority":3}');
      expect(r.arguments, {'title': 'Оплатить интернет', 'priority': 3});
    });

    test('6. аргументы строкой JSON (стиль OpenAI)', () {
      final r = _ok(
        r'{"tool":"create_task","arguments":"{\"title\":\"Строка\"}"}',
      );
      expect(r.arguments['title'], 'Строка');
    });

    test('7. null и пустые строки в необязательных полях отбрасываются', () {
      final r = _ok(
        _wrap(
          '{"title":"Т","notes":"","priority":null,"due_date":null,'
          '"project":"  ","tags":[]}',
        ),
      );
      expect(r.arguments, {'title': 'Т'});
    });

    test('8. лишние ключи отбрасываются (как на сервере)', () {
      final r = _ok(_wrap('{"title":"Т","color":"red","id":"x"}'));
      expect(r.arguments, {'title': 'Т'});
    });

    test('9. целое число в виде 2.0 принимается', () {
      final r = _ok(_wrap('{"title":"Т","priority":2.0}'));
      expect(r.arguments['priority'], 2);
    });

    test('10. title обрезается по краям пробелов', () {
      final r = _ok(_wrap('{"title":"  Нужно  "}'));
      expect(r.arguments['title'], 'Нужно');
    });

    test('11. фигурные скобки внутри строки не ломают разбор', () {
      final r = _ok(_wrap(r'{"title":"Починить {кран} \"срочно\""}'));
      expect(r.arguments['title'], 'Починить {кран} "срочно"');
    });

    test('12. дата 29 февраля високосного года', () {
      final r = _ok(_wrap('{"title":"Т","due_date":"2028-02-29"}'));
      expect(r.arguments['due_date'], '2028-02-29');
    });

    test('13. ровно 5 тегов', () {
      final r = _ok(_wrap('{"title":"Т","tags":["а","б","в","г","д"]}'));
      expect((r.arguments['tags']! as List).length, 5);
    });

    test('14. граничные значения: priority 5, длительность 1440', () {
      final r = _ok(
        _wrap('{"title":"Т","priority":5,"duration_minutes":1440}'),
      );
      expect(r.arguments['priority'], 5);
      expect(r.arguments['duration_minutes'], 1440);
    });

    test('15. имя инструмента в поле name', () {
      final r = _ok('{"name":"create_task","arguments":{"title":"Т"}}');
      expect(r.arguments['title'], 'Т');
    });

    test('16. два объекта: берётся первый про инструмент', () {
      final r = _ok('{"foo":1} ${_wrap('{"title":"Первый"}')}');
      expect(r.arguments['title'], 'Первый');
    });
  });

  group('неверные поля', () {
    test('17. нет title', () {
      final r = _bad(_wrap('{"priority":2}'));
      expect(r.problems.single, contains('title'));
    });

    test('18. пустой title', () {
      expect(_bad(_wrap('{"title":"   "}')).problems.first, contains('title'));
    });

    test('19. title длиннее 500', () {
      final long = 'а' * 501;
      expect(_bad(_wrap('{"title":"$long"}')).problems.first, contains('500'));
    });

    test('20. priority вне 1..5', () {
      expect(
        _bad(_wrap('{"title":"Т","priority":6}')).problems.single,
        contains('priority'),
      );
      expect(
        _bad(_wrap('{"title":"Т","priority":0}')).problems.single,
        contains('priority'),
      );
    });

    test('21. priority строкой или дробью', () {
      expect(_bad(_wrap('{"title":"Т","priority":"2"}')).problems, isNotEmpty);
      expect(_bad(_wrap('{"title":"Т","priority":2.5}')).problems, isNotEmpty);
    });

    test('22. нереальная дата', () {
      expect(
        _bad(_wrap('{"title":"Т","due_date":"2026-02-30"}')).problems.single,
        contains('due_date'),
      );
      expect(
        _bad(_wrap('{"title":"Т","due_date":"завтра"}')).problems,
        isNotEmpty,
      );
      expect(
        _bad(_wrap('{"title":"Т","due_date":"1969-12-31"}')).problems,
        isNotEmpty,
      );
    });

    test('23. время без даты', () {
      expect(
        _bad(_wrap('{"title":"Т","due_time":"10:00"}')).problems.single,
        contains('due_date'),
      );
    });

    test('24. время неверного формата', () {
      expect(
        _bad(_wrap('{"title":"Т","due_date":"2026-10-09","due_time":"25:00"}'))
            .problems
            .single,
        contains('due_time'),
      );
      expect(
        _bad(_wrap('{"title":"Т","due_date":"2026-10-09","due_time":"9:5"}'))
            .problems,
        isNotEmpty,
      );
    });

    test('25. длительность вне 1..1440', () {
      expect(
        _bad(_wrap('{"title":"Т","duration_minutes":0}')).problems,
        isNotEmpty,
      );
      expect(
        _bad(_wrap('{"title":"Т","duration_minutes":1441}')).problems,
        isNotEmpty,
      );
    });

    test('26. больше 5 тегов', () {
      expect(
        _bad(_wrap('{"title":"Т","tags":["1","2","3","4","5","6"]}'))
            .problems
            .single,
        contains('tags'),
      );
    });

    test('27. тег не строка или с недопустимыми символами', () {
      expect(_bad(_wrap('{"title":"Т","tags":[1]}')).problems, isNotEmpty);
      expect(_bad(_wrap('{"title":"Т","tags":["a b"]}')).problems, isNotEmpty);
      expect(_bad(_wrap('{"title":"Т","tags":["#х"]}')).problems, isNotEmpty);
    });

    test('28. project длиннее 200 / не строка', () {
      final long = 'п' * 201;
      expect(
        _bad(_wrap('{"title":"Т","project":"$long"}')).problems,
        isNotEmpty,
      );
      expect(_bad(_wrap('{"title":"Т","project":5}')).problems, isNotEmpty);
    });

    test('29. несколько проблем сразу', () {
      final r = _bad(_wrap('{"priority":9,"due_date":"x"}'));
      expect(r.problems.length, greaterThanOrEqualTo(3));
    });

    test('30. notes не строка', () {
      expect(_bad(_wrap('{"title":"Т","notes":[1]}')).problems, isNotEmpty);
    });
  });

  group('неразобранный и оборванный JSON', () {
    test('31. оборван по длине', () {
      final r = _bad('{"tool":"create_task","arguments":{"title":"Куп');
      expect(r.problems.single, contains('оборван'));
    });

    test('32. оборван после вводного текста: текст сохраняется', () {
      final r = _bad('Создаю задачу. {"tool":"create_task","arguments":{"ti');
      expect(r.text, 'Создаю задачу.');
    });

    test('33. синтаксическая ошибка: запятая в конце', () {
      final r = _bad('{"tool":"create_task","arguments":{"title":"Т",}}');
      expect(r.problems.single, contains('JSON не разобран'));
    });

    test('34. одинарные кавычки', () {
      _bad("{'tool':'create_task','arguments':{'title':'Т'}}");
    });

    test('35. неизвестный инструмент', () {
      final r = _bad('{"tool":"delete_everything","arguments":{"title":"Т"}}');
      expect(r.problems.first, contains('delete_everything'));
    });

    test('36. arguments не объект', () {
      final r = _bad('{"tool":"create_task","arguments":[1,2]}');
      expect(r.problems.single, contains('arguments'));
    });

    test('37. arguments — строка не-JSON', () {
      _bad('{"tool":"create_task","arguments":"title=Т"}');
    });

    test('38. tool без arguments', () {
      _bad('{"tool":"create_task"}');
    });

    test('39. мусорный блок кода после текста про create_task', () {
      _bad('```json\n{"tool": "create_task", "arguments": {title: Т}}\n```');
    });
  });

  group('обычный текст — не вызов', () {
    test('40. пустой ответ', () {
      expect(_plain('').text, isEmpty);
      expect(_plain('   \n').text, isEmpty);
    });

    test('41. обычная фраза', () {
      expect(
        _plain('Сегодня у вас три задачи.').text,
        'Сегодня у вас три задачи.',
      );
    });

    test('42. JSON про другое', () {
      _plain('Вот данные: {"a":1,"b":[1,2]}');
    });

    test('43. фигурные скобки в тексте без инструмента', () {
      _plain('Формат такой: {дата}-{время}');
    });

    test('44. оборванный объект без упоминания задачи', () {
      _plain('Смотрите пример: {"a": 1, "b"');
    });

    test('45. код, не связанный с задачей', () {
      _plain('```dart\nvoid main() { print(1); }\n```');
    });
  });

  group('потоковый показ', () {
    test('сырой JSON не показывается, пока идёт ответ', () {
      expect(visibleTextWhileStreaming('Создаю.\n{"tool":"cr'), 'Создаю.');
      expect(visibleTextWhileStreaming('Обычный текст'), 'Обычный текст');
      expect(visibleTextWhileStreaming('```json\n{'), '');
      expect(looksLikeToolDraft('привет'), isFalse);
      expect(looksLikeToolDraft('{"to'), isTrue);
    });
  });
}
