import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_env.dart';

void main() {
  testWidgets('пустая «Учёба»: предложение добавить семестр', (tester) async {
    await pumpStudy(tester);
    expect(find.byKey(const Key('study-empty')), findsOneWidget);
    expect(find.text('Семестра пока нет'), findsOneWidget);
  });

  testWidgets('обзор: плитки, сегодняшние занятия и ссылки', (tester) async {
    await pumpStudy(tester, seed: true);
    expect(find.byKey(const Key('study-overview')), findsOneWidget);
    expect(find.text('Чётная'), findsWidgets);
    expect(find.text('Математический анализ'), findsWidgets);
  });
}
