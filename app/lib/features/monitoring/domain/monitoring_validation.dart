/// Проверки «Серверов» на клиенте (spec `stage9_monitoring.md`, раздел 2).
/// Сервер отвергает то же самое построчно
/// (`backend/src/tasker/monitoring/schema.py`); здесь — те же правила с
/// русскими сообщениями для форм. Каждая функция возвращает первую проблему
/// или `null`. Правила цели (SSRF) — `monitoring_targets.dart`.
library;

import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_targets.dart';

const int maxNameLength = 100;
const int maxNoteLength = 2000;
const int maxProviderLength = 100;
const int minInterval = 10;
const int maxInterval = 3600;
const int maxTimeout = 30;

/// Одно слово, которое движок сравнивает буквально: без пробелов, звёздочек,
/// скобок, кавычек и подобных знаков (`KEYWORD_PATTERN` сервера).
final RegExp keywordPattern = RegExp(r'''^[^\s*()\[\]'"\\<>=!$`]{1,100}$''');

/// Ожидаемое значение DNS: один «токен» (`EXPECTED_VALUE_PATTERN`).
final RegExp expectedValuePattern = RegExp(r'^[A-Za-z0-9._:/-]{1,253}$');

/// Понятная причина отказа цели (коды `targets.py`).
String targetReasonText(String? reason) => switch (reason) {
  'empty' => 'Адрес не указан',
  'too_long' => 'Слишком длинный адрес',
  'bad_chars' =>
    'В адресе недопустимые символы (пробелы, «/», «@», «?», «#», «%» и др.)',
  'non_global_ip' =>
    'Адрес из внутренней сети или служебный — проверять можно только '
        'публичные адреса',
  'single_label' =>
    'Имя без точки (localhost, имя службы) — нужен публичный адрес вроде '
        'example.com',
  'bad_label' => 'Неверное имя: допустимы латинские буквы, цифры и дефис',
  'bad_tld' => 'Неверное окончание имени (нужны буквы, например .com или .ru)',
  'reserved_name' => 'Внутренняя зона имён (.local, .internal, .lan и т. п.)',
  'scheme' => 'Адрес должен начинаться с http:// или https://',
  'userinfo' => 'Логин и пароль в адресе не поддерживаются',
  'fragment' => 'Уберите «#…» в конце адреса',
  'bad_port' => 'Порт — число от 1 до 65535',
  'bad_url' => 'Адрес записан неверно',
  'no_host' => 'В адресе нет имени сервера',
  _ => 'Адрес не подходит для проверки',
};

bool _blank(String? value) => value == null || value.trim().isEmpty;

String? _nameProblem(String what, String name) {
  if (_blank(name)) return '$what: укажите название';
  if (name.length > maxNameLength) {
    return '$what: не длиннее $maxNameLength символов';
  }
  return null;
}

String? _noteProblem(String? note) =>
    (note?.length ?? 0) > maxNoteLength ? 'Заметка слишком длинная' : null;

/// Проверка поля «Адрес сервера / хост» (имя или публичный IP).
String? hostFieldProblem(String? host) {
  if (_blank(host)) return 'Укажите адрес';
  final verdict = checkHost(host!.trim());
  return verdict.valid ? null : targetReasonText(verdict.reason);
}

/// Проверка поля «Адрес (URL)» проверки HTTP.
String? urlFieldProblem(String? url) {
  if (_blank(url)) return 'Укажите адрес';
  final verdict = checkUrl(url!.trim());
  return verdict.valid ? null : targetReasonText(verdict.reason);
}

/// Сервер: название и публичный адрес.
String? serverProblem(MonitorServer s) {
  final name = _nameProblem('Сервер', s.name);
  if (name != null) return name;
  final host = hostFieldProblem(s.host);
  if (host != null) return host;
  if ((s.provider?.length ?? 0) > maxProviderLength) {
    return 'Провайдер — не длиннее $maxProviderLength символов';
  }
  return _noteProblem(s.note);
}

/// Сервис: название (сервер выбран при создании).
String? serviceProblem(MonitorService s) {
  final name = _nameProblem('Сервис', s.name);
  return name ?? _noteProblem(s.note);
}

/// Какие необязательные колонки использует вид (остальные — `null`).
const Map<CheckKind, Set<String>> usedColumns = {
  CheckKind.http: {'url', 'expected_status', 'keyword'},
  CheckKind.tcp: {'host', 'port'},
  CheckKind.dns: {'host', 'dns_record_type', 'expected_value'},
  CheckKind.ssl: {'host', 'port', 'ssl_min_days'},
};

/// Значения необязательных колонок проверки по именам колонок.
Map<String, Object?> _optional(MonitorCheck c) => {
  'url': c.url,
  'host': c.host,
  'port': c.port,
  'dns_record_type': c.dnsRecordType,
  'expected_value': c.expectedValue,
  'expected_status': c.expectedStatus,
  'keyword': c.keyword,
  'ssl_min_days': c.sslMinDays,
};

/// Проверка: поля вида, цель (правила SSRF), интервал и таймаут. Та же
/// последовательность, что у сервера (`check_problem`).
String? checkProblem(MonitorCheck c) {
  final name = _nameProblem('Проверка', c.name);
  if (name != null) return name;
  final used = usedColumns[c.kind]!;
  for (final e in _optional(c).entries) {
    if (e.value != null && !used.contains(e.key)) {
      return 'Поле «${e.key}» не подходит к проверке ${c.kind.label}';
    }
  }
  switch (c.kind) {
    case CheckKind.http:
      final url = urlFieldProblem(c.url);
      if (url != null) return url;
      final status = c.expectedStatus;
      if (status != null && (status < 100 || status > 599)) {
        return 'Ожидаемый код ответа — от 100 до 599';
      }
      final keyword = c.keyword;
      if (keyword != null && !keywordPattern.hasMatch(keyword)) {
        return 'Ключевое слово — одно слово без пробелов и знаков '
            '* ( ) [ ] \' " \\ < > = ! \$ `, до 100 символов';
      }
    case CheckKind.tcp:
      final host = hostFieldProblem(c.host);
      if (host != null) return host;
      final port = c.port;
      if (port == null) return 'Укажите порт';
      if (port < 1 || port > 65535) return 'Порт — число от 1 до 65535';
    case CheckKind.dns:
      final host = hostFieldProblem(c.host);
      if (host != null) return host;
      if (c.dnsRecordType == null) return 'Выберите тип записи';
      if (!dnsRecordTypes.contains(c.dnsRecordType)) {
        return 'Неизвестный тип записи';
      }
      final expected = c.expectedValue;
      if (expected != null && !expectedValuePattern.hasMatch(expected)) {
        return 'Ожидаемое значение — одно слово из букв, цифр и знаков '
            '. _ : / - (до 253 символов)';
      }
    case CheckKind.ssl:
      final host = hostFieldProblem(c.host);
      if (host != null) return host;
      final port = c.port;
      if (port != null && (port < 1 || port > 65535)) {
        return 'Порт — число от 1 до 65535';
      }
      final days = c.sslMinDays;
      if (days != null && (days < 1 || days > 365)) {
        return 'Минимум дней до конца сертификата — от 1 до 365';
      }
  }
  if (c.intervalSeconds < minInterval || c.intervalSeconds > maxInterval) {
    return 'Интервал — от $minInterval до $maxInterval секунд';
  }
  if (c.timeoutSeconds < 1 || c.timeoutSeconds > maxTimeout) {
    return 'Таймаут — от 1 до $maxTimeout секунд';
  }
  if (c.timeoutSeconds >= c.intervalSeconds) {
    return 'Таймаут должен быть меньше интервала';
  }
  return null;
}
