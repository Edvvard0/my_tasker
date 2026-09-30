import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_models.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_remote.dart';
import 'package:my_tasker/features/sync/presentation/conflicts_screen.dart';

import '../support/pump_app.dart';
import '../support/ui_helpers.dart';

final _now = DateTime.utc(2026, 10, 1, 12);
const route = '/settings/sync/conflicts';

SyncConflict _conflict(
  String id, {
  ConflictKind kind = ConflictKind.field,
  Object? losing = 'моё',
  Object? winning = 'чужое',
  DateTime? reverted,
  String key = 'ui.theme',
  Duration ago = const Duration(hours: 1),
}) => SyncConflict(
  id: id,
  createdAt: _now.subtract(ago),
  table: 'user_settings',
  rowId: userSettingsId(key),
  field: kind == ConflictKind.field ? 'value' : 'deleted_at',
  kind: kind,
  losingValue: losing,
  winningValue: winning,
  revertedAt: reverted,
);

SyncConflict _revertedC1(String _) => _conflict('c1', reverted: _now);

class _Remote implements SyncRemote {
  _Remote(this.pages);

  final List<ConflictsPage> pages;
  Exception? conflictsError;
  Exception? revertError;
  Completer<void>? gate;
  final List<String?> requestedBefore = [];
  SyncConflict Function(String id)? onRevert;
  SyncChange? change;

  @override
  Future<ConflictsPage> conflicts({
    String reverted = 'all',
    int limit = 50,
    String? before,
  }) async {
    requestedBefore.add(before);
    await gate?.future;
    if (conflictsError != null) throw conflictsError!;
    return pages[requestedBefore.length - 1];
  }

  @override
  Future<RevertResult> revert(String conflictId) async {
    if (revertError != null) throw revertError!;
    return RevertResult(conflict: onRevert!(conflictId), change: change!);
  }

  @override
  Future<PushResponse> push(List<Json> ops) => throw UnimplementedError();

  @override
  Future<PullPage> pull({required int since, required int limit}) =>
      throw UnimplementedError();
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _Remote remote, {
    Size size = phoneSize,
    bool settle = true,
    List<Override> extra = const [],
  }) async {
    await pumpApp(
      tester,
      size: size,
      location: route,
      now: _now,
      settle: settle,
      overrides: [
        syncRemoteProvider.overrideWithValue(remote),
        syncCoordinatorProvider.overrideWith(CountingCoordinator.new),
        ...extra,
      ],
    );
  }

  testWidgets('загрузка: скелетон', (tester) async {
    final remote = _Remote([const ConflictsPage(conflicts: [])])
      ..gate = Completer<void>();
    await open(tester, remote);
    expect(find.byKey(const Key('list-skeleton')), findsOneWidget);
    remote.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('list-skeleton')), findsNothing);
  });

  testWidgets('пусто: «Конфликтов не было»', (tester) async {
    await open(tester, _Remote([const ConflictsPage(conflicts: [])]));
    expect(find.text('Конфликтов не было'), findsOneWidget);
  });

  testWidgets('данные: тексты по видам конфликта', (tester) async {
    await open(
      tester,
      _Remote([
        ConflictsPage(
          conflicts: [
            _conflict('c1'),
            _conflict(
              'c2',
              kind: ConflictKind.resurrected,
              losing: {'deleted_at': 'x'},
              winning: {'deleted_at': null},
              ago: const Duration(days: 2),
            ),
            _conflict(
              'c3',
              kind: ConflictKind.editVsDelete,
              losing: {'value': 5},
              winning: {'deleted_at': 'x'},
            ),
            _conflict('c4', kind: ConflictKind.parentDeleted),
            _conflict('c5', reverted: _now, key: 'z'),
          ],
        ),
      ]),
    );
    expect(find.byKey(const Key('conflicts-list')), findsOneWidget);
    expect(
      find.textContaining('Поле «value» изменили на двух устройствах'),
      findsNWidgets(2),
    );
    expect(
      find.textContaining('Правка новее — запись осталась'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Удаление новее: запись в корзине'),
      findsOneWidget,
    );
    expect(find.textContaining('внутри удалённого объекта'), findsOneWidget);
    expect(find.text('моё'), findsNWidgets(2));
    expect(find.text('чужое'), findsNWidgets(2));
    expect(find.text('ВОЗВРАЩЕНО'), findsOneWidget);
    // «Вернуть моё» — у обычных, не у возвращённого и не у parent_deleted
    expect(find.byKey(const Key('revert-c1')), findsOneWidget);
    expect(find.byKey(const Key('revert-c2')), findsOneWidget);
    expect(find.byKey(const Key('revert-c3')), findsOneWidget);
    expect(find.byKey(const Key('revert-c4')), findsNothing);
    expect(find.byKey(const Key('revert-c5')), findsNothing);
    expect(find.text('1 ч назад'), findsNothing);
  });

  testWidgets('ошибка: «Повторить»', (tester) async {
    final remote =
        _Remote([
            const ConflictsPage(conflicts: []),
            const ConflictsPage(conflicts: []),
          ])
          ..conflictsError = const ApiException(
            kind: ApiErrorKind.http,
            status: 500,
          );
    await open(tester, remote);
    expect(find.byKey(const Key('conflicts-error')), findsOneWidget);
    remote.conflictsError = null;
    await tester.tap(find.byKey(const Key('conflicts-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Конфликтов не было'), findsOneWidget);
  });

  testWidgets('офлайн: журнал хранится на сервере', (tester) async {
    final remote = _Remote([const ConflictsPage(conflicts: [])])
      ..conflictsError = const ApiException.network();
    await open(tester, remote);
    expect(find.byKey(const Key('conflicts-offline')), findsOneWidget);
  });

  testWidgets('«Показать ещё» подгружает следующую страницу', (tester) async {
    final remote = _Remote([
      ConflictsPage(conflicts: [_conflict('c1')], nextBefore: 'c1'),
      ConflictsPage(conflicts: [_conflict('c0', key: 'old')]),
    ]);
    await open(tester, remote);
    await tester.ensureVisible(find.byKey(const Key('conflicts-more')));
    await tester.tap(find.byKey(const Key('conflicts-more')));
    await tester.pumpAndSettle();
    expect(remote.requestedBefore, [null, 'c1']);
    expect(find.byKey(const Key('conflict-c0')), findsOneWidget);
    expect(find.byKey(const Key('conflicts-more')), findsNothing);
  });

  testWidgets('ошибка подгрузки: сообщение, кнопка остаётся', (tester) async {
    final remote = _Remote([
      ConflictsPage(conflicts: [_conflict('c1')], nextBefore: 'c1'),
      const ConflictsPage(conflicts: []),
    ]);
    await open(tester, remote);
    remote.conflictsError = const ApiException.network();
    await tester.ensureVisible(find.byKey(const Key('conflicts-more')));
    await tester.tap(find.byKey(const Key('conflicts-more')));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить ещё'), findsOneWidget);
    expect(find.byKey(const Key('conflicts-more')), findsOneWidget);
  });

  group('«Вернуть моё»', () {
    Future<_Remote> withRow(WidgetTester tester) async {
      final remote = _Remote([
        ConflictsPage(conflicts: [_conflict('c1')]),
      ]);
      await open(tester, remote);
      return remote;
    }

    testWidgets('успех: значение применено локально, запись помечена', (
      tester,
    ) async {
      final remote = await withRow(tester);
      final id = userSettingsId('ui.theme');
      remote
        ..onRevert = _revertedC1
        ..change = SyncChange(
          table: 'user_settings',
          id: id,
          serverVersion: 9,
          row: {
            'id': id,
            'created_at': '2026-10-01T00:00:00.000Z',
            'updated_at':
                '000000000000500-00000-0195f2a0-0000-7000-8000-00000000000b',
            'deleted_at': null,
            'server_version': 9,
            'origin_device_id': '0195f2a0-0000-7000-8000-00000000000b',
            'key': 'ui.theme',
            'value': 'моё',
          },
        );
      await tester.tap(find.byKey(const Key('revert-c1')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Вернули ваше значение'), findsOneWidget);
      expect(find.text('ВОЗВРАЩЕНО'), findsOneWidget);
      expect(find.byKey(const Key('revert-c1')), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      final row = await tester.runAsync(
        () => container.read(syncStoreProvider).getRow('user_settings', id),
      );
      expect(row!['value'], 'моё');
      expect(row['server_version'], 9);
    });

    for (final (code, text) in [
      ('conflict_already_reverted', 'Это значение уже возвращено'),
      ('row_not_found', 'Записи больше нет на сервере'),
      ('not_revertable', 'Для этого конфликта возврат не поддерживается'),
      ('revert_rejected', 'Сервер не принял значение: оно больше не подходит'),
    ]) {
      testWidgets('ошибка $code', (tester) async {
        final remote = await withRow(tester);
        remote.revertError = ApiException(
          kind: ApiErrorKind.http,
          status: 409,
          code: code,
        );
        await tester.tap(find.byKey(const Key('revert-c1')));
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget);
      });
    }

    testWidgets('нет сети и прочие сбои', (tester) async {
      final remote = await withRow(tester);
      remote.revertError = const ApiException.network();
      await tester.tap(find.byKey(const Key('revert-c1')));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось вернуть: нет соединения'), findsOneWidget);
      // кнопка снова доступна
      expect(find.byKey(const Key('revert-c1')), findsOneWidget);
      remote.revertError = const ApiException(
        kind: ApiErrorKind.http,
        status: 500,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.byKey(const Key('revert-c1')));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось вернуть значение'), findsOneWidget);
    });
  });

  testWidgets('подпись записи берётся из локальной строки', (tester) async {
    final remote = _Remote([
      ConflictsPage(conflicts: [_conflict('c1')]),
    ]);
    final container = await pumpApp(
      tester,
      location: route,
      now: _now,
      overrides: [
        syncRemoteProvider.overrideWithValue(remote),
        syncCoordinatorProvider.overrideWith(CountingCoordinator.new),
      ],
    );
    expect(find.text('Настройка'), findsOneWidget);
    await tester.runAsync(
      () => container.read(syncStoreProvider).create(
        'user_settings',
        userSettingsId('ui.theme'),
        {'key': 'ui.theme', 'value': 'x'},
      ),
    );
    container.invalidate(syncRemoteProvider);
  });

  test('describeValue сокращает длинные значения', () {
    expect(describeValue('abc'), 'abc');
    expect(describeValue({'a': 1}), '{"a":1}');
    expect(describeValue('x' * 100).length, 80);
    expect(describeValue(null), 'null');
  });
}
