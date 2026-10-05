import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
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

/// Окно «повтора»: уведомление с тем же пакетом, заголовком и текстом в
/// пределах этого срока от уже виденного считается повторной публикацией
/// (банк обновил уведомление), а не новой операцией.
const Duration notificationRepeatWindow = Duration(minutes: 2);

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

  /// Хеш «пакет, заголовок, текст» — общая часть отпечатка и ключ окна
  /// повтора. Сам текст в отпечаток не попадает.
  static String contentKey(RawNotification n) => sha256
      .convert(utf8.encode('${n.package}\u0000${n.title}\u0000${n.text}'))
      .toString()
      .substring(0, 32);

  /// Отпечаток уведомления для защиты от повторной обработки:
  /// `<хеш содержимого>:<хеш экземпляра>`. Экземпляр — ключ уведомления в
  /// системе и `when` (одно и то же уведомление, опубликованное повторно,
  /// их сохраняет); `postTime` в отпечаток **не входит** — он меняется при
  /// повторной публикации. Без ключа и `when` (старая очередь, тесты) в
  /// экземпляр входит время публикации.
  static String fingerprint(RawNotification n) {
    final when = n.whenMs ?? 0;
    final instance = n.key != null || when > 0
        ? '${n.key ?? ''}|$when'
        : '${n.postedAt.toUtc().millisecondsSinceEpoch}';
    final tail = sha256
        .convert(utf8.encode(instance))
        .toString()
        .substring(0, 16);
    return '${contentKey(n)}:$tail';
  }

  /// Состояния, у которых исходный текст не нужен: он стирается.
  static bool _keepsText(NotificationState state) =>
      state == NotificationState.unrecognized ||
      state == NotificationState.needsAccount;

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
              title: _keepsText(state) ? raw.title : '',
              body: _keepsText(state) ? raw.text : '',
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

  /// Уже обработанное уведомление: тот же отпечаток или то же содержимое
  /// в пределах [notificationRepeatWindow] (повторная публикация в другую
  /// минуту).
  Future<bool> seen(RawNotification raw) async {
    final exact = await (_db.select(
      _db.bankNotifications,
    )..where((t) => t.fingerprint.equals(fingerprint(raw)))).get();
    if (exact.isNotEmpty) return true;
    final similar = await (_db.select(
      _db.bankNotifications,
    )..where((t) => t.fingerprint.like('${contentKey(raw)}:%'))).get();
    final at = raw.postedAt.toUtc();
    return similar.any(
      (r) =>
          parseFinanceInstant(r.postedAt).difference(at).abs() <=
          notificationRepeatWindow,
    );
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

  /// Операция создана или найдена: исходный текст больше не нужен и
  /// стирается (остаются результат разбора — для остатка — и ссылка на
  /// операцию, пока остаток не использован).
  Future<void> markProcessed(
    String id, {
    String? txId,
    bool possibleDuplicate = false,
  }) => _update(
    id,
    () => BankNotificationsCompanion(
      state: Value(
        (possibleDuplicate
                ? NotificationState.possibleDuplicate
                : NotificationState.processed)
            .wire,
      ),
      reason: Value(possibleDuplicate ? 'possible_duplicate' : null),
      txId: Value(txId),
      title: const Value(''),
      body: const Value(''),
    ),
  );

  Future<void> markDismissed(String id) => _update(
    id,
    () => BankNotificationsCompanion(
      state: Value(NotificationState.dismissed.wire),
      title: const Value(''),
      body: const Value(''),
    ),
  );

  /// Уведомления, по которым создана операция [txId] и которые ещё хранят
  /// результат разбора (остаток для точки сверки) или ждут решения
  /// «дубль / отдельная покупка».
  Future<List<BankNotification>> pendingForTx(String txId) async {
    final rows =
        await (_db.select(_db.bankNotifications)..where(
              (t) =>
                  t.txId.equals(txId) &
                  t.state.isIn([
                    NotificationState.processed.wire,
                    NotificationState.possibleDuplicate.wire,
                  ]) &
                  (t.parsedJson.isNotNull() |
                      t.state.equals(NotificationState.possibleDuplicate.wire)),
            ))
            .get();
    return [for (final r in rows) _model(r)];
  }

  /// Решение по операции принято: пометка «возможный дубль» и результат
  /// разбора больше не нужны.
  Future<void> settle(String id) => _update(
    id,
    () => BankNotificationsCompanion(
      state: Value(NotificationState.processed.wire),
      reason: const Value(null),
      parsedJson: const Value(null),
    ),
  );

  /// Удаляет закрытые уведомления (обработанные и убранные) старше
  /// [notificationRetention]; возвращает число. **Нерешённые**
  /// (`unrecognized`, `needs_account`, `possible_duplicate`) не удаляются:
  /// иначе настоящая операция молча пропала бы из «Требует проверки».
  Future<int> purgeExpired() {
    final cutoff = _utcSeconds(_now()).subtract(notificationRetention);
    return (_db.delete(_db.bankNotifications)..where(
          (t) =>
              t.receivedAt.isSmallerThanValue(financeInstantText(cutoff)) &
              t.state.isIn([
                NotificationState.processed.wire,
                NotificationState.dismissed.wire,
              ]),
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
