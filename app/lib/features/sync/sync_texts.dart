import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';

/// Тексты статуса синхронизации: что случилось и что делать (02, 2.9.5).
String syncFailureText(SyncFailureKind kind) => switch (kind) {
  SyncFailureKind.offline =>
    'Нет связи с сервером. Изменения сохраняются на устройстве и '
        'отправятся, когда появится сеть.',
  SyncFailureKind.server =>
    'Сервер ответил ошибкой. Попробуем ещё раз чуть позже.',
  SyncFailureKind.protocol =>
    'Сервер вернул неожиданный ответ. Если повторяется — обнови приложение.',
  SyncFailureKind.rateLimited =>
    'Слишком частые запросы. Подождём немного и повторим.',
  SyncFailureKind.clientTooOld =>
    'Нужно обновить приложение. Пока оно работает без синхронизации.',
  SyncFailureKind.authRequired => 'Нужен вход. Войди снова.',
  SyncFailureKind.notConfigured =>
    'Сервер не настроен. Укажи его адрес в настройках.',
  SyncFailureKind.unknown => 'Что-то пошло не так при синхронизации.',
};

/// «12 изменений».
String changesCount(int n) =>
    '$n ${pluralRu(n, 'изменение', 'изменения', 'изменений')}';

/// Подпись пилюли в верхней панели; `null` — индикатор не показывается.
/// На узком экране ([compact]) пилюля сжимается до значка и счётчика, чтобы
/// не вытеснять заголовок экрана.
String? indicatorLabel(SyncStatus status, {bool compact = false}) {
  final unsent = status.outbox.unsent;
  if (compact) {
    return switch (status.indicator) {
      SyncIndicatorKind.offline when unsent > 0 => '$unsent',
      _ => '',
    };
  }
  return switch (status.indicator) {
    SyncIndicatorKind.synced || SyncIndicatorKind.syncing => null,
    SyncIndicatorKind.offline => unsent > 0 ? 'Офлайн · $unsent' : 'Офлайн',
    SyncIndicatorKind.error => 'Не синхронизировано',
    SyncIndicatorKind.blocked => 'Нужно обновить',
  };
}

/// Название вида операции outbox.
String opTypeLabel(String type) => type == 'delete' ? 'Удаление' : 'Правка';

/// Короткое пояснение к коду отклонения (`rejected`, spec 3.3).
String rejectCodeText(String? code) => switch (code) {
  'unknown_table' => 'Сервер не знает такой раздел (приложение новее сервера).',
  'invalid_field' => 'Сервер не принял значение поля.',
  'immutable_field' => 'Это поле нельзя менять.',
  'missing_fields' => 'Не хватает обязательных полей.',
  'parent_not_found' => 'Родительская запись не найдена.',
  'validation_failed' => 'Нарушено правило данных.',
  'hlc_device_mismatch' => 'Изменение сделано с другого устройства.',
  'invalid_op' || 'invalid_id' || 'invalid_hlc' => 'Некорректная операция.',
  _ => 'Сервер отклонил изменение.',
};
