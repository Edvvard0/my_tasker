import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/features/shell/app_router.dart';
import 'package:my_tasker/features/shell/app_section.dart';

import '../support/pump_app.dart';

late ProviderContainer _container;

Future<void> _pump(
  WidgetTester tester, {
  Size size = phoneSize,
  String location = '/today',
}) async {
  _container = await pumpApp(tester, size: size, location: location);
}

/// Текущий маршрут (работает и для экранов вне оболочки, например /sections).
String _location(WidgetTester tester) => _container
    .read(routerProvider)
    .routerDelegate
    .currentConfiguration
    .uri
    .toString();

Finder _nav(AppSection s) => find.byKey(Key('nav-${s.name}'));

/// Активна ли вкладка таб-бара: у активной — пилюля `accent/muted`.
bool _isActive(WidgetTester tester, AppSection s) {
  final box = tester.widget<AnimatedContainer>(
    find.descendant(of: _nav(s), matching: find.byType(AnimatedContainer)),
  );
  return (box.decoration! as BoxDecoration).color == AppColors.dark.accentMuted;
}

/// Заголовок экрана (h1) в верхней панели: отличает его от подписей таб-бара.
Finder _title(String text) =>
    find.descendant(of: find.byType(Scaffold).first, matching: find.text(text));

void main() {
  group('телефон 390×844: плавающий таб-бар', () {
    testWidgets('стартовый экран — «Сегодня», таб-бар с 5 подписями и «+»', (
      tester,
    ) async {
      await _pump(tester);

      expect(_location(tester), '/today');
      expect(find.byKey(const Key('floating-tab-bar')), findsOneWidget);
      expect(find.byKey(const Key('create-fab')), findsOneWidget);
      // Боковой панели и рейла нет.
      expect(find.byKey(const Key('nav-side-panel')), findsNothing);
      expect(find.byKey(const Key('nav-rail')), findsNothing);

      for (final s in AppSection.tabs) {
        expect(_nav(s), findsOneWidget, reason: s.label);
        expect(
          find.descendant(of: _nav(s), matching: find.text(s.label)),
          findsOneWidget,
          reason: 'подпись у ${s.label}',
        );
      }
      expect(_isActive(tester, AppSection.today), isTrue);
      expect(_isActive(tester, AppSection.calendar), isFalse);
      // Учёбы, Сна и Настроек в таб-баре нет.
      expect(_nav(AppSection.study), findsNothing);
      expect(_nav(AppSection.sleep), findsNothing);
      expect(_nav(AppSection.settings), findsNothing);
    });

    testWidgets('таб-бар переключает разделы', (tester) async {
      await _pump(tester);
      const paths = {
        AppSection.calendar: '/calendar',
        AppSection.work: '/work',
        AppSection.finance: '/finance',
        AppSection.ai: '/ai',
        AppSection.today: '/today',
      };
      for (final entry in paths.entries) {
        await tester.tap(_nav(entry.key));
        await tester.pumpAndSettle();
        expect(_location(tester), entry.value);
      }
    });

    testWidgets('«Календарь»: вкладка «Задачи» внутри, а не в таб-баре', (
      tester,
    ) async {
      await _pump(tester, location: '/calendar');
      expect(find.byKey(const Key('segment-calendar')), findsOneWidget);

      await tester.tap(find.byKey(const Key('segment-tasks')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/calendar/tasks');
      expect(find.textContaining('Списки задач'), findsOneWidget);
      // Раздел «Календарь» остаётся активным в таб-баре.
      expect(_isActive(tester, AppSection.calendar), isTrue);
      expect(_isActive(tester, AppSection.today), isFalse);

      await tester.tap(find.byKey(const Key('segment-calendar')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/calendar');
    });

    testWidgets('«Работа»: «Серверы» вложены и ведут назад в «Работу»', (
      tester,
    ) async {
      await _pump(tester, location: '/work');
      await tester.tap(find.byKey(const Key('work-servers-link')));
      await tester.pumpAndSettle();

      expect(_location(tester), '/work/servers');
      expect(find.text('Работа ›'), findsOneWidget);
      expect(_title('Серверы'), findsOneWidget);

      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/work');
    });

    testWidgets('«Разделы» открывают Учёбу, Сон, Серверы и Настройки', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('open-sections')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sections-grid')), findsOneWidget);

      const targets = {
        'study': '/study',
        'sleep': '/sleep',
        'servers': '/work/servers',
        'settings': '/settings',
      };
      for (final entry in targets.entries) {
        if (find.byKey(const Key('sections-grid')).evaluate().isEmpty) {
          await tester.tap(find.byKey(const Key('open-sections')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(Key('section-${entry.key}')));
        await tester.pumpAndSettle();
        expect(_location(tester), entry.value);
        if (entry.key != 'servers') {
          // Для разделов вне таб-бара ни одна вкладка не активна.
          for (final tab in AppSection.tabs) {
            expect(_isActive(tester, tab), isFalse, reason: tab.label);
          }
          await tester.tap(find.byTooltip('Назад'));
          await tester.pumpAndSettle();
          expect(_location(tester), '/sections');
          await tester.tap(find.byTooltip('Назад'));
          await tester.pumpAndSettle();
          expect(_location(tester), '/today');
        } else {
          await tester.tap(find.byTooltip('Назад'));
          await tester.pumpAndSettle();
          await tester.tap(_nav(AppSection.today));
          await tester.pumpAndSettle();
        }
      }
    });

    testWidgets('сетка «Разделы»: стрелка назад возвращает на «Сегодня»', (
      tester,
    ) async {
      await _pump(tester, location: '/sections');
      expect(find.byKey(const Key('sections-grid')), findsOneWidget);
      // Прямой переход на /sections без истории: стрелка ведёт на «Сегодня».
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/today');
    });

    testWidgets('«+» открывает окно «Создать» (заглушка) снизу', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('create-fab')));
      await tester.pumpAndSettle();
      expect(find.text('Создать'), findsOneWidget);
      expect(find.textContaining('Быстрое создание'), findsOneWidget);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.text('Закрыть'), findsNothing);
    });

    testWidgets('корневой адрес / перенаправляет на «Сегодня»', (tester) async {
      await _pump(tester, location: '/');
      expect(_location(tester), '/today');
    });

    testWidgets('крупный шрифт (200 %): подписи неактивных вкладок скрыты', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester);
      // Активна «Сегодня» — её подпись есть, у остальных нет.
      expect(
        find.descendant(
          of: _nav(AppSection.today),
          matching: find.text('Сегодня'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _nav(AppSection.work),
          matching: find.text('Работа'),
        ),
        findsNothing,
      );
    });

    testWidgets('все экраны-заглушки открываются без ошибок', (tester) async {
      const routes = {
        '/today': 'этапе 2',
        '/calendar': 'этапе 2',
        '/calendar/tasks': 'этапе 2',
        '/work': 'этапе 4',
        '/work/servers': 'этапе 9',
        '/finance': 'этапе 5',
        '/ai': 'этапе 3',
        '/study': 'этапе 7',
        '/sleep': 'этапе 8',
      };
      for (final entry in routes.entries) {
        await _pump(tester, location: entry.key);
        expect(
          find.textContaining(entry.value),
          findsOneWidget,
          reason: entry.key,
        );
        expect(tester.takeException(), isNull, reason: entry.key);
      }
    });
  });

  group('десктоп: боковая навигация', () {
    testWidgets('1440×900: левая панель 256 px со всеми разделами', (
      tester,
    ) async {
      await _pump(tester, size: desktopSize);

      expect(find.byKey(const Key('nav-side-panel')), findsOneWidget);
      expect(find.byKey(const Key('floating-tab-bar')), findsNothing);
      expect(find.byKey(const Key('create-fab')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('nav-side-panel'))).width,
        256,
      );

      for (final s in AppSection.values) {
        expect(_nav(s), findsOneWidget, reason: s.label);
        expect(
          find.descendant(of: _nav(s), matching: find.text(s.label)),
          findsOneWidget,
        );
      }
      // «Настройки» — внизу панели, ниже всех остальных разделов.
      final settingsY = tester.getCenter(_nav(AppSection.settings)).dy;
      final sleepY = tester.getCenter(_nav(AppSection.sleep)).dy;
      expect(settingsY, greaterThan(sleepY));
      // «Разделы» на десктопе не нужны.
      expect(find.byKey(const Key('open-sections')), findsNothing);
    });

    testWidgets('переключает все разделы, включая Учёбу, Сон и Настройки', (
      tester,
    ) async {
      await _pump(tester, size: desktopSize);
      for (final s in AppSection.values) {
        await tester.tap(_nav(s));
        await tester.pumpAndSettle();
        expect(_location(tester), s.path, reason: s.label);
      }
    });

    testWidgets('повторный тап по активному разделу возвращает к его корню', (
      tester,
    ) async {
      await _pump(tester, size: desktopSize, location: '/work/servers');
      expect(_location(tester), '/work/servers');
      await tester.tap(_nav(AppSection.work));
      await tester.pumpAndSettle();
      expect(_location(tester), '/work');
    });

    testWidgets('кнопка ≡ сворачивает панель в рейл 72 px и разворачивает', (
      tester,
    ) async {
      await _pump(tester, size: desktopSize);
      await tester.tap(find.byKey(const Key('nav-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-rail')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('nav-rail'))).width, 72);
      // В рейле у иконок остаются подписи.
      expect(
        find.descendant(
          of: _nav(AppSection.finance),
          matching: find.text('Финансы'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('nav-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-side-panel')), findsOneWidget);
    });

    testWidgets('800×600 (Medium): рейл 72 px без кнопки сворачивания', (
      tester,
    ) async {
      await _pump(tester, size: mediumSize);
      expect(find.byKey(const Key('nav-rail')), findsOneWidget);
      expect(find.byKey(const Key('nav-toggle')), findsNothing);
      expect(find.byKey(const Key('floating-tab-bar')), findsNothing);
      // Кнопка «Создать» — круглая иконка.
      expect(find.byKey(const Key('create-button')), findsOneWidget);
      expect(find.text('Создать'), findsNothing);
    });

    testWidgets('1200×800 (Expanded): панель 256 px', (tester) async {
      await _pump(tester, size: expandedSize);
      expect(find.byKey(const Key('nav-side-panel')), findsOneWidget);
    });

    testWidgets('«Создать» на десктопе открывает диалог', (tester) async {
      await _pump(tester, size: desktopSize);
      await tester.tap(find.byKey(const Key('create-button')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('на десктопе у вложенного экрана стрелка «Назад» тоже есть', (
      tester,
    ) async {
      await _pump(tester, size: desktopSize, location: '/work/servers');
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/work');
    });

    testWidgets('Учёба и Сон на десктопе без стрелки «Назад»', (tester) async {
      await _pump(tester, size: desktopSize, location: '/study');
      expect(find.byTooltip('Назад'), findsNothing);
    });
  });
}
