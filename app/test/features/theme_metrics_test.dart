import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

import '../support/pump_app.dart';

/// Размеры и стили из 02, 2.3 / 2.9.1: кнопки 48/36, поля 52/40, кольцо
/// фокуса 2 px + зазор 2 px, модальные окна на мобиле — радиус 28.
void main() {
  const route = '/settings/server';

  double heightOf(WidgetTester tester, Finder f) => tester.getSize(f).height;

  Finder inner(String key) => find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(TextField),
  );

  testWidgets('телефон: кнопка 48, поле 52', (tester) async {
    await pumpApp(tester, location: route);
    expect(heightOf(tester, find.byKey(const Key('save-button'))), 48);
    expect(heightOf(tester, find.byKey(const Key('check-button'))), 48);
    expect(heightOf(tester, inner('server-url-field')), 52);
  });

  testWidgets('десктоп: кнопка 36, поле 40', (tester) async {
    await pumpApp(tester, size: desktopSize, location: route);
    expect(heightOf(tester, find.byKey(const Key('save-button'))), 36);
    expect(heightOf(tester, find.byKey(const Key('check-button'))), 36);
    expect(heightOf(tester, inner('server-url-field')), 40);
    // «Создать» в левой панели тоже стандартной десктопной высоты.
    expect(heightOf(tester, find.byKey(const Key('create-button'))), 36);
  });

  testWidgets('кольцо фокуса: 2 px, зазор 2 px, только в фокусе', (
    tester,
  ) async {
    await pumpApp(tester, location: route);
    final ring = find.descendant(
      of: find.byKey(const Key('server-url-field')),
      matching: find.byKey(const Key('focus-ring')),
    );
    BoxDecoration deco() =>
        tester.widget<DecoratedBox>(ring).decoration as BoxDecoration;
    BorderSide border() => (deco().border! as Border).top;

    expect(border().color, Colors.transparent);
    expect(border().width, 2);

    await tester.tap(find.byKey(const Key('server-url-field')));
    await tester.pumpAndSettle();
    expect(border().color, context(tester).colors.borderFocus);
    expect(border().width, 2);

    // Зазор 2 px между кольцом и полем.
    final ringRect = tester.getRect(ring);
    final fieldRect = tester.getRect(
      find.descendant(of: ring, matching: find.byType(TextField)),
    );
    expect(fieldRect.left - ringRect.left, 4);
    expect(fieldRect.top - ringRect.top, 4);

    // Ушли с поля — кольцо погасло, размер не менялся.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(border().color, Colors.transparent);
    expect(tester.getRect(ring), ringRect);
  });

  testWidgets('радиус модальных окон: 28 на телефоне, 20 на десктопе', (
    tester,
  ) async {
    double radius(ThemeData t) =>
        ((t.dialogTheme.shape! as RoundedRectangleBorder).borderRadius
                as BorderRadius)
            .topLeft
            .x;

    await pumpApp(tester);
    final phone = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(radius(phone), 28);
    final sheet =
        (phone.bottomSheetTheme.shape! as RoundedRectangleBorder).borderRadius
            as BorderRadius;
    expect(sheet.topLeft.x, 28);

    await pumpApp(tester, size: desktopSize);
    final desktop = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(radius(desktop), 20);
  });
}

BuildContext context(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first);
