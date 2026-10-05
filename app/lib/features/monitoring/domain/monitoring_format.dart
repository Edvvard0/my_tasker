/// Тексты «Серверов» для интерфейса: статусы, причины, ошибки, длительности.
/// Технические коды сервера показываются человеку словами; сам код остаётся
/// в «Подробнее».
library;

import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_validation.dart';

/// Слово статуса для пилюли («РАБОТАЕТ» — регистр делает сама пилюля).
String statusLabel(PulseStatus status) => switch (status) {
  PulseStatus.up => 'Работает',
  PulseStatus.down => 'Лежит',
  PulseStatus.unknown => 'Нет данных',
};

/// Почему проверка не запускается (`problem` карточки, spec 4.2).
String problemText(String code) {
  if (code == 'resolve_failed') {
    return 'Имя не разрешается в DNS: пока адрес не откроется, проверка не '
        'запускается и тревог по ней нет.';
  }
  if (code == 'resolves_to_non_global') {
    return 'Имя указывает на внутренний адрес: такую проверку запускать '
        'нельзя.';
  }
  if (code == 'no_address') {
    return 'У имени нет адреса: проверка не запускается.';
  }
  if (code.startsWith('target_')) {
    final reason = code.substring('target_'.length);
    return 'Цель проверки не подходит: ${targetReasonText(reason)}.';
  }
  return 'Проверка не запускается ($code).';
}

/// Секунды человеческим языком: «45 с», «12 мин», «1 ч 5 мин», «2 дн. 3 ч».
String durationShort(int seconds) {
  if (seconds < 60) return '$seconds с';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes мин';
  final hours = minutes ~/ 60;
  final restMinutes = minutes % 60;
  if (hours < 24) {
    return restMinutes == 0 ? '$hours ч' : '$hours ч $restMinutes мин';
  }
  final days = hours ~/ 24;
  final restHours = hours % 24;
  return restHours == 0 ? '$days дн.' : '$days дн. $restHours ч';
}

/// Момент ответа сервера (`YYYY-MM-DDTHH:MM:SSZ`) -> `DateTime` UTC.
DateTime? parseMoment(String? text) => text == null ? null : parseInstant(text);

/// «Данные на 14:32 · нет сети» (офлайн-кэш «Пульса», spec 8).
String staleLabel(DateTime asOf) =>
    'Данные на ${formatLocalClock(asOf)} · нет сети';

/// Начало инцидента: «сегодня в 14:20», «30 сент., 14:20».
String incidentMoment(String startedAt, DateTime now) {
  final t = parseMoment(startedAt);
  return t == null ? startedAt : formatMoment(t, now);
}

/// Причина инцидента одной строкой (`reason` от сервера уже короткий).
String incidentReason(String? reason) =>
    (reason == null || reason.trim().isEmpty) ? 'без причины' : reason.trim();

/// Ошибка Telegram по коду (`telegram.last_error`, ответ `/telegram/test`).
String telegramErrorText(String? code) => switch (code) {
  null || '' => '',
  'not_configured' =>
    'Бот не настроен: токен и чат задаются на сервере (TELEGRAM_BOT_TOKEN, '
        'TELEGRAM_CHAT_ID).',
  'network' => 'Сервер не достучался до Telegram. Повторите позже.',
  'rate_limited' =>
    'Слишком часто: тестовое сообщение можно отправлять раз в 10 секунд.',
  'server_error' => 'Telegram временно не отвечает. Повторите позже.',
  'unauthorized' => 'Telegram отклонил токен бота: проверьте токен на сервере.',
  'chat_not_found' => 'Чат не найден: проверьте TELEGRAM_CHAT_ID на сервере.',
  'bad_request' => 'Telegram отклонил сообщение.',
  'bad_response' => 'Telegram ответил непонятно. Повторите позже.',
  _ => 'Не удалось отправить сообщение ($code).',
};

/// Причина, по которой движок не отвечает (`engine.error`, самопроверка).
String engineErrorText(String? code) => (code == null || code.isEmpty)
    ? 'движок не отвечает'
    : 'движок не отвечает: $code';

/// Подпись вида проверки для списка: «HTTP · https://example.com».
String checkSummary(MonitorCheck c) => '${c.kind.label} · ${c.target}';

/// «каждые 20 с», «каждые 5 мин».
String intervalText(int seconds) => 'каждые ${durationShort(seconds)}';
