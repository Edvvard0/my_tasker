import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/shell/app_router.dart';
import 'package:my_tasker/features/work/application/timer_providers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import 'calendar_env.dart' show appRegistry;
import 'fake_server/fake_sync_server.dart';
import 'manual_clock.dart';
import 'pump_app.dart';
import 'sync_env.dart';

/// «Сейчас» для экранов «Работы»: среда, 30 сентября 2026, 11:40 по Москве
/// (как в макетах дизайн-системы).
final DateTime workNow = DateTime.utc(2026, 9, 30, 8, 40);

/// Момент по Москве (UTC+3).
DateTime msk(int y, int m, int d, [int h = 12, int min = 0]) =>
    DateTime.utc(y, m, d, h - 3, min);

/// Запускает приложение на экране «Работа» с зафиксированным временем и
/// поясом Москвы; [seed] наполняет демо-данными, [seedWith] — своими.
/// [fixedClock] `false` — часы задаёт тест своим переопределением.
Future<ProviderContainer> pumpWork(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/work',
  bool seed = false,
  DateTime? now,
  bool fixedClock = true,
  Future<void> Function(ProviderContainer container)? seedWith,
  List<Override> overrides = const [],
}) async {
  final container = await pumpApp(
    tester,
    size: size,
    location: location,
    now: fixedClock ? (now ?? workNow) : null,
    settle: false,
    overrides: [
      deviceTimeZoneSourceProvider.overrideWithValue(
        const FixedTimeZoneSource('Europe/Moscow'),
      ),
      ...overrides,
    ],
  );
  await tester.runAsync(() async {
    if (seed) await seedWorkDemo(container);
    if (seedWith != null) await seedWith(container);
  });
  await tester.pumpAndSettle();
  return container;
}

/// Идентификаторы демо-данных.
class WorkDemo {
  const WorkDemo({
    required this.roma,
    required this.elena,
    required this.bot,
    required this.creora,
    required this.saas,
    required this.botLogin,
    required this.botUpload,
  });

  final String roma;
  final String elena;
  final String bot;
  final String creora;
  final String saas;
  final String botLogin;
  final String botUpload;
}

/// Демо-данные по макетам дизайн-системы (02, 5.4 и 6.6): заказчики Рома и
/// Елена; проект «Бот разборов ИИ» (26 000 ₽, оплачено 21 000, остаток
/// 5 000), «Платформа Creora» (80 000, оплачено 24 500, остаток 55 500),
/// «SaaS Лены» (20 000, без оплат). Мне должны всего 80 500 ₽: Рома 25 000,
/// Елена 55 500. В сентябре получено 19 000 ₽.
Future<WorkDemo> seedWorkDemo(ProviderContainer container) async {
  final repo = container.read(workRepositoryProvider);

  Future<String> person(String name, PersonRole role) async {
    final id = repo.newId();
    await repo.createPerson(WorkPerson(id: id, name: name, role: role));
    return id;
  }

  final roma = await person('Рома', PersonRole.client);
  final elena = await person('Елена', PersonRole.client);

  Future<String> project(
    String title, {
    required String client,
    required int base,
    String? deadline,
  }) async {
    final id = repo.newId();
    await repo.createProject(
      WorkProject(
        id: id,
        title: title,
        clientId: client,
        status: ProjectStatus.active,
        baseAmount: base,
        deadlineDate: deadline,
      ),
    );
    return id;
  }

  final bot = await project(
    'Бот разборов ИИ',
    client: roma,
    base: 2000000,
    deadline: '2026-10-15',
  );
  final creora = await project(
    'Платформа Creora',
    client: elena,
    base: 8000000,
    deadline: '2026-11-30',
  );
  final saas = await project('SaaS Лены', client: roma, base: 2000000);

  Future<String> cr(
    String project,
    String title,
    int amount, {
    ChangeRequestStatus status = ChangeRequestStatus.inProgress,
    String? closed,
  }) async {
    final id = repo.newId();
    await repo.createChangeRequest(
      ChangeRequest(
        id: id,
        projectId: project,
        title: title,
        amount: amount,
        status: status,
        closedDate: closed,
      ),
    );
    return id;
  }

  final botLogin = await cr(bot, 'Доработка входа в бот', 200000);
  final botUpload = await cr(bot, 'Выгрузка роликов в канал', 400000);

  Future<void> pay(
    DateTime at,
    int amount,
    String payer,
    List<AllocationDraft> allocations,
  ) => repo
      .createPayment(
        Payment(id: repo.newId(), paidAt: at, amount: amount, payerId: payer),
        allocations,
      )
      .then((_) {});

  await pay(msk(2026, 8, 20), 1200000, roma, [
    AllocationDraft(projectId: bot, amount: 1200000),
  ]);
  await pay(msk(2026, 9, 10), 900000, roma, [
    AllocationDraft(projectId: bot, amount: 800000),
    AllocationDraft(projectId: bot, changeRequestId: botLogin, amount: 100000),
  ]);
  await pay(msk(2026, 8, 25), 1450000, elena, [
    AllocationDraft(projectId: creora, amount: 1450000),
  ]);
  await pay(msk(2026, 9, 12), 1000000, elena, [
    AllocationDraft(projectId: creora, amount: 1000000),
  ]);

  Future<void> hours(String project, DateTime start, int minutes) => repo
      .addManualEntry(
        TimeEntry(
          id: repo.newId(),
          projectId: project,
          startedAt: start,
          endedAt: start.add(Duration(minutes: minutes)),
          billable: true,
          source: TimeSource.manual,
        ),
      )
      .then((_) {});

  await hours(bot, msk(2026, 8, 18, 10), 240);
  await hours(bot, msk(2026, 9, 14, 10), 300);
  await hours(bot, msk(2026, 9, 21, 10), 300);
  await hours(creora, msk(2026, 9, 15, 10), 480);
  await hours(creora, msk(2026, 9, 22, 10), 480);
  await hours(creora, msk(2026, 9, 29, 10), 480);

  return WorkDemo(
    roma: roma,
    elena: elena,
    bot: bot,
    creora: creora,
    saas: saas,
    botLogin: botLogin,
    botUpload: botUpload,
  );
}

/// Устройство с репозиторием «Работы» поверх [TestDevice] (тесты
/// синхронизации).
class WorkDevice {
  WorkDevice(this.device, {String Function()? newId})
    : work = WorkRepository(
        device.store,
        newId: newId,
        now: () => device.clock.now,
      );

  static Future<WorkDevice> create(
    FakeSyncServer server, {
    ManualClock? clock,
    String Function()? newId,
  }) async => WorkDevice(
    await TestDevice.create(server, clock: clock, registry: appRegistry()),
    newId: newId,
  );

  final TestDevice device;
  final WorkRepository work;

  Future<void> close() => device.close();
}

/// Текст с неразрывными пробелами, как его выводит `formatAmount`:
/// в тестах суммы пишутся с обычными пробелами (`'25 000 ₽'`).
String nb(String text) => text.replaceAll(' ', '\u00A0');

/// Текущий маршрут: адрес верхнего видимого экрана (в том числе
/// открытого через `push`).
String locationOf(WidgetTester tester) =>
    GoRouterState.of(tester.element(find.byType(ScreenScaffold).last)).uri
        .toString();

/// Идентификатор проекта по названию (данные уже загружены экраном).
String projectIdOf(ProviderContainer container, String title) => container
    .read(workDataProvider)
    .requireValue
    .projects
    .firstWhere((p) => p.title == title)
    .id;

/// Переходит на экран по адресу (как `go`) и ждёт завершения анимаций.
Future<void> goTo(
  WidgetTester tester,
  ProviderContainer container,
  String location,
) async {
  container.read(routerProvider).go(location);
  await tester.pumpAndSettle();
}

/// Нажимает на виджет и ждёт завершения анимаций.
Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

/// Тик таймера без настоящих часов: тест двигает «секундомер» вручную.
class ManualTimerTick extends TimerTickNotifier {
  @override
  DateTime build() => ref.read(clockProvider)().toUtc();

  // Метод, а не сеттер: тест вызывает его как команду «тик».
  // ignore: use_setters_to_change_properties
  void set(DateTime moment) => state = moment;
}

/// Переопределения для тестов таймера: подвижные часы и ручной тик.
class TimerClock {
  TimerClock(this.moment);

  DateTime moment;

  List<Override> get overrides => [
    clockProvider.overrideWithValue(() => moment),
    timerTickProvider.overrideWith(ManualTimerTick.new),
  ];

  /// Сдвигает часы и «секундомер» интерфейса.
  void advance(ProviderContainer container, Duration d) {
    moment = moment.add(d);
    (container.read(timerTickProvider.notifier) as ManualTimerTick).set(moment);
  }
}
