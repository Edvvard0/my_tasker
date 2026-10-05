import 'package:drift/drift.dart';
import 'package:my_tasker/core/db/calendar_tables.dart';

// DSL-описания таблиц исполняются только генератором кода (drift_dev).
// coverage:ignore-start

/// Правила «мерчант → категория» (spec `stage6_banks.md`, раздел 7).
/// Синхронизируемая таблица: `merchant_key`, `match_type` и `kind`
/// неизменяемы, `id` детерминирован
/// (`uuid5(ns("merchant_category_rules"), kind|match_type|merchant_key)`).
@DataClassName('MerchantCategoryRuleRow')
class MerchantCategoryRules extends Table with SyncColumns {
  TextColumn get merchantKey => text()();
  TextColumn get matchType => text()();
  TextColumn get kind => text()();
  TextColumn get categoryId => text()();

  @override
  String get tableName => 'merchant_category_rules';
}

/// Сырые уведомления банков — **только на устройстве** (не синхронизируются,
/// хранятся 30 дней): исходный текст нужен для «Требует проверки» и для
/// ручного создания операции. На сервер уходит лишь распознанная операция.
@DataClassName('BankNotificationRow')
@TableIndex(name: 'bank_notifications_received_idx', columns: {#receivedAt})
@TableIndex(name: 'bank_notifications_state_idx', columns: {#state})
class BankNotifications extends Table {
  TextColumn get id => text()();

  /// Отпечаток «пакет, время публикации, заголовок, текст»: одно и то же
  /// уведомление не обрабатывается дважды.
  TextColumn get fingerprint => text().unique()();
  TextColumn get package => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();

  /// Момент публикации уведомления (UTC, `YYYY-MM-DDTHH:MM:SSZ`).
  TextColumn get postedAt => text()();

  /// Когда приложение получило уведомление (UTC): от него идёт срок
  /// хранения.
  TextColumn get receivedAt => text()();

  /// `unrecognized` — не разобрано; `needs_account` — разобрано, но счёт
  /// не определён; `processed` — операция создана или найдена; `dismissed`
  /// — пользователь убрал.
  TextColumn get state => text()();

  /// Причина: `no_rule`, `bad_amount`, `unknown_currency`, `no_account`,
  /// `ambiguous_account`.
  TextColumn get reason => text().nullable()();

  /// Результат разбора (JSON) — для `needs_account`.
  TextColumn get parsedJson => text().nullable()();

  /// Операция, созданная или найденная по уведомлению.
  TextColumn get txId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  String get tableName => 'bank_notifications';
}

// coverage:ignore-end
