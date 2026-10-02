import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/model_manager.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/local_ai/presentation/local_models_screen.dart';

import '../support/pump_app.dart';

/// Golden-тесты Этапа 10: экран «Офлайн-модель» (телефон) в трёх состояниях.
/// Эталоны — `files/*.png`; обновление:
/// `flutter test --update-goldens test/goldens/stage10_goldens_test.dart`.
const int _gib = 1024 * 1024 * 1024;

final LocalModelsActions _noop = LocalModelsActions(
  onWifiOnly: (_) {},
  onDownload: (_) {},
  onDownloadCellular: (_) {},
  onPause: (_) {},
  onDiscardPartial: (_) {},
  onDelete: (_) {},
  onBenchmark: () {},
);

Future<void> _pump(WidgetTester tester, LocalModelsViewData data) async {
  tester.view
    ..physicalSize = phoneSize
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Офлайн-модель', style: context.text.h1),
                  const SizedBox(height: 12),
                  LocalModelsBody(data: data, actions: _noop),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

LocalModelsViewData _data(
  LocalModelState? state, {
  bool supported = true,
  int used = 0,
}) => LocalModelsViewData(
  supported: supported,
  unsupportedReason:
      'Офлайн-модель недоступна на этой платформе: она работает только на '
      'Android. Используйте облачный чат.',
  states: state == null ? const {} : {gemma4E2b.id: state},
  wifiOnly: true,
  usedBytes: used,
  freeBytes: 38 * _gib,
  totalRamBytes: 8 * _gib,
  availableRamBytes: 4 * _gib,
);

Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

void main() {
  group('Офлайн-модель', () {
    testWidgets('идёт скачивание (телефон)', (tester) async {
      await _pump(
        tester,
        _data(
          const LocalModelState(
            phase: LocalModelPhase.downloading,
            receivedBytes: 1700 * 1024 * 1024,
            totalBytes: 2600 * 1024 * 1024,
          ),
          used: 1700 * 1024 * 1024,
        ),
      );
      await _shot(tester, 'local_models_downloading_phone');
    });

    testWidgets('скачана, сумма не закреплена (телефон)', (tester) async {
      await _pump(
        tester,
        _data(
          const LocalModelState(
            phase: LocalModelPhase.ready,
            receivedBytes: 2600 * 1024 * 1024,
            totalBytes: 2600 * 1024 * 1024,
            sha256:
                '9f2c4ab17d03e5586ab9c1d4e7f08a3b'
                '5c6d7e8f9012a3b4c5d6e7f8091a2b3c',
            fileBytes: 2600 * 1024 * 1024,
          ),
          used: 2600 * 1024 * 1024,
        ),
      );
      await _shot(tester, 'local_models_ready_phone');
    });

    testWidgets('платформа без модели, Windows (телефонная ширина)', (
      tester,
    ) async {
      await _pump(tester, _data(null, supported: false));
      await _shot(tester, 'local_models_unsupported_phone');
    });
  });
}
