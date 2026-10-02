import 'dart:convert';

import 'package:my_tasker/core/calendar_time/civil_date.dart' show parseDate;
import 'package:my_tasker/features/tasks/domain/task_validation.dart'
    show isValidTagName;

/// Результат разбора ответа локальной модели на предмет вызова `create_task`.
sealed class ToolParseResult {
  const ToolParseResult();
}

/// В ответе нет попытки вызвать инструмент — это обычный текст.
final class NoToolCall extends ToolParseResult {
  const NoToolCall(this.text);

  final String text;
}

/// Вызов `create_task` разобран и прошёл проверку схемы.
final class ParsedToolCall extends ToolParseResult {
  const ParsedToolCall({required this.arguments, required this.text});

  /// Нормализованные аргументы (spec Этапа 3, 6.3): только известные поля,
  /// без `null` и пустых строк.
  final Map<String, Object?> arguments;

  /// Текст ответа вокруг JSON (может быть пустым).
  final String text;
}

/// Модель пыталась вызвать инструмент, но JSON не разобран или не прошёл
/// проверку.
final class InvalidToolCall extends ToolParseResult {
  const InvalidToolCall({
    required this.problems,
    required this.text,
    required this.raw,
  });

  /// Проблемы по-русски — для подсказки при повторе.
  final List<String> problems;

  /// Текст ответа вокруг JSON.
  final String text;

  /// Сырой ответ модели.
  final String raw;
}

/// Имя инструмента.
const String createTaskTool = 'create_task';

/// Допустимые поля аргументов `create_task`.
const List<String> createTaskFields = [
  'title',
  'notes',
  'priority',
  'due_date',
  'due_time',
  'duration_minutes',
  'project',
  'tags',
];

/// Найденный в тексте объект `{...}`.
class _Span {
  const _Span(this.start, this.end, this.value, this.error);

  final int start;
  final int end;
  final Object? value;
  final String? error;
}

/// Находит в [text] верхнеуровневые сбалансированные `{...}` (строки и
/// экранирование учитываются). Второй результат — «последний объект не
/// закрыт» (ответ оборван по длине).
({List<_Span> spans, int? unterminatedFrom}) _findObjects(String text) {
  final spans = <_Span>[];
  var depth = 0;
  var start = -1;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"' && depth > 0) {
      inString = true;
    } else if (ch == '{') {
      if (depth == 0) start = i;
      depth++;
    } else if (ch == '}' && depth > 0) {
      depth--;
      if (depth == 0) {
        final source = text.substring(start, i + 1);
        try {
          spans.add(_Span(start, i + 1, jsonDecode(source), null));
        } on FormatException catch (e) {
          spans.add(_Span(start, i + 1, null, e.message));
        }
      }
    }
  }
  return (spans: spans, unterminatedFrom: depth > 0 ? start : null);
}

/// Текст ответа без JSON-объектов и маркеров кода (```), в одну связную
/// строку.
String _proseOutside(String text, Iterable<_Span> removed) {
  final buffer = StringBuffer();
  var pos = 0;
  for (final span in removed) {
    buffer.write(text.substring(pos, span.start));
    pos = span.end;
  }
  buffer.write(text.substring(pos));
  return buffer
      .toString()
      .replaceAll(RegExp('```[a-zA-Z]*'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// Текст до начала JSON-вызова: что показывать, пока ответ ещё генерируется
/// (карточка появится после разбора, сырой JSON пользователю не нужен).
String visibleTextWhileStreaming(String partial) {
  final brace = partial.indexOf('{');
  final fence = partial.indexOf('```');
  final cuts = [brace, fence].where((i) => i >= 0);
  if (cuts.isEmpty) return partial;
  return partial.substring(0, cuts.reduce((a, b) => a < b ? a : b)).trimRight();
}

/// Ответ уже содержит начало вызова инструмента (показываем «Формирую
/// задачу…» вместо сырого JSON).
bool looksLikeToolDraft(String partial) =>
    partial.contains('{') || partial.contains('```');

bool _mentionsTool(String text) =>
    text.contains(createTaskTool) || text.contains('"title"');

bool _isAttempt(Map<String, Object?> map) =>
    map['tool'] != null ||
    map['name'] == createTaskTool ||
    map['function'] == createTaskTool ||
    map['arguments'] is Map ||
    map['arguments'] is String ||
    map['parameters'] is Map ||
    map['title'] is String;

/// Разбирает ответ локальной модели (строгий разбор, решение этапа 10, п. 6).
///
/// Ожидаемый формат: объект `{"tool": "create_task", "arguments": {...}}`,
/// возможно в блоке кода и с текстом вокруг. Допускается и «голый» объект
/// аргументов (с полем `title`). Правила:
/// * нет объекта / объект не про инструмент -> [NoToolCall];
/// * объект про `create_task`, но неразбираем, оборван или нарушает схему ->
///   [InvalidToolCall] с перечнем проблем;
/// * иначе -> [ParsedToolCall] с нормализованными аргументами.
ToolParseResult parseCreateTaskReply(String raw) {
  final found = _findObjects(raw);

  Map<String, Object?>? attempt;
  _Span? attemptSpan;
  for (final span in found.spans) {
    final value = span.value;
    if (value is Map<String, Object?> && _isAttempt(value)) {
      attempt = value;
      attemptSpan = span;
      break;
    }
  }

  if (attempt == null || attemptSpan == null) {
    final brokenSpan = found.spans
        .where((s) => s.error != null)
        .where((s) => _mentionsTool(raw.substring(s.start, s.end)))
        .firstOrNull;
    if (brokenSpan != null) {
      return InvalidToolCall(
        problems: ['JSON не разобран: ${brokenSpan.error}'],
        text: _proseOutside(raw, [brokenSpan]),
        raw: raw,
      );
    }
    final cut = found.unterminatedFrom;
    if (cut != null && _mentionsTool(raw)) {
      return InvalidToolCall(
        problems: const ['ответ оборван: JSON не закрыт'],
        text: raw.substring(0, cut).replaceAll('```json', '').trim(),
        raw: raw,
      );
    }
    return NoToolCall(raw.trim());
  }

  final prose = _proseOutside(raw, [attemptSpan]);
  final problems = <String>[];

  final tool = attempt['tool'] ?? attempt['name'] ?? attempt['function'];
  if (tool != null && tool != createTaskTool) {
    problems.add('неизвестный инструмент «$tool», доступен только create_task');
  }

  var args = attempt['arguments'] ?? attempt['parameters'];
  if (args == null && attempt['tool'] == null && attempt['title'] != null) {
    // «Голый» объект аргументов.
    args = attempt;
  }
  if (args is String) {
    try {
      args = jsonDecode(args);
    } on FormatException {
      problems.add('arguments: строка не является JSON-объектом');
    }
  }
  if (args is! Map) {
    if (problems.isEmpty) {
      problems.add('arguments: нужен объект с полями задачи');
    }
    return InvalidToolCall(problems: problems, text: prose, raw: raw);
  }

  final normalized = _validateArguments(args.cast<String, Object?>(), problems);
  if (problems.isNotEmpty) {
    return InvalidToolCall(problems: problems, text: prose, raw: raw);
  }
  return ParsedToolCall(arguments: normalized, text: prose);
}

final RegExp _timePattern = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

int? _intOf(Object? value) {
  if (value is int) return value;
  if (value is double && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

/// Проверка по spec Этапа 3, 6.3; ошибки — в [problems].
Map<String, Object?> _validateArguments(
  Map<String, Object?> args,
  List<String> problems,
) {
  final out = <String, Object?>{};

  final rawTitle = args['title'];
  if (rawTitle is! String || rawTitle.trim().isEmpty) {
    problems.add('title: обязательная непустая строка');
  } else if (rawTitle.trim().length > 500) {
    problems.add('title: не длиннее 500 знаков');
  } else {
    out['title'] = rawTitle.trim();
  }

  final notes = args['notes'];
  if (notes != null) {
    if (notes is! String) {
      problems.add('notes: должна быть строка');
    } else if (notes.length > 20000) {
      problems.add('notes: не длиннее 20 000 знаков');
    } else if (notes.trim().isNotEmpty) {
      out['notes'] = notes.trim();
    }
  }

  final priorityRaw = args['priority'];
  if (priorityRaw != null) {
    final priority = _intOf(priorityRaw);
    if (priority == null || priority < 1 || priority > 5) {
      problems.add('priority: целое число от 1 до 5');
    } else {
      out['priority'] = priority;
    }
  }

  final dueDate = args['due_date'];
  String? date;
  if (dueDate != null) {
    if (dueDate is! String || parseDate(dueDate.trim()) == null) {
      problems.add('due_date: настоящая дата в формате ГГГГ-ММ-ДД');
    } else {
      date = dueDate.trim();
      out['due_date'] = date;
    }
  }

  final dueTime = args['due_time'];
  if (dueTime != null) {
    if (dueTime is! String || !_timePattern.hasMatch(dueTime.trim())) {
      problems.add('due_time: время в формате ЧЧ:ММ');
    } else if (dueDate == null) {
      problems.add('due_time: нельзя без due_date');
    } else if (date != null) {
      out['due_time'] = dueTime.trim();
    }
  }

  final durationRaw = args['duration_minutes'];
  if (durationRaw != null) {
    final duration = _intOf(durationRaw);
    if (duration == null || duration < 1 || duration > 1440) {
      problems.add('duration_minutes: целое число от 1 до 1440');
    } else {
      out['duration_minutes'] = duration;
    }
  }

  final project = args['project'];
  if (project != null) {
    if (project is! String) {
      problems.add('project: должна быть строка');
    } else if (project.trim().length > 200) {
      problems.add('project: не длиннее 200 знаков');
    } else if (project.trim().isNotEmpty) {
      out['project'] = project.trim();
    }
  }

  final tags = args['tags'];
  if (tags != null) {
    if (tags is! List || tags.any((t) => t is! String)) {
      problems.add('tags: список строк');
    } else {
      final clean = [
        for (final t in tags.cast<String>())
          if (t.trim().isNotEmpty) t.trim(),
      ];
      if (clean.length > 5) {
        problems.add('tags: не больше 5 тегов');
      } else if (clean.any((t) => !isValidTagName(t))) {
        problems.add(
          'tags: имя тега без пробелов и символов # @ + !, до 50 знаков',
        );
      } else if (clean.isNotEmpty) {
        out['tags'] = clean;
      }
    }
  }
  return out;
}
