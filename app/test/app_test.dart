import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/db/database_opener.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/main.dart' as app;

import 'support/pump_app.dart';

void main() {
  testWidgets('main() запускает приложение: без входа — экран входа', (
    tester,
  ) async {
    tester.view
      ..physicalSize = phoneSize
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('main_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => call.method == 'getApplicationSupportDirectory'
                ? dir.path
                : null,
          )
          // Плагин сети: онлайн, поток событий принимается молча.
          ..setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/connectivity'),
            (call) async => ['wifi'],
          )
          ..setMockMethodCallHandler(
            const MethodChannel(
              'dev.fluttercommunity.plus/connectivity_status',
            ),
            (call) async => null,
          );
    addTearDown(() {
      for (final name in [
        'plugins.flutter.io/path_provider',
        'dev.fluttercommunity.plus/connectivity',
        'dev.fluttercommunity.plus/connectivity_status',
      ]) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });

    // Настоящая БД (SQLCipher), настоящие токены (пустые), настоящий роутер.
    app.main();
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Сервер не настроен').evaluate().isNotEmpty) break;
    }

    expect(find.text('Сервер не настроен'), findsOneWidget);
    expect(find.byKey(const Key('login-setup-server')), findsOneWidget);
  });

  test('провайдеры по умолчанию: конфиг и проверка соединения', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(appConfigProvider).appVersion, '0.1.0');
    expect(container.read(connectionCheckerProvider), isA<ConnectionChecker>());
  });

  test('defaultDatabaseFile лежит в каталоге данных приложения', () async {
    final dir = await Directory.systemTemp.createTemp('support_dir');
    addTearDown(() => dir.delete(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => call.method == 'getApplicationSupportDirectory'
                ? dir.path
                : null,
          );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );

    final file = await defaultDatabaseFile();
    expect(file.path, '${dir.path}/my_tasker.sqlite');
  });

  testWidgets('EmptyState показывает иконку, тексты и действие', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: EmptyState(
            icon: LucideIcons.server,
            title: 'Серверов пока нет',
            message: 'Добавь сервер.',
            action: ElevatedButton(
              onPressed: () {},
              child: const Text('Добавить сервер'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Серверов пока нет'), findsOneWidget);
    expect(find.text('Добавь сервер.'), findsOneWidget);
    expect(find.text('Добавить сервер'), findsOneWidget);
    expect(find.byIcon(LucideIcons.server), findsOneWidget);
  });

  testWidgets('StatusPill: текст в верхнем регистре, тон задаёт цвет', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: Column(
            children: [
              StatusPill(label: 'Работает', tone: StatusTone.success),
              StatusPill(label: 'Частично', tone: StatusTone.warning),
              StatusPill(label: 'Лежит', tone: StatusTone.danger),
              StatusPill(label: 'ИИ', tone: StatusTone.info),
              StatusPill(label: 'Нет данных', tone: StatusTone.neutral),
            ],
          ),
        ),
      ),
    );
    expect(find.text('РАБОТАЕТ'), findsOneWidget);
    expect(find.text('НЕТ ДАННЫХ'), findsOneWidget);
    // Смысл дублируется семантикой, а не только цветом.
    expect(find.bySemanticsLabel('Лежит'), findsOneWidget);
  });
}
