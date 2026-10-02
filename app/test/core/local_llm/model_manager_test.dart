import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/model_downloader.dart';
import 'package:my_tasker/core/local_llm/model_manager.dart';
import 'package:my_tasker/core/local_llm/network_probe.dart';

import '../../support/fake_llm.dart';

final List<int> _content = List.generate(64, (i) => (i * 7 + 3) % 251);
final String _hash = sha256.convert(_content).toString();

LocalModelSpec _spec({
  String? sha,
  bool exact = false,
  int? size,
  int minTotal = 6 * 1024 * 1024 * 1024,
  int minAvailable = 3 * 1024 * 1024 * 1024,
}) => LocalModelSpec(
  id: 't',
  name: 'Тестовая модель',
  engineId: 'fake',
  fileName: 'm.bin',
  url: 'https://example.test/m.bin',
  sizeBytes: size ?? _content.length,
  sizeIsExact: exact,
  sha256: sha,
  licenseName: 'Тест',
  licenseUrl: 'https://example.test',
  minTotalRamBytes: minTotal,
  minAvailableRamBytes: minAvailable,
  contextTokens: 1024,
);

Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('условие не наступило');
}

void main() {
  late Directory dir;
  late FakeDownloader downloader;
  late FakeResources resources;
  late FakeNetwork network;
  late bool wifiOnly;
  late bool inUse;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('local_models_test');
    downloader = FakeDownloader(_content);
    resources = FakeResources();
    network = FakeNetwork();
    wifiOnly = true;
    inUse = false;
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  LocalModelManager make(
    LocalModelSpec spec, {
    int retries = 0,
    int reserve = 0,
  }) => LocalModelManager(
    modelsDir: () async => dir,
    downloader: downloader,
    resources: resources,
    network: network,
    wifiOnly: () async => wifiOnly,
    catalog: [spec],
    freeSpaceReserveBytes: reserve,
    progressStepBytes: 1,
    maxAutoRetries: retries,
    retryDelay: Duration.zero,
    isInUse: (_) => inUse,
  );

  File file(String name) => File('${dir.path}/$name');

  group('загрузка', () {
    test('скачивание, проверка SHA-256, публикация и метка', () async {
      final manager = make(_spec(sha: _hash));
      final seen = <LocalModelPhase>[];
      final sub = manager.states.listen((s) => seen.add(s['t']!.phase));
      await manager.start('t');
      await manager.whenIdle('t');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final state = manager.stateOf('t');
      expect(state.phase, LocalModelPhase.ready);
      expect(state.sha256, _hash);
      expect(file('m.bin').readAsBytesSync(), _content);
      expect(file('m.bin.part').existsSync(), isFalse);
      expect(file('m.bin.ok').readAsStringSync(), '${_content.length} $_hash');
      expect(
        seen,
        containsAllInOrder([
          LocalModelPhase.downloading,
          LocalModelPhase.verifying,
          LocalModelPhase.ready,
        ]),
      );
      expect((await manager.modelFile('t'))?.path, file('m.bin').path);
    });

    test('без закреплённой суммы: считается и показывается', () async {
      final manager = make(_spec());
      await manager.start('t');
      await manager.whenIdle('t');
      expect(manager.stateOf('t').sha256, _hash);
      expect(manager.stateOf('t').isReady, isTrue);
    });

    test('неверный SHA-256: файл удалён, ошибка', () async {
      final manager = make(_spec(sha: 'ab' * 32));
      await manager.start('t');
      await manager.whenIdle('t');
      final state = manager.stateOf('t');
      expect(state.phase, LocalModelPhase.failed);
      expect(state.failure!.kind, LocalModelFailureKind.shaMismatch);
      expect(file('m.bin').existsSync(), isFalse);
      expect(file('m.bin.part').existsSync(), isFalse);
      expect(file('m.bin.ok').existsSync(), isFalse);
    });

    test('точный размер не совпал: файл удалён', () async {
      final manager = make(_spec(exact: true, size: _content.length + 10));
      await manager.start('t');
      await manager.whenIdle('t');
      expect(
        manager.stateOf('t').failure!.kind,
        LocalModelFailureKind.sizeMismatch,
      );
      expect(file('m.bin.part').existsSync(), isFalse);
    });

    test('ошибка сервера: без повторов, частичного файла нет', () async {
      downloader.failure = const DownloadFailure(
        DownloadFailureKind.http,
        'Сервер ответил кодом 404',
        statusCode: 404,
      );
      final manager = make(_spec(), retries: 3);
      await manager.start('t');
      await manager.whenIdle('t');
      expect(manager.stateOf('t').failure!.kind, LocalModelFailureKind.http);
      expect(downloader.calls, 1);
    });
  });

  group('докачка', () {
    test('обрыв оставляет часть файла; повторный запуск продолжает', () async {
      downloader.dropAfter = 24;
      final manager = make(_spec(sha: _hash));
      await manager.start('t');
      await manager.whenIdle('t');
      var state = manager.stateOf('t');
      expect(state.phase, LocalModelPhase.failed);
      expect(state.failure!.kind, LocalModelFailureKind.network);
      expect(file('m.bin.part').lengthSync(), 24);

      await manager.start('t');
      await manager.whenIdle('t');
      state = manager.stateOf('t');
      expect(state.isReady, isTrue);
      expect(downloader.resumePoints, [0, 24]);
      expect(file('m.bin').readAsBytesSync(), _content);
    });

    test('автоповтор при обрыве: одна команда доводит до конца', () async {
      downloader.dropAfter = 20;
      final manager = make(_spec(sha: _hash), retries: 2);
      await manager.start('t');
      await manager.whenIdle('t');
      expect(manager.stateOf('t').isReady, isTrue);
      expect(downloader.resumePoints.length, 2);
      expect(downloader.resumePoints.last, greaterThanOrEqualTo(20));
    });

    test('сервер без Range: файл переписывается с нуля и сходится', () async {
      downloader
        ..dropAfter = 24
        ..supportsRange = false;
      final manager = make(_spec(sha: _hash), retries: 1);
      await manager.start('t');
      await manager.whenIdle('t');
      expect(manager.stateOf('t').isReady, isTrue);
      expect(file('m.bin').readAsBytesSync(), _content);
    });

    test('пауза сохраняет часть файла, затем продолжение', () async {
      downloader.holdAt = 16;
      final manager = make(_spec(sha: _hash));
      await manager.start('t');
      await eventually(() => manager.stateOf('t').receivedBytes >= 16);
      await manager.pause('t');
      var state = manager.stateOf('t');
      expect(state.phase, LocalModelPhase.partial);
      expect(file('m.bin.part').lengthSync(), greaterThanOrEqualTo(16));

      await manager.start('t');
      await manager.whenIdle('t');
      state = manager.stateOf('t');
      expect(state.isReady, isTrue);
      expect(downloader.resumePoints.last, greaterThanOrEqualTo(16));
    });

    test('удаление недокачанного освобождает место', () async {
      downloader.dropAfter = 12;
      final manager = make(_spec());
      await manager.start('t');
      await manager.whenIdle('t');
      expect(await manager.usedBytes(), 12);
      await manager.discardPartial('t');
      expect(manager.stateOf('t').phase, LocalModelPhase.notDownloaded);
      expect(await manager.usedBytes(), 0);
    });
  });

  group('место и память', () {
    test('не хватает места: загрузка не начинается', () async {
      resources.free = 10;
      final manager = make(_spec());
      await manager.start('t');
      await manager.whenIdle('t');
      final failure = manager.stateOf('t').failure!;
      expect(failure.kind, LocalModelFailureKind.notEnoughSpace);
      expect(failure.message, contains('Не хватает места'));
      expect(downloader.calls, 0);
    });

    test(
      'запас места сверх размера учитывается, докачка считает остаток',
      () async {
        resources.free = _content.length + 5;
        final manager = make(_spec(), reserve: 100);
        await manager.start('t');
        await manager.whenIdle('t');
        expect(
          manager.stateOf('t').failure!.kind,
          LocalModelFailureKind.notEnoughSpace,
        );

        // Часть уже скачана: нужно меньше.
        file('m.bin.part').writeAsBytesSync(_content.sublist(0, 60));
        resources.free = 4 + 100;
        await manager.refresh();
        await manager.start('t');
        await manager.whenIdle('t');
        expect(manager.stateOf('t').isReady, isTrue);
      },
    );

    test('неизвестное свободное место не блокирует', () async {
      resources.free = null;
      final manager = make(_spec());
      await manager.start('t');
      await manager.whenIdle('t');
      expect(manager.stateOf('t').isReady, isTrue);
    });

    test('проверка ОЗУ перед запуском', () async {
      final spec = _spec();
      final manager = make(spec);

      resources.totalRam = 4 * 1024 * 1024 * 1024;
      var check = await manager.checkCanRun('t');
      expect(check.canRun, isFalse);
      expect(check.failure!.kind, LocalModelFailureKind.notEnoughTotalRam);

      resources
        ..totalRam = 8 * 1024 * 1024 * 1024
        ..availableRam = 1024 * 1024 * 1024;
      check = await manager.checkCanRun('t');
      expect(check.failure!.kind, LocalModelFailureKind.notEnoughAvailableRam);
      expect(check.failure!.message, contains('Закройте другие приложения'));

      resources.availableRam = 4 * 1024 * 1024 * 1024;
      expect((await manager.checkCanRun('t')).canRun, isTrue);

      resources
        ..totalRam = null
        ..availableRam = null;
      expect((await manager.checkCanRun('t')).canRun, isTrue);
    });

    test('занятое и свободное место', () async {
      final manager = make(_spec());
      resources.free = 12345;
      expect(await manager.freeBytes(), 12345);
      expect(await manager.usedBytes(), 0);
      await manager.start('t');
      await manager.whenIdle('t');
      expect(
        await manager.usedBytes(),
        _content.length + file('m.bin.ok').lengthSync(),
      );
    });
  });

  group('сеть: только Wi-Fi', () {
    test(
      'на мобильной сети ждёт Wi-Fi и сама стартует, когда он появился',
      () async {
        network.kind = NetworkKind.cellular;
        final manager = make(_spec(sha: _hash));
        await manager.start('t');
        await eventually(
          () => manager.stateOf('t').phase == LocalModelPhase.waitingForNetwork,
        );
        expect(downloader.calls, 0);

        network.set(NetworkKind.wifi);
        await manager.whenIdle('t');
        expect(manager.stateOf('t').isReady, isTrue);
      },
    );

    test('одноразовое разрешение мобильной сети', () async {
      network.kind = NetworkKind.cellular;
      final manager = make(_spec());
      await manager.start('t', allowCellular: true);
      await manager.whenIdle('t');
      expect(manager.stateOf('t').isReady, isTrue);
    });

    test(
      'настройка «только Wi-Fi» выключена: мобильная сеть годится',
      () async {
        network.kind = NetworkKind.cellular;
        wifiOnly = false;
        final manager = make(_spec());
        await manager.start('t');
        await manager.whenIdle('t');
        expect(manager.stateOf('t').isReady, isTrue);
      },
    );

    test('кабельная сеть считается безлимитной', () async {
      network.kind = NetworkKind.ethernet;
      final manager = make(_spec());
      await manager.start('t');
      await manager.whenIdle('t');
      expect(manager.stateOf('t').isReady, isTrue);
    });

    test('VPN/неизвестная сеть при «только Wi-Fi» — ждёт', () async {
      network.kind = NetworkKind.other;
      final manager = make(_spec());
      await manager.start('t');
      await eventually(
        () => manager.stateOf('t').phase == LocalModelPhase.waitingForNetwork,
      );
      await manager.pause('t');
    });

    test('Wi-Fi пропал посреди загрузки: пауза, потом докачка', () async {
      downloader.holdAt = 16;
      final manager = make(_spec(sha: _hash));
      await manager.start('t');
      await eventually(() => manager.stateOf('t').receivedBytes >= 16);
      network.set(NetworkKind.cellular);
      await eventually(
        () => manager.stateOf('t').phase == LocalModelPhase.waitingForNetwork,
      );
      expect(file('m.bin.part').lengthSync(), greaterThanOrEqualTo(16));

      network.set(NetworkKind.wifi);
      await manager.whenIdle('t');
      expect(manager.stateOf('t').isReady, isTrue);
      expect(downloader.resumePoints.last, greaterThanOrEqualTo(16));
      expect(file('m.bin').readAsBytesSync(), _content);
    });

    test(
      'нет сети вообще: ошибка с понятным текстом, часть файла цела',
      () async {
        network.kind = NetworkKind.none;
        final manager = make(_spec());
        await manager.start('t');
        await manager.whenIdle('t');
        final failure = manager.stateOf('t').failure!;
        expect(failure.kind, LocalModelFailureKind.noNetwork);
        expect(failure.message, contains('Нет сети'));
      },
    );
  });

  group('диск: сканирование и удаление', () {
    test('refresh находит готовую модель и недокачанную', () async {
      final manager = make(_spec(sha: _hash));
      expect(manager.stateOf('t').phase, LocalModelPhase.notDownloaded);

      file('m.bin.part').writeAsBytesSync(_content.sublist(0, 10));
      await manager.refresh();
      expect(manager.stateOf('t').phase, LocalModelPhase.partial);
      expect(manager.stateOf('t').receivedBytes, 10);

      file('m.bin.part').deleteSync();
      file('m.bin').writeAsBytesSync(_content);
      file('m.bin.ok').writeAsStringSync('${_content.length} $_hash');
      await manager.refresh();
      expect(manager.stateOf('t').isReady, isTrue);
    });

    test('файл без метки или с неверной меткой не считается готовым', () async {
      final manager = make(_spec(sha: _hash));
      file('m.bin').writeAsBytesSync(_content);
      await manager.refresh();
      expect(manager.stateOf('t').isReady, isFalse);
      expect(file('m.bin').existsSync(), isFalse);

      file('m.bin').writeAsBytesSync(_content);
      file('m.bin.ok').writeAsStringSync('${_content.length} ${'0' * 64}');
      await manager.refresh();
      expect(manager.stateOf('t').isReady, isFalse);
      expect(file('m.bin.ok').existsSync(), isFalse);

      file('m.bin').writeAsBytesSync(_content);
      file('m.bin.ok').writeAsStringSync('999 $_hash');
      await manager.refresh();
      expect(manager.stateOf('t').isReady, isFalse);
      expect(await manager.modelFile('t'), isNull);
    });

    test('удаление модели убирает все файлы; занятую удалять нельзя', () async {
      final manager = make(_spec());
      await manager.start('t');
      await manager.whenIdle('t');

      inUse = true;
      await expectLater(manager.delete('t'), throwsStateError);
      expect(manager.stateOf('t').isReady, isTrue);

      inUse = false;
      await manager.delete('t');
      expect(manager.stateOf('t').phase, LocalModelPhase.notDownloaded);
      expect(await manager.usedBytes(), 0);
    });

    test('неизвестная модель — ошибка аргумента', () async {
      final manager = make(_spec());
      await expectLater(manager.start('нет'), throwsArgumentError);
    });

    test('повторный start во время загрузки ничего не дублирует', () async {
      downloader.holdAt = 8;
      final manager = make(_spec());
      await manager.start('t');
      await eventually(() => manager.stateOf('t').receivedBytes >= 8);
      await manager.start('t');
      downloader.releaseDownload();
      await manager.whenIdle('t');
      expect(downloader.calls, 1);
      expect(manager.stateOf('t').isReady, isTrue);
    });

    test(
      'готовая модель: start ничего не делает; каталог по умолчанию',
      () async {
        final manager = make(_spec());
        await manager.start('t');
        await manager.whenIdle('t');
        await manager.start('t');
        expect(downloader.calls, 1);
        expect(localModelById('gemma-4-e2b-it'), isNotNull);
        expect(localModelByWireId('local/gemma-4-e2b-it'), isNotNull);
        expect(localModelByWireId('openai/gpt-4o'), isNull);
        expect(localModelByWireId(null), isNull);
        expect(formatBytes(2600 * 1024 * 1024), '2,5 ГБ');
        expect(formatBytes(340 * 1024 * 1024), '340 МБ');
      },
    );
  });
}
