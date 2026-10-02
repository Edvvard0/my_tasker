import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/model_manager.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/local_ai/presentation/local_models_screen.dart';

class _Calls {
  final List<String> log = [];

  LocalModelsActions get actions => LocalModelsActions(
    onWifiOnly: (v) => log.add('wifi:$v'),
    onDownload: (s) => log.add('download:${s.id}'),
    onDownloadCellular: (s) => log.add('cellular:${s.id}'),
    onPause: (s) => log.add('pause:${s.id}'),
    onDiscardPartial: (s) => log.add('discard:${s.id}'),
    onDelete: (s) => log.add('delete:${s.id}'),
    onBenchmark: () => log.add('benchmark'),
  );
}

const int _gib = 1024 * 1024 * 1024;

Widget _host(LocalModelsViewData data, _Calls calls) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: LocalModelsBody(data: data, actions: calls.actions),
    ),
  ),
);

LocalModelsViewData _data(
  LocalModelState? state, {
  bool supported = true,
  bool wifiOnly = true,
}) => LocalModelsViewData(
  supported: supported,
  unsupportedReason: supported
      ? null
      : 'Офлайн-модель работает только на Android.',
  states: state == null ? const {} : {gemma4E2b.id: state},
  wifiOnly: wifiOnly,
  freeBytes: 40 * _gib,
  totalRamBytes: 8 * _gib,
  availableRamBytes: 4 * _gib,
);

void main() {
  testWidgets('не скачана: место, ОЗУ, кнопка «Скачать»', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_host(_data(null), calls));
    expect(find.text('Gemma 4 E2B (русский, офлайн)'), findsOneWidget);
    expect(find.byKey(const Key('local-storage')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('local-storage'))).data,
      contains('свободно: 40,0 ГБ'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('local-ram'))).data,
      contains('8,0 ГБ'),
    );
    await tester.tap(find.byKey(const Key('local-download')));
    expect(calls.log, ['download:${gemma4E2b.id}']);
    expect(find.byKey(const Key('local-delete')), findsNothing);
  });

  testWidgets('переключатель Wi-Fi вызывает действие', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_host(_data(null), calls));
    await tester.tap(find.byKey(const Key('local-wifi-only')));
    expect(calls.log, ['wifi:false']);
  });

  testWidgets('скачивание: прогресс и «Пауза»', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host(
        _data(
          const LocalModelState(
            phase: LocalModelPhase.downloading,
            receivedBytes: 1 * _gib,
            totalBytes: 2 * _gib,
          ),
        ),
        calls,
      ),
    );
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('local-progress')),
    );
    expect(bar.value, 0.5);
    expect(
      find.byWidgetPredicate(
        (w) => w is StatusPill && w.label == 'Скачивание 50%',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('local-pause')));
    expect(calls.log, ['pause:${gemma4E2b.id}']);
  });

  testWidgets('ждёт Wi-Fi: можно разрешить мобильную сеть или остановить', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host(
        _data(
          const LocalModelState(
            phase: LocalModelPhase.waitingForNetwork,
            receivedBytes: 300 * 1024 * 1024,
            totalBytes: 2 * _gib,
          ),
        ),
        calls,
      ),
    );
    expect(find.textContaining('появится Wi-Fi'), findsOneWidget);
    await tester.tap(find.byKey(const Key('local-cellular')));
    await tester.tap(find.byKey(const Key('local-pause')));
    expect(calls.log, ['cellular:${gemma4E2b.id}', 'pause:${gemma4E2b.id}']);
  });

  testWidgets('недокачана: продолжить или удалить недокачанное', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host(
        _data(
          const LocalModelState(
            phase: LocalModelPhase.partial,
            receivedBytes: 500 * 1024 * 1024,
            totalBytes: 2 * _gib,
          ),
        ),
        calls,
      ),
    );
    await tester.tap(find.byKey(const Key('local-resume')));
    await tester.tap(find.byKey(const Key('local-discard')));
    expect(calls.log, ['download:${gemma4E2b.id}', 'discard:${gemma4E2b.id}']);
  });

  testWidgets('ошибка: текст причины и «Повторить»', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host(
        _data(
          const LocalModelState(
            phase: LocalModelPhase.failed,
            failure: LocalModelFailure(
              LocalModelFailureKind.notEnoughSpace,
              'Не хватает места: нужно 2,8 ГБ, свободно 1,0 ГБ',
            ),
          ),
        ),
        calls,
      ),
    );
    expect(
      find.text('Не хватает места: нужно 2,8 ГБ, свободно 1,0 ГБ'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('local-resume')));
    expect(calls.log, ['download:${gemma4E2b.id}']);
    expect(find.byKey(const Key('local-discard')), findsNothing);
  });

  testWidgets('скачана: тест, удаление, незакреплённая сумма копируется', (
    tester,
  ) async {
    final calls = _Calls();
    final sha = 'ab12' * 16;
    await tester.pumpWidget(
      _host(
        _data(
          LocalModelState(
            phase: LocalModelPhase.ready,
            receivedBytes: 2 * _gib,
            totalBytes: 2 * _gib,
            sha256: sha,
            fileBytes: 2 * _gib,
          ),
        ),
        calls,
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('local-checksum'))).data,
      contains('не закреплена'),
    );
    expect(find.byKey(const Key('local-copy-sha')), findsOneWidget);
    await tester.tap(find.byKey(const Key('local-benchmark')));
    await tester.tap(find.byKey(const Key('local-delete')));
    expect(calls.log, ['benchmark', 'delete:${gemma4E2b.id}']);
  });

  testWidgets('платформа без модели: пояснение и никаких действий', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(_host(_data(null, supported: false), calls));
    expect(find.byKey(const Key('local-unsupported')), findsOneWidget);
    expect(find.textContaining('только на Android'), findsOneWidget);
    expect(find.byKey(const Key('local-download')), findsNothing);
    expect(find.byKey(const Key('local-delete')), findsNothing);
  });

  test('подписи статусов', () {
    expect(modelStatus(LocalModelState.absent).$1, 'Не скачана');
    expect(
      modelStatus(const LocalModelState(phase: LocalModelPhase.verifying)).$1,
      'Проверка',
    );
    expect(
      modelStatus(const LocalModelState(phase: LocalModelPhase.downloading)).$1,
      'Скачивание',
    );
  });
}
