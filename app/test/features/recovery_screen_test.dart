import 'dart:io';

import 'package:drift/drift.dart' show LazyDatabase, QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/token_store.dart';
import 'package:my_tasker/core/db/database_bootstrap.dart';
import 'package:my_tasker/core/db/database_key_store.dart';
import 'package:my_tasker/core/db/database_opener.dart';
import 'package:my_tasker/core/db/database_providers.dart';

import '../support/fakes.dart';
import '../support/in_memory_opener.dart';
import '../support/pump_app.dart';

Finder get _reset => find.byKey(const Key('recovery-reset'));
Finder get _retry => find.byKey(const Key('recovery-retry'));

/// БД, которая не открывается первые [failures] раз.
class _FlakyOpener implements AppDatabaseOpener {
  _FlakyOpener(this.failures);

  int failures;
  int opens = 0;

  @override
  QueryExecutor open() {
    opens++;
    if (failures > 0) {
      failures--;
      return LazyDatabase(() async => throw const FileSystemException('disk'));
    }
    return NativeDatabase.memory();
  }

  @override
  Future<void> resetStorage() async {}
}

class _ThrowingResetOpener extends BrokenUntilResetOpener {
  _ThrowingResetOpener(super.error);

  @override
  Future<void> resetStorage() async {
    resets++;
    throw const FileSystemException('locked');
  }
}

SqliteException get _notADatabase =>
    SqliteException(extendedResultCode: 26, message: 'file is not a database');

void main() {
  group('экран восстановления', () {
    testWidgets('нет ключа: вместо падения — предупреждение и кнопка сброса', (
      tester,
    ) async {
      final opener = BrokenUntilResetOpener(_notADatabase);
      await pumpApp(tester, opener: opener, gated: true);
      expect(find.byKey(const Key('recovery')), findsOneWidget);
      expect(find.text('Не удалось открыть локальные данные'), findsOneWidget);
      expect(find.byKey(const Key('recovery-warning')), findsOneWidget);
      expect(
        find.textContaining('не успели отправиться на сервер'),
        findsOneWidget,
      );
      expect(
        find.text('Сбросить локальные данные и загрузить с сервера'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('floating-tab-bar')), findsNothing);
    });

    testWidgets('сброс: подтверждение, удаление БД, далее вход', (
      tester,
    ) async {
      final opener = BrokenUntilResetOpener(_notADatabase);
      final container = await pumpApp(tester, opener: opener, gated: true);
      await tester.tap(_reset);
      await tester.pumpAndSettle();
      expect(find.text('Сбросить локальные данные?'), findsOneWidget);
      expect(find.textContaining('будет потеряно'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(opener.resets, 1);
      expect(find.byKey(const Key('recovery')), findsNothing);
      // токены стёрты, БД пустая: нужно снова указать сервер и войти
      expect(find.text('Сервер не настроен'), findsOneWidget);
      expect(await container.read(tokenStoreProvider).read(), isNull);
    });

    testWidgets('отмена подтверждения ничего не сбрасывает', (tester) async {
      final opener = BrokenUntilResetOpener(_notADatabase);
      await pumpApp(tester, opener: opener, gated: true);
      await tester.tap(_reset);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(opener.resets, 0);
      expect(find.byKey(const Key('recovery')), findsOneWidget);
    });

    testWidgets('сброс не удался: сообщение, можно повторить', (tester) async {
      final opener = _ThrowingResetOpener(_notADatabase);
      await pumpApp(tester, opener: opener, gated: true);
      await tester.tap(_reset);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-error')), findsOneWidget);
      expect(_reset, findsOneWidget);
      expect(find.byKey(const Key('recovery-progress')), findsNothing);
    });

    testWidgets('БД новее приложения: сброса нет, только «Повторить»', (
      tester,
    ) async {
      final opener = BrokenUntilResetOpener(
        StateError('Схема БД v7 новее приложения (v2). Обновите приложение.'),
      );
      await pumpApp(tester, opener: opener, gated: true);
      expect(find.text('Данные созданы более новой версией'), findsOneWidget);
      expect(_reset, findsNothing);
      expect(find.byKey(const Key('recovery-warning')), findsNothing);
      expect(_retry, findsOneWidget);
    });

    testWidgets('прочая ошибка: «Повторить» открывает БД заново', (
      tester,
    ) async {
      final opener = _FlakyOpener(1);
      await pumpApp(tester, opener: opener, gated: true);
      expect(find.byKey(const Key('recovery')), findsOneWidget);
      expect(_reset, findsOneWidget);
      await tester.tap(_retry);
      await tester.pumpAndSettle();
      expect(opener.opens, greaterThanOrEqualTo(2));
      expect(find.byKey(const Key('recovery')), findsNothing);
      expect(find.text('Здесь будет «Сегодня»'), findsOneWidget);
    });

    testWidgets('десктоп', (tester) async {
      await pumpApp(
        tester,
        size: desktopSize,
        opener: BrokenUntilResetOpener(_notADatabase),
        gated: true,
      );
      expect(find.byKey(const Key('recovery')), findsOneWidget);
    });

    testWidgets('пока БД открывается — заставка', (tester) async {
      await pumpApp(tester, gated: true, settle: false);
      expect(find.byKey(const Key('splash')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('splash')), findsNothing);
    });
  });

  group('потеря ключа с настоящей БД (SQLCipher)', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('recovery_test');
      file = File('${dir.path}/my_tasker.sqlite');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    ProviderContainer container(_MemoryKeys keys) {
      final c = ProviderContainer(
        overrides: [
          databaseOpenerProvider.overrideWithValue(
            EncryptedDatabaseOpener(
              keyStore: keys,
              locateFile: () async => file,
            ),
          ),
          tokenStoreProvider.overrideWithValue(MemoryTokenStore(fakeSession())),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test(
      'ключ пропал: БД не открывается, сброс создаёт новую с новым ключом',
      () async {
        final keys = _MemoryKeys('a' * 64);
        final first = container(keys);
        await first.read(localSettingsRepositoryProvider).write('k', 'v');
        expect(
          (await first.read(databaseBootstrapProvider.future)).isOk,
          isTrue,
        );
        first.dispose();
        expect(file.existsSync(), isTrue);

        // «Хранилище ОС потеряло ключ»: выдаётся другой.
        keys.key = 'b' * 64;
        final lost = container(keys);
        final boot = await lost.read(databaseBootstrapProvider.future);
        expect(boot.isOk, isFalse);
        expect(boot.failure, DatabaseFailureKind.unreadable);

        await lost.read(localDataResetProvider)();
        expect(keys.resets, 1);
        final fresh = await lost.read(databaseBootstrapProvider.future);
        expect(fresh.isOk, isTrue);
        expect(
          await lost.read(localSettingsRepositoryProvider).read('k'),
          isNull,
        );
        expect(await lost.read(tokenStoreProvider).read(), isNull);
        // старые данные физически удалены, а не оставлены нечитаемыми
        lost.dispose();
        final reopened = container(keys);
        expect(
          (await reopened.read(databaseBootstrapProvider.future)).isOk,
          isTrue,
        );
      },
    );

    test('повреждённый ключ в хранилище — тоже «нечитаемо»', () async {
      final keys = _MemoryKeys('a' * 64)..corrupted = true;
      final c = container(keys);
      final boot = await c.read(databaseBootstrapProvider.future);
      expect(boot.failure, DatabaseFailureKind.unreadable);
    });
  });

  test('resetStorage удаляет файл и журналы, ключ создаётся заново', () async {
    final dir = Directory.systemTemp.createTempSync('reset_storage');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/my_tasker.sqlite')..writeAsStringSync('x');
    for (final suffix in ['-wal', '-shm', '-journal']) {
      File('${file.path}$suffix').writeAsStringSync('x');
    }
    final keys = _MemoryKeys('a' * 64);
    await EncryptedDatabaseOpener(
      keyStore: keys,
      locateFile: () async => file,
    ).resetStorage();
    expect(dir.listSync(), isEmpty);
    expect(keys.resets, 1);
    // повторный сброс без файлов не падает
    await EncryptedDatabaseOpener(
      keyStore: keys,
      locateFile: () async => file,
    ).resetStorage();
  });

  test('классификация сбоев БД', () async {
    Future<DatabaseFailureKind?> classify(Object error) async {
      final c = ProviderContainer(
        overrides: [
          databaseOpenerProvider.overrideWithValue(
            BrokenUntilResetOpener(error),
          ),
        ],
      );
      addTearDown(c.dispose);
      return (await c.read(databaseBootstrapProvider.future)).failure;
    }

    expect(await classify(_notADatabase), DatabaseFailureKind.unreadable);
    expect(
      await classify(DatabaseKeyCorruptedException()),
      DatabaseFailureKind.unreadable,
    );
    expect(
      await classify(StateError('Схема БД v9 новее приложения (v2).')),
      DatabaseFailureKind.schemaTooNew,
    );
    expect(
      await classify(const FileSystemException('x')),
      DatabaseFailureKind.other,
    );
    expect(const DatabaseBootstrap.ok().isOk, isTrue);
    expect(InMemoryDatabaseOpener().resets, 0);
  });
}

class _MemoryKeys implements DatabaseKeyStore {
  _MemoryKeys(this.key);

  String key;
  bool corrupted = false;
  int resets = 0;

  @override
  Future<String> getOrCreateKey() async {
    if (corrupted) throw DatabaseKeyCorruptedException();
    return key;
  }

  @override
  Future<String> resetKey() async {
    resets++;
    corrupted = false;
    return key = 'c' * 64;
  }
}
