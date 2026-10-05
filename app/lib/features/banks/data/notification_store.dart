import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/app_database.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/domain/notification_engine.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart'
    show financeInstantText, parseFinanceInstant;

/// Срок хранения сырых уведомлений (spec 0 и 2.4 Этапа 6): 30 суток.
const Duration notificationRetention = Duration(days: 30);

/// Локальное хранилище сырых уведомлений банков (`bank_notifications`).
/// Не синхронизируется: исходный текст остаётся на устройстве, на сервер
/// уходит только распознанная операция.
class NotificationStore {
  NotificationStore(
    this._db, {
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? uuid7;

  final AppDatabase _db;
  final DateTime Function() _now;
  final String Function() _newId;

  /// Отпечаток уведомления для защиты от повторной обработки.
  static String fingerprint(RawNotification n) =>
      '${n.package}|${n.postedAt.toUtc().millisecondsSinceEpoch}|'
      '${n.title}|${n.text}';

  /// Сохраняет уведомление; `null`, если такое уже есть.
  Future<BankNotification?> insert(
    RawNotification raw, {
    required NotificationState state,
    String? reason,
    NotificationParse? parsed,
    String? txId,
  }) async {
    final id = _newId();
    final received = _utcSeconds(_now());
    try {
      await _db
          .into(_db.bankNotifications)
          .insert(
            BankNotificationsCompanion.insert(
              id: id,
              fingerprint: fingerprint(raw),
              package: raw.package,
              title: raw.title,
              body: raw.text,
              postedAt: financeInstantText(raw.postedAt),
              receivedAt: financeInstantText(received),
              state: state.wire,
              reason: Value(reason),
              parsedJson: Value(
                parsed == null ? null : jsonEncode(parsed.toJson()),
              ),
              txId: Value(txId),
            ),
          );
    } on Object catch (e) {
      if (e.toString().contains('UNIQUE')) return null;
      rethrow;
    }
    return await get(id);
  }

  /// Уже обработанное уведомление (по отпечатку).
  Future<bool> seen(RawNotification raw) async {
    final rows = await (_db.select(
      _db.bankNotifications,
    )..where((t) => t.fingerprint.equals(fingerprint(raw)))).get();
    return rows.isNotEmpty;
  }

  Future<BankNotification?> get(String id) async {
    final row = await (_db.select(
      _db.bankNotifications,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _model(row);
  }

  Future<List<BankNotification>> byState(NotificationState state) async {
    final rows =
        await (_db.select(_db.bankNotifications)
              ..where((t) => t.state.equals(state.wire))
              ..orderBy([
                (t) => OrderingTerm.desc(t.postedAt),
                (t) => OrderingTerm.desc(t.id),
              ]))
            .get();
    return [for (final r in rows) _model(r)];
  }

  /// Поток списка по состоянию (обновляется при записи в таблицу). Не
  /// использует `Selectable.watch()` Drift — как `SyncStore`: тот при отмене
  /// подписки заводит нулевой таймер, мешающий тестам виджетов.
  Stream<List<BankNotification>> watchByState(NotificationState state) {
    late final StreamController<List<BankNotification>> controller;
    StreamSubscription<Object?>? subscription;
    var chain = Future<void>.value();
    void emit() {
      chain = chain.then((_) async {
        if (controller.isClosed) return;
        try {
          final value = await byState(state);
          if (!controller.isClosed) controller.add(value);
        } on Object catch (error, stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        }
      });
    }

    controller = StreamController<List<BankNotification>>(
      onListen: () {
        emit();
        subscription = _db
            .tableUpdates(TableUpdateQuery.onAllTables({_db.bankNotifications}))
            .listen((_) => emit());
      },
      onCancel: () async {
        await subscription?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<void> _update(
    String id,
    BankNotificationsCompanion Function() change,
  ) => (_db.update(
    _db.bankNotifications,
  )..where((t) => t.id.equals(id))).write(change());

  /// Операция создана или найдена: исходный текст больше не нужен для
  /// проверки, но хранится до конца срока.
  Future<void> markProcessed(String id, {String? txId}) => _update(
    id,
    () => BankNotificationsCompanion(
      state: Value(NotificationState.processed.wire),
      txId: Value(txId),
    ),
  );

  Future<void> markDismissed(String id) => _update(
    id,
    () => BankNotificationsCompanion(
      state: Value(NotificationState.dismissed.wire),
    ),
  );

  /// Удаляет уведомления старше [notificationRetention]; возвращает число.
  Future<int> purgeExpired() {
    final cutoff = _utcSeconds(_now()).subtract(notificationRetention);
    return (_db.delete(_db.bankNotifications)..where(
          (t) => t.receivedAt.isSmallerThanValue(financeInstantText(cutoff)),
        ))
        .go();
  }

  Future<int> count() async {
    final rows = await _db.select(_db.bankNotifications).get();
    return rows.length;
  }

  BankNotification _model(BankNotificationRow r) {
    NotificationParse? parsed;
    final raw = r.parsedJson;
    if (raw != null) {
      parsed = NotificationParse.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    }
    return BankNotification(
      id: r.id,
      package: r.package,
      title: r.title,
      body: r.body,
      postedAt: parseFinanceInstant(r.postedAt),
      receivedAt: parseFinanceInstant(r.receivedAt),
      state: NotificationState.parse(r.state),
      reason: r.reason,
      parsed: parsed,
      txId: r.txId,
    );
  }
}

DateTime _utcSeconds(DateTime value) {
  final t = value.toUtc();
  return DateTime.fromMillisecondsSinceEpoch(
    (t.millisecondsSinceEpoch ~/ 1000) * 1000,
    isUtc: true,
  );
}

final Provider<NotificationStore> notificationStoreProvider =
    Provider<NotificationStore>(
      (ref) => NotificationStore(
        ref.watch(appDatabaseProvider),
        now: ref.watch(clockProvider),
      ),
    );
