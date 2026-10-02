import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';

/// Результат разбора строки быстрого ввода (spec 8): **предложение**, которое
/// интерфейс показывает чипами до сохранения.
@immutable
class QuickInput {
  const QuickInput({
    required this.title,
    this.priority,
    this.project,
    this.people = const [],
    this.tags = const [],
    this.date,
    this.time,
    this.durationMinutes,
  });

  final String title;

  /// 1…5 или `null`.
  final int? priority;
  final String? project;
  final List<String> people;
  final List<String> tags;

  /// `YYYY-MM-DD` или `null`.
  final String? date;

  /// `HH:MM` или `null`.
  final String? time;
  final int? durationMinutes;

  /// Формат файла векторов.
  Map<String, Object?> toJson() => {
    'title': title,
    'priority': priority,
    'project': project,
    'people': people,
    'tags': tags,
    'date': date,
    'time': time,
    'duration_minutes': durationMinutes,
  };
}

/// Разбор быстрого ввода (spec 8, раздел «Алгоритм»). Эталон —
/// `backend/src/tasker/calendar/reference_quick_input.py`; общие векторы —
/// `shared-test-vectors/calendar/quick_input.json`.
///
/// [now] — локальное время устройства (в поясе пользователя) до минуты; в
/// [DateTime] хранится как «настенные» поля (см. `DateTime.utc`).
QuickInput parseQuickInput(String text, DateTime now) =>
    analyzeQuickInput(text, now).result;

/// Что задаёт токен строки (для чипов: убрали чип — токены возвращаются в
/// название).
enum QuickToken { priority, project, person, tag, date, time, duration }

/// Разбор с привязкой токенов к распознанным компонентам.
class QuickInputAnalysis {
  const QuickInputAnalysis._(
    this.result,
    this._tokens,
    this._owners,
    this._now,
  );

  /// Результат по спецификации (то же, что вернёт [parseQuickInput]).
  final QuickInput result;
  final List<String> _tokens;
  final List<Set<QuickToken>> _owners;
  final DateTime _now;

  /// Результат, в котором компоненты [removed] не применяются, а их токены
  /// остаются в названии на своих местах. Убрать дату — убрать и время
  /// (время без даты не бывает); убрать время — убрать и длительность.
  QuickInput without(Set<QuickToken> removed) {
    if (removed.isEmpty) return result;
    final drop = {...removed};
    if (drop.contains(QuickToken.date)) drop.add(QuickToken.time);
    if (drop.contains(QuickToken.time)) drop.add(QuickToken.duration);
    final title = [
      for (var i = 0; i < _tokens.length; i++)
        if (_owners[i].isEmpty || _owners[i].every(drop.contains)) _tokens[i],
    ].join(' ');
    final hasTime = result.time != null && !drop.contains(QuickToken.time);
    final hasDate = result.date != null && !drop.contains(QuickToken.date);
    return QuickInput(
      title: title,
      priority: drop.contains(QuickToken.priority) ? null : result.priority,
      project: drop.contains(QuickToken.project) ? null : result.project,
      people: drop.contains(QuickToken.person) ? const [] : result.people,
      tags: drop.contains(QuickToken.tag) ? const [] : result.tags,
      date: hasDate ? result.date : null,
      time: hasDate && hasTime ? result.time : null,
      durationMinutes: hasDate && hasTime && !drop.contains(QuickToken.duration)
          ? result.durationMinutes
          : null,
    );
  }

  /// Какие компоненты распознаны (для чипов).
  Set<QuickToken> get present => {
    if (result.priority != null) QuickToken.priority,
    if (result.project != null) QuickToken.project,
    if (result.people.isNotEmpty) QuickToken.person,
    if (result.tags.isNotEmpty) QuickToken.tag,
    if (result.date != null) QuickToken.date,
    if (result.time != null) QuickToken.time,
    if (result.durationMinutes != null) QuickToken.duration,
  };

  /// Исходное время «сейчас» разбора.
  DateTime get now => _now;
}

/// Разбор строки быстрого ввода с привязкой токенов к компонентам.
QuickInputAnalysis analyzeQuickInput(String text, DateTime now) {
  final tokens = _split(text);
  final (rest, meta) = _splitNames(tokens);
  final state = _State(
    DateTime.utc(now.year, now.month, now.day, now.hour, now.minute),
    [for (final t in rest.tokens) _key(t)],
    List<bool>.filled(rest.tokens.length, false),
    [for (var i = 0; i < rest.tokens.length; i++) <QuickToken>{}],
  );
  _scan(state);
  _bareHour(state);
  var day = state.day;
  final clock = state.clock;
  if (clock != null && day == null) {
    final today = dateOnly(state.now);
    final later =
        clock.$1 > now.hour || (clock.$1 == now.hour && clock.$2 > now.minute);
    day = later ? today : addDays(today, 1);
  }
  final title = [
    for (var i = 0; i < rest.tokens.length; i++)
      if (!state.consumed[i]) rest.tokens[i],
  ].join(' ');
  String two(int v) => v.toString().padLeft(2, '0');
  final result = QuickInput(
    title: title,
    priority: meta.priority,
    project: meta.project,
    people: meta.people,
    tags: meta.tags,
    date: day == null ? null : formatDate(day),
    time: clock == null ? null : '${two(clock.$1)}:${two(clock.$2)}',
    durationMinutes: state.duration,
  );
  // Владельцы всех исходных токенов: метки — по [rest.labels], остальные —
  // по состоянию разбора.
  final owners = <Set<QuickToken>>[];
  var restIndex = 0;
  for (final label in rest.labels) {
    if (label != null) {
      owners.add({label});
    } else {
      owners.add({...state.owners[restIndex]});
      restIndex++;
    }
  }
  return QuickInputAnalysis._(result, tokens, owners, now);
}

// ---- токены и метки --------------------------------------------------------

/// Разделители: только U+0020, U+0009, U+000A, U+000D, U+00A0, U+202F,
/// U+2009 (spec 8.1, шаг 1).
final RegExp _separators = RegExp('[ \t\n\r   ]+');

List<String> _split(String text) => [
  for (final t in text.split(_separators))
    if (t.isNotEmpty) t,
];

final RegExp _priority = RegExp(r'^![1-5]$');
final RegExp _letter = RegExp(r'^\p{L}', unicode: true);
final RegExp _decimalDigit = RegExp(r'^\p{Nd}', unicode: true);

class _Meta {
  int? priority;
  String? project;
  final List<String> people = [];
  final List<String> tags = [];
}

String _stripTrailing(String value, String chars) {
  var end = value.length;
  while (end > 0 && chars.contains(value[end - 1])) {
    end--;
  }
  return value.substring(0, end);
}

({List<String> tokens, List<QuickToken?> labels}) _restOf(
  List<String> rest,
  List<QuickToken?> labels,
) => (tokens: rest, labels: labels);

(({List<String> tokens, List<QuickToken?> labels}), _Meta) _splitNames(
  List<String> tokens,
) {
  final rest = <String>[];
  final labels = <QuickToken?>[];
  final meta = _Meta();
  for (final token in tokens) {
    if (_priority.hasMatch(token)) {
      meta.priority = int.parse(token[1]);
      labels.add(QuickToken.priority);
      continue;
    }
    if (token.length > 1 && '#@+'.contains(token[0])) {
      final name = _stripTrailing(token.substring(1), ',.;:');
      final firstOk =
          _letter.hasMatch(name) ||
          (token[0] == '#' && _decimalDigit.hasMatch(name));
      if (name.isNotEmpty && firstOk) {
        _record(meta, token[0], name);
        labels.add(switch (token[0]) {
          '#' => QuickToken.project,
          '@' => QuickToken.person,
          _ => QuickToken.tag,
        });
        continue;
      }
    }
    rest.add(token);
    labels.add(null);
  }
  return (_restOf(rest, labels), meta);
}

void _record(_Meta meta, String sigil, String name) {
  if (sigil == '#') {
    meta.project = name; // побеждает последний
    return;
  }
  final bucket = sigil == '@' ? meta.people : meta.tags;
  final lower = name.toLowerCase();
  if (!bucket.any((item) => item.toLowerCase() == lower)) bucket.add(name);
}

/// Ключ токена: нижний регистр, `ё -> е`, без хвостовых `, ; :`.
String _key(String token) =>
    _stripTrailing(token.toLowerCase().replaceAll('ё', 'е'), ',;:');

// ---- состояние разбора -------------------------------------------------------

class _Match {
  const _Match(this.used, {this.day, this.clock, this.duration});

  final int used;
  final DateTime? day;
  final (int, int)? clock;
  final int? duration;
}

class _State {
  _State(this.now, this.keys, this.consumed, this.owners);

  final DateTime now;
  final List<String> keys;
  final List<bool> consumed;

  /// Какие компоненты забрали токен (для чипов).
  final List<Set<QuickToken>> owners;
  DateTime? day;
  (int, int)? clock;
  int? duration;

  DateTime get today => dateOnly(now);
}

const Map<String, int> _weekdays = {
  'понедельник': 0,
  'пн': 0,
  'вторник': 1,
  'вт': 1,
  'среда': 2,
  'среду': 2,
  'ср': 2,
  'четверг': 3,
  'чт': 3,
  'пятница': 4,
  'пятницу': 4,
  'пт': 4,
  'суббота': 5,
  'субботу': 5,
  'сб': 5,
  'воскресенье': 6,
  'вс': 6,
};

const Map<String, int> _months = {
  'января': 1,
  'янв': 1,
  'февраля': 2,
  'фев': 2,
  'марта': 3,
  'мар': 3,
  'апреля': 4,
  'апр': 4,
  'мая': 5,
  'июня': 6,
  'июн': 6,
  'июля': 7,
  'июл': 7,
  'августа': 8,
  'авг': 8,
  'сентября': 9,
  'сен': 9,
  'сент': 9,
  'октября': 10,
  'окт': 10,
  'ноября': 11,
  'ноя': 11,
  'нояб': 11,
  'декабря': 12,
  'дек': 12,
};

const _nextWords = ['следующий', 'следующую', 'следующее'];
const _connectors = ['в', 'во', 'на', 'к', 'до', 'с'];
const _dayWords = ['день', 'дня', 'дней'];
const _weekWords = ['неделю', 'недели', 'недель'];
const _monthWords = ['месяц', 'месяца', 'месяцев'];
const _minuteWords = ['минуту', 'минуты', 'минут', 'мин'];
const _hourWords = ['час', 'часа', 'часов', 'ч'];
const _periods = ['утра', 'дня', 'вечера'];
const Map<String, (int, int)> _dayPartTimes = {
  'утром': (9, 0),
  'днем': (13, 0),
  'вечером': (19, 0),
};
const Map<String, int> _dayOffsets = {
  'сегодня': 0,
  'завтра': 1,
  'послезавтра': 2,
};

final RegExp _int = RegExp(r'^[0-9]+$');
final RegExp _clock = RegExp(r'^([01]?[0-9]|2[0-3]):([0-5][0-9])$');
final RegExp _range = RegExp(
  r'^([01]?[0-9]|2[0-3]):([0-5][0-9])[-–—]([01]?[0-9]|2[0-3]):([0-5][0-9])$',
);
final RegExp _numericDate = RegExp(
  r'^([0-9]{1,2})\.([0-9]{1,2})(?:\.([0-9]{4}|[0-9]{2}))?$',
);
final RegExp _isoDate = RegExp(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$');
final RegExp _year = RegExp(r'^20[0-9]{2}$');

/// Число из токена; слишком большое число — «очень большое» (вне диапазонов).
int? _number(List<String> keys, int index) {
  if (index < keys.length && _int.hasMatch(keys[index])) {
    return int.tryParse(keys[index]) ?? (1 << 60);
  }
  return null;
}

DateTime? _safeDate(int year, int month, int day) {
  if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1) {
    return null;
  }
  if (day > daysInMonth(year, month)) return null;
  return DateTime.utc(year, month, day);
}

/// Эта дата этого года, если она не в прошлом, иначе следующего.
DateTime? _upcoming(DateTime today, int month, int day) {
  for (final year in [today.year, today.year + 1]) {
    final found = _safeDate(year, month, day);
    if (found != null && !found.isBefore(today)) return found;
  }
  return null;
}

_Match _moment(int used, DateTime moment) =>
    _Match(used, day: dateOnly(moment), clock: (moment.hour, moment.minute));

// ---- фразы -------------------------------------------------------------------

_Match? _relative(_State s, int i) {
  final keys = s.keys;
  if (keys[i] != 'через') return null;
  final following = i + 1 < keys.length ? keys[i + 1] : '';
  final today = s.today;
  switch (following) {
    case 'неделю':
      return _Match(2, day: addDays(today, 7));
    case 'месяц':
      return _Match(2, day: addMonthsClamped(today, 1));
    case 'час':
      return _moment(2, s.now.add(const Duration(hours: 1)));
    case 'полчаса':
      return _moment(2, s.now.add(const Duration(minutes: 30)));
  }
  final amount = _number(keys, i + 1);
  final unit = i + 2 < keys.length ? keys[i + 2] : '';
  if (amount == null) return null;
  if (_dayWords.contains(unit) && amount >= 1 && amount <= 365) {
    return _Match(3, day: addDays(today, amount));
  }
  if (_weekWords.contains(unit) && amount >= 1 && amount <= 52) {
    return _Match(3, day: addDays(today, 7 * amount));
  }
  if (_monthWords.contains(unit) && amount >= 1 && amount <= 24) {
    return _Match(3, day: addMonthsClamped(today, amount));
  }
  if (_minuteWords.contains(unit) && amount >= 1 && amount <= 1440) {
    return _moment(3, s.now.add(Duration(minutes: amount)));
  }
  if (_hourWords.contains(unit) && amount >= 1 && amount <= 72) {
    return _moment(3, s.now.add(Duration(hours: amount)));
  }
  return null;
}

_Match? _weekdayPhrase(_State s, int i) {
  final keys = s.keys;
  var j = i;
  if (keys[j] == 'в' || keys[j] == 'во') j++;
  final following = j < keys.length && _nextWords.contains(keys[j]);
  if (following) j++;
  if (j >= keys.length || !_weekdays.containsKey(keys[j])) return null;
  final target = _weekdays[keys[j]]!;
  final today = s.today;
  final DateTime found;
  if (following) {
    found = addDays(mondayOf(today), 7 + target);
  } else {
    final delta = (target - weekdayIndex(today)) % 7;
    found = addDays(today, delta == 0 ? 7 : delta);
  }
  return _Match(j + 1 - i, day: found);
}

_Match? _weekdayAt(_State s, int i) {
  final key = s.keys[i];
  if (key == 'в' ||
      key == 'во' ||
      _nextWords.contains(key) ||
      _weekdays.containsKey(key)) {
    return _weekdayPhrase(s, i);
  }
  return null;
}

_Match? _datePhrase(_State s, int i) {
  final keys = s.keys;
  final key = keys[i];
  final today = s.today;
  if (_dayOffsets.containsKey(key)) {
    return _Match(1, day: addDays(today, _dayOffsets[key]!));
  }
  if ((key == 'в' || key == 'на') &&
      i + 1 < keys.length &&
      (keys[i + 1] == 'выходные' || keys[i + 1] == 'выходных')) {
    final wd = weekdayIndex(today);
    return _Match(2, day: wd >= 5 ? today : addDays(today, 5 - wd));
  }
  final iso = _isoDate.firstMatch(key);
  if (iso != null) {
    final found = _safeDate(
      int.parse(iso.group(1)!),
      int.parse(iso.group(2)!),
      int.parse(iso.group(3)!),
    );
    return found == null ? null : _Match(1, day: found);
  }
  final numeric = _numericDate.firstMatch(key);
  if (numeric != null) {
    final day = int.parse(numeric.group(1)!);
    final month = int.parse(numeric.group(2)!);
    final year = numeric.group(3);
    final DateTime? found;
    if (year == null) {
      found = _upcoming(today, month, day);
    } else {
      found = _safeDate(
        int.parse(year) + (year.length == 2 ? 2000 : 0),
        month,
        day,
      );
    }
    return found == null ? null : _Match(1, day: found);
  }
  final amount = _number(keys, i);
  if (amount != null &&
      i + 1 < keys.length &&
      _months.containsKey(keys[i + 1])) {
    final month = _months[keys[i + 1]]!;
    if (i + 2 < keys.length && _year.hasMatch(keys[i + 2])) {
      final found = _safeDate(int.parse(keys[i + 2]), month, amount);
      return found == null ? null : _Match(3, day: found);
    }
    final found = _upcoming(today, month, amount);
    return found == null ? null : _Match(2, day: found);
  }
  return null;
}

_Match? _clockRange(int used, (int, int) start, (int, int) end) {
  final minutes = (end.$1 * 60 + end.$2) - (start.$1 * 60 + start.$2);
  if (minutes <= 0) return null;
  return _Match(used, clock: start, duration: minutes);
}

_Match? _timePhrase(_State s, int i) {
  final keys = s.keys;
  final key = keys[i];
  if (key == 'с' && i + 3 < keys.length && keys[i + 2] == 'до') {
    final first = _clock.firstMatch(keys[i + 1]);
    final second = _clock.firstMatch(keys[i + 3]);
    if (first != null && second != null) {
      return _clockRange(
        4,
        (int.parse(first.group(1)!), int.parse(first.group(2)!)),
        (int.parse(second.group(1)!), int.parse(second.group(2)!)),
      );
    }
  }
  final ranged = _range.firstMatch(key);
  if (ranged != null) {
    final g = [for (var n = 1; n <= 4; n++) int.parse(ranged.group(n)!)];
    return _clockRange(1, (g[0], g[1]), (g[2], g[3]));
  }
  final hour = _hourPhrase(keys, i);
  if (hour != null) return hour;
  final clock = _clock.firstMatch(key);
  if (clock != null) {
    return _Match(
      1,
      clock: (int.parse(clock.group(1)!), int.parse(clock.group(2)!)),
    );
  }
  if (_dayPartTimes.containsKey(key)) {
    return _Match(1, clock: _dayPartTimes[key]);
  }
  return null;
}

/// `[в|к] N [час|часа|часов] [утра|дня|вечера]` (голое «в N» — отдельно).
_Match? _hourPhrase(List<String> keys, int i) {
  var j = i;
  final hasPrep = keys[j] == 'в' || keys[j] == 'к';
  if (hasPrep) j++;
  final amount = _number(keys, j);
  if (amount == null) return null;
  j++;
  final hasWord = j < keys.length && ['час', 'часа', 'часов'].contains(keys[j]);
  if (hasWord) j++;
  final period = j < keys.length && _periods.contains(keys[j]) ? keys[j] : null;
  if (period != null) {
    j++;
    if (amount < 1 || amount > 12) return null;
    final hour = period == 'утра' ? amount % 12 : amount % 12 + 12;
    return _Match(j - i, clock: (hour, 0));
  }
  if (hasWord && hasPrep && amount >= 0 && amount <= 23) {
    return _Match(j - i, clock: (amount, 0));
  }
  return null;
}

_Match? _durationPhrase(_State s, int i) {
  final keys = s.keys;
  if (keys[i] != 'на' || i + 1 >= keys.length) return null;
  final following = keys[i + 1];
  if (following == 'час') return const _Match(2, duration: 60);
  if (following == 'полчаса') return const _Match(2, duration: 30);
  if (following == 'полтора' && i + 2 < keys.length && keys[i + 2] == 'часа') {
    return const _Match(3, duration: 90);
  }
  final amount = _number(keys, i + 1);
  final unit = i + 2 < keys.length ? keys[i + 2] : '';
  if (amount == null) return null;
  if (_minuteWords.contains(unit) && amount >= 1 && amount <= 1440) {
    return _Match(3, duration: amount);
  }
  if (_hourWords.contains(unit) && amount >= 1 && amount <= 24) {
    return _Match(3, duration: amount * 60);
  }
  return null;
}

/// Принимает фразу, если все её компоненты ещё свободны. Возвращает число
/// использованных токенов (0 — фраза отвергнута).
int _accept(_State s, int i, _Match match) {
  if ((match.day != null && s.day != null) ||
      (match.clock != null && s.clock != null) ||
      (match.duration != null && s.duration != null)) {
    return 0;
  }
  s
    ..day = match.day ?? s.day
    ..clock = match.clock ?? s.clock
    ..duration = match.duration ?? s.duration;
  final kinds = {
    if (match.day != null) QuickToken.date,
    if (match.clock != null) QuickToken.time,
    if (match.duration != null) QuickToken.duration,
  };
  for (var k = i; k < i + match.used; k++) {
    s.consumed[k] = true;
    s.owners[k].addAll(kinds);
  }
  final setsMoment = match.day != null || match.clock != null;
  if (setsMoment &&
      i > 0 &&
      !s.consumed[i - 1] &&
      _connectors.contains(s.keys[i - 1])) {
    s.consumed[i - 1] = true; // висящий «в», «на», «до» перед фразой
    s.owners[i - 1].addAll(kinds);
  }
  return match.used;
}

void _scan(_State s) {
  var i = 0;
  while (i < s.keys.length) {
    final match =
        _relative(s, i) ??
        _weekdayAt(s, i) ??
        _datePhrase(s, i) ??
        _timePhrase(s, i) ??
        _durationPhrase(s, i);
    final used = match == null ? 0 : _accept(s, i, match);
    i += used == 0 ? 1 : used;
  }
}

/// Голое «в N» (N = 0…23): время, если найдена дата или это последние два
/// токена.
void _bareHour(_State s) {
  if (s.clock != null) return;
  final keys = s.keys;
  for (var i = 0; i < keys.length - 1; i++) {
    if (s.consumed[i] || s.consumed[i + 1] || keys[i] != 'в') continue;
    final amount = _number(keys, i + 1);
    if (amount == null || amount > 23) continue;
    if (s.day == null && i + 2 != keys.length) continue;
    s
      ..clock = (amount, 0)
      ..consumed[i] = true
      ..consumed[i + 1] = true;
    s.owners[i].add(QuickToken.time);
    s.owners[i + 1].add(QuickToken.time);
    return;
  }
}
