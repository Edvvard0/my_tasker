import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/network/api_client.dart';

/// Человеческий текст ошибки входа: что случилось и что делать (02, 2.9.5).
/// Клиент ветвится по `code`, а не по тексту сервера (spec 0).
String loginErrorText(ApiException e) {
  if (e.kind == ApiErrorKind.notConfigured) {
    return 'Сервер не настроен. Укажи его адрес.';
  }
  if (e.kind == ApiErrorKind.certMismatch) {
    return 'Сертификат сервера не совпал с закреплённым. Проверь настройки '
        'сервера.';
  }
  if (e.isNetwork) {
    return 'Нет соединения с сервером. Проверь сеть и адрес сервера.';
  }
  return switch (e.code) {
    'invalid_credentials' => 'Неверный пароль или код. Проверь оба поля.',
    'too_many_attempts' => _tooMany(e),
    'client_too_old' =>
      'Нужно обновить приложение: сервер требует более новую версию.',
    'validation_error' => 'Проверь введённые данные.',
    'owner_secret_unreadable' =>
      'Сервер не может проверить код: после смены ключа шифрования секрет '
          'входа не читается. Владельцу нужно выполнить на сервере '
          '«user reset». Повторять вход не нужно.',
    'device_revoked' ||
    'refresh_reuse_detected' => 'Сессия завершена. Войди снова.',
    _ when e.status == 429 => 'Слишком много запросов. Подожди и повтори.',
    _ when e.status == 404 =>
      'Сервер не нашёл нужный адрес. Проверь адрес сервера в настройках.',
    _ when e.status == 403 => 'Доступ запрещён. Проверь адрес сервера.',
    _ when e.status == 401 => 'Неверный пароль или код. Проверь оба поля.',
    _ when e.isServerError => 'Сервер сейчас недоступен. Попробуй позже.',
    _ => 'Не удалось войти. Попробуй ещё раз.',
  };
}

String _tooMany(ApiException e) {
  final seconds = e.retryAfter?.inSeconds;
  if (seconds == null) return 'Слишком много попыток. Подожди и повтори.';
  final minutes = (seconds / 60).ceil();
  final wait = seconds < 90
      ? '$seconds ${pluralRu(seconds, 'секунду', 'секунды', 'секунд')}'
      : '$minutes ${pluralRu(minutes, 'минуту', 'минуты', 'минут')}';
  return 'Слишком много попыток. Повтори через $wait.';
}
