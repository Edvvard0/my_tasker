import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';
import '../support/work_env.dart';

/// Golden-тесты Этапа 4: список проектов, карточка проекта и «Мне должны»
/// (телефон и десктоп) на демо-данных по макетам 02, 5.4 и 6.6–6.7.
/// Эталоны — `files/work_*.png`; обновление:
/// `flutter test --update-goldens test/goldens`.
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

void main() {
  group('Работа: список проектов', () {
    testWidgets('телефон', (tester) async {
      await pumpWork(tester, seed: true);
      await _shot(tester, 'work_projects_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpWork(tester, seed: true, size: desktopSize);
      await _shot(tester, 'work_projects_desktop');
    });
  });

  group('Работа: карточка проекта', () {
    testWidgets('телефон', (tester) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(
        tester,
        container,
        '/work/projects/${projectIdOf(container, 'Бот разборов ИИ')}',
      );
      await _shot(tester, 'work_project_phone');
    });

    testWidgets('десктоп', (tester) async {
      final container = await pumpWork(tester, seed: true, size: desktopSize);
      await goTo(
        tester,
        container,
        '/work/projects/${projectIdOf(container, 'Бот разборов ИИ')}',
      );
      await _shot(tester, 'work_project_desktop');
    });
  });

  group('Работа: «Мне должны»', () {
    testWidgets('телефон', (tester) async {
      final container = await pumpWork(tester, seed: true);
      await goTo(tester, container, '/work/receivables');
      await _shot(tester, 'work_receivables_phone');
    });

    testWidgets('десктоп', (tester) async {
      final container = await pumpWork(tester, seed: true, size: desktopSize);
      await goTo(tester, container, '/work/receivables');
      await _shot(tester, 'work_receivables_desktop');
    });
  });
}
