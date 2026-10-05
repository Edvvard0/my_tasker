import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/study_env.dart';

/// Golden-тесты Этапа 7 (только ключевые экраны, 04, 2.4): экран предмета,
/// карточка долга и редактор расписания на демо-данных (понедельник,
/// 5 октября 2026). Эталоны — `files/study_*.png`; обновление:
/// `flutter test --update-goldens test/goldens`.
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

void main() {
  group('Учёба: экран предмета', () {
    testWidgets('телефон', (tester) async {
      await pumpStudyDemo(tester, at: (d) => '/study/subjects/${d.math}');
      expect(find.byKey(const Key('subject-screen')), findsOneWidget);
      await _shot(tester, 'study_subject_phone');
    });

    testWidgets('десктоп', (tester) async {
      await pumpStudyDemo(
        tester,
        size: desktopSize,
        at: (d) => '/study/subjects/${d.math}',
      );
      await _shot(tester, 'study_subject_desktop');
    });
  });

  group('Учёба: карточка долга', () {
    testWidgets('телефон', (tester) async {
      await pumpStudyDemo(tester, at: (d) => '/study/debts/${d.lab1}');
      expect(find.byKey(const Key('debt-screen')), findsOneWidget);
      await _shot(tester, 'study_debt_phone');
    });
  });

  group('Учёба: редактор расписания', () {
    testWidgets('пары (телефон)', (tester) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule/edit');
      expect(find.byKey(const Key('schedule-editor')), findsOneWidget);
      await _shot(tester, 'study_editor_slots_phone');
    });

    testWidgets('особые дни (телефон)', (tester) async {
      await pumpStudyDemo(tester, at: (_) => '/study/schedule/edit');
      await tapKey(tester, 'editor-tab-rules');
      await _shot(tester, 'study_editor_rules_phone');
    });
  });
}
