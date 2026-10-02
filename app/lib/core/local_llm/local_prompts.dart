import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:timezone/timezone.dart' as tz;

const List<String> _weekdays = [
  'понедельник',
  'вторник',
  'среда',
  'четверг',
  'пятница',
  'суббота',
  'воскресенье',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// Блок «сейчас»: дата, день недели, время и пояс — модели нужна дата, чтобы
/// превращать «завтра», «в пятницу» в `due_date`.
String nowBlock(DateTime nowUtc, tz.Location zone) {
  final wall = utcToWall(zone, nowUtc);
  return 'Сейчас: ${wall.year}-${_two(wall.month)}-${_two(wall.day)}, '
      '${_weekdays[wall.weekday - 1]}, ${_two(wall.hour)}:${_two(wall.minute)} '
      '(${zone.name}).';
}

/// Общая системная часть локального ассистента (когда у чата нет агента).
const String defaultLocalAssistantPrompt =
    'Ты личный ассистент в приложении планирования. Отвечай по-русски, '
    'коротко и по делу. Опирайся на данные пользователя ниже; если данных '
    'не хватает — так и скажи, не выдумывай.';

/// Правила вызова `create_task` (формат — spec Этапа 3, 6.3).
const String createTaskRules =
    'Если пользователь просит создать, добавить или запланировать задачу, '
    'ответь ТОЛЬКО JSON-объектом без пояснений и без markdown:\n'
    '{"tool":"create_task","arguments":{"title":"...","due_date":"ГГГГ-ММ-ДД",'
    '"due_time":"ЧЧ:ММ","priority":1,"duration_minutes":30,"notes":"...",'
    '"project":"...","tags":["..."]}}\n'
    'Обязательно только title (до 500 знаков). Остальные поля добавляй, '
    'только если пользователь их назвал: priority — целое 1..5 (1 самый '
    'высокий), due_time только вместе с due_date, не больше 5 тегов. '
    'Относительные даты («завтра», «в пятницу») переводи в ГГГГ-ММ-ДД по '
    'текущей дате. На обычные вопросы отвечай обычным текстом, без JSON.';

/// Системная часть запроса: промт агента (или общий), правила инструмента,
/// «сейчас».
String buildLocalSystemPrompt({
  required DateTime nowUtc,
  required tz.Location zone,
  String? agentPrompt,
  bool allowCreateTask = true,
}) {
  final base = (agentPrompt == null || agentPrompt.trim().isEmpty)
      ? defaultLocalAssistantPrompt
      : agentPrompt.trim();
  return [
    base,
    if (allowCreateTask) createTaskRules,
    nowBlock(nowUtc, zone),
  ].join('\n\n');
}

/// Подсказка для единственного повтора после невалидного JSON.
String createTaskRetryHint(List<String> problems) =>
    'Твой ответ не подошёл: ${problems.join('; ')}. Ответь заново ТОЛЬКО '
    'корректным JSON-объектом {"tool":"create_task","arguments":{...}} без '
    'пояснений.';

/// Текст, если после повтора JSON так и не получился (карточки не будет).
const String createTaskFailedText =
    'Не получилось оформить задачу. Напишите ещё раз: что сделать, когда и '
    'с каким приоритетом.';

/// Фраза над карточкой, если модель не написала текст рядом с JSON.
String proposalLeadText(String title) => 'Предлагаю создать задачу «$title».';
