import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/banks/data/bank_drafts.dart';
import 'package:my_tasker/features/banks/data/bank_pipeline.dart';
import 'package:my_tasker/features/banks/data/banks_repository.dart';
import 'package:my_tasker/features/banks/data/notification_store.dart';
import 'package:my_tasker/features/banks/data/statement_importer.dart';
import 'package:my_tasker/features/banks/data/statements_api.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/domain/statement_models.dart';
import 'package:my_tasker/features/banks/platform/bank_platform.dart';
import 'package:my_tasker/features/banks/platform/statement_file_source.dart';

import 'banks_data.dart';
import 'fake_server/fake_sync_server.dart';
import 'finance_env.dart';
import 'manual_clock.dart';

export 'banks_data.dart' show loadBankDataSync;
export 'finance_env.dart';

/// Пакеты банков из синтетических правил.
const String tbankPackage = 'com.idamob.tinkoff.android';
const String vtbPackage = 'ru.vtb24.mobilebanking.android';

/// Уведомление банка в момент [at] (UTC).
RawNotification raw(String package, String title, String text, DateTime at) =>
    RawNotification(package: package, title: title, text: text, postedAt: at);

/// Поддельная платформа: управляемые разрешения, очередь, сигнал.
class FakeBankPlatform implements BankPlatform {
  FakeBankPlatform({this.supported = true});

  final bool supported;
  bool listenerEnabled = false;
  bool batteryExempt = false;
  final List<RawNotification> queue = [];
  List<String> packages = const [];
  int openedListener = 0;
  int openedBattery = 0;
  int drains = 0;
  final StreamController<void> _wake = StreamController<void>.broadcast();

  void wake() => _wake.add(null);

  @override
  bool get isSupported => supported;

  @override
  Future<void> setWatchedPackages(List<String> packages) async =>
      this.packages = packages;

  @override
  Future<bool> isListenerEnabled() async => listenerEnabled;

  @override
  Future<void> openListenerSettings() async => openedListener++;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => batteryExempt;

  @override
  Future<void> openBatterySettings() async => openedBattery++;

  @override
  Future<List<RawNotification>> drain() async {
    drains++;
    final out = [...queue];
    queue.clear();
    return out;
  }

  @override
  Stream<void> get wakeups => _wake.stream;
}

/// Поддельный API разбора выписки.
class FakeStatementsApi implements StatementsApi {
  FakeStatementsApi([this.statement]);

  ParsedStatement? statement;
  Exception? error;
  int calls = 0;
  Uint8List? lastBytes;

  @override
  Future<ParsedStatement> parse(
    Uint8List bytes, {
    String? format,
    String bank = 'auto',
  }) async {
    calls++;
    lastBytes = bytes;
    final e = error;
    if (e != null) throw e;
    return statement!;
  }
}

/// Поддельный выбор файла.
class FakeStatementFileSource implements StatementFileSource {
  FakeStatementFileSource([this.file]);

  PickedStatementFile? file;
  int picks = 0;

  @override
  Future<PickedStatementFile?> pick() async {
    picks++;
    return file;
  }
}

PickedStatementFile pickedFile([String name = 'statement.csv']) =>
    PickedStatementFile(name: name, bytes: Uint8List.fromList([1, 2, 3]));

/// Ответ сервера (`candidates`) для [ParsedStatement.fromJson].
Map<String, Object?> serverLine({
  required int index,
  required String occurredAt,
  required String kind,
  required int amount,
  String? merchant,
  String? card,
  bool dateOnly = false,
  String? externalId,
  String currency = 'RUB',
  bool needsReview = false,
  String? mcc,
  int? originalAmount,
  String? originalCurrency,
}) => {
  'index': index,
  'row': index + 2,
  'occurred_at': occurredAt,
  'date_only': dateOnly,
  'kind': kind,
  'amount': amount,
  'currency': currency,
  'original_amount': originalAmount,
  'original_currency': originalCurrency,
  'merchant': merchant,
  'merchant_norm': merchant?.toLowerCase(),
  'card_last4': card,
  'external_id': externalId,
  'mcc': mcc,
  'bank_category': null,
  'balance_after': null,
  'needs_review': needsReview,
  'review_reason': needsReview ? 'foreign_currency' : null,
  'dedup_tail': null,
  'suggested_category': {'source': null, 'category_id': null},
};

ParsedStatement statementOf(
  List<Map<String, Object?>> lines, {
  String bank = 'tbank',
  List<String> cards = const [],
  Map<String, Object?>? closing,
  List<Map<String, Object?>> skipped = const [],
}) => ParsedStatement.fromJson({
  'format': 'csv',
  'bank': bank,
  'period': const {'from': '2026-09-01', 'to': '2026-09-30'},
  'closing_balance': closing,
  'cards': cards,
  'candidates': lines,
  'skipped': skipped,
});

/// Устройство с репозиториями и службами Банков поверх [FinanceDevice]
/// (тесты конвейера, черновиков и импорта без интерфейса).
class BanksDevice {
  BanksDevice(this.fin, {String Function()? newId})
    : data = loadBankDataSync() {
    banks = BanksRepository(fin.device.store);
    notifications = NotificationStore(
      fin.device.db,
      now: () => fin.device.clock.now,
      newId: newId,
    );
    pipeline = BankPipeline(
      loadData: () async => data,
      store: fin.device.store,
      finance: fin.finance,
      banks: banks,
      notifications: notifications,
    );
    drafts = BankDrafts(
      loadData: () async => data,
      store: fin.device.store,
      finance: fin.finance,
      banks: banks,
    );
    importer = StatementImporter(store: fin.device.store, finance: fin.finance);
  }

  static Future<BanksDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    String Function()? newId,
  }) async => BanksDevice(
    await FinanceDevice.create(server, clock: clock, newId: newId),
    newId: newId,
  );

  final FinanceDevice fin;
  final BankData data;
  late final BanksRepository banks;
  late final NotificationStore notifications;
  late final BankPipeline pipeline;
  late final BankDrafts drafts;
  late final StatementImporter importer;

  ManualClock get clock => fin.device.clock;

  Future<void> close() => fin.close();
}

/// Переопределения для экранов Банков: данные из файлов, поддельные
/// платформа, API и выбор файла.
List<Override> banksOverrides({
  BankPlatform? platform,
  StatementsApi? api,
  StatementFileSource? files,
}) => [
  bankDataProvider.overrideWith((ref) async => loadBankDataSync()),
  if (platform != null) bankPlatformProvider.overrideWithValue(platform),
  if (api != null) statementsApiProvider.overrideWithValue(api),
  if (files != null) statementFileSourceProvider.overrideWithValue(files),
];

/// Запускает приложение на экране Банков (маршруты `/finance/banks/...`).
Future<ProviderContainer> pumpBanks(
  WidgetTester tester, {
  String location = '/finance/banks',
  Size size = phoneSize,
  bool seed = false,
  BankPlatform? platform,
  StatementsApi? api,
  StatementFileSource? files,
  Future<void> Function(ProviderContainer container)? seedWith,
  List<Override> overrides = const [],
}) => pumpFinance(
  tester,
  size: size,
  location: location,
  seed: seed,
  seedWith: seedWith,
  overrides: [
    ...banksOverrides(platform: platform, api: api, files: files),
    ...overrides,
  ],
);

/// Нетипизированный перехват исключений API для проверок текстов ошибок.
ApiException httpError(String code, {int status = 422}) => ApiException(
  kind: ApiErrorKind.http,
  status: status,
  code: code,
  message: code,
);
