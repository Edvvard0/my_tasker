import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_elevation.dart';
import 'package:my_tasker/core/theme/app_motion.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/theme/app_typography.dart';
import 'package:my_tasker/core/theme/font_licenses.dart';

double _luminance(Color c) => c.computeLuminance();

double _contrast(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('WindowClass (брейкпоинты из 02)', () {
    test('границы классов', () {
      expect(WindowClass.fromWidth(390), WindowClass.compact);
      expect(WindowClass.fromWidth(599.9), WindowClass.compact);
      expect(WindowClass.fromWidth(600), WindowClass.medium);
      expect(WindowClass.fromWidth(1023), WindowClass.medium);
      expect(WindowClass.fromWidth(1024), WindowClass.expanded);
      expect(WindowClass.fromWidth(1439), WindowClass.expanded);
      expect(WindowClass.fromWidth(1440), WindowClass.large);
      expect(WindowClass.fromWidth(2560), WindowClass.large);
    });

    test('поля и высота верхней панели', () {
      expect(WindowClass.compact.gutter, 16);
      expect(WindowClass.medium.gutter, 24);
      expect(WindowClass.expanded.gutter, 24);
      expect(WindowClass.large.gutter, 32);
      expect(WindowClass.compact.topBarHeight, 56);
      expect(WindowClass.large.topBarHeight, 64);
      expect(WindowClass.compact.isDesktopScale, isFalse);
      expect(WindowClass.medium.isDesktopScale, isTrue);
    });
  });

  group('токены', () {
    const c = AppColors.dark;

    test('значения совпадают с 02_DESIGN_SYSTEM', () {
      expect(c.bgBase, const Color(0xFF000000));
      expect(c.surface1, const Color(0xFF141414));
      expect(c.surface2, const Color(0xFF1C1C1C));
      expect(c.surface3, const Color(0xFF262626));
      expect(c.surface4, const Color(0xFF3A3A3A));
      expect(c.surfaceInverse, const Color(0xFFFFFFFF));
      expect(c.textPrimary, const Color(0xFFFFFFFF));
      expect(c.textSecondary, const Color(0xFFA6A6A6));
      expect(c.textTertiary, const Color(0xFF8F8F8F));
      expect(c.accent, const Color(0xFF0A84FF));
      expect(c.borderFocus, c.accent);
      expect(c.danger, const Color(0xFFF0625A));
      expect(AppColors.chartSeries, hasLength(4));
      expect(AppColors.chartSeries.first, c.accent);
      expect(AppColors.heat, hasLength(5));
    });

    test('палитра: только серые, один синий и функциональный красный', () {
      bool isGray(Color x) => x.r == x.g && x.g == x.b;
      final grays = [
        c.bgBase,
        c.surface1,
        c.surface2,
        c.surface3,
        c.surface4,
        c.surfaceInverse,
        c.borderSubtle,
        c.borderDefault,
        c.borderStrong,
        c.textPrimary,
        c.textSecondary,
        c.textTertiary,
        c.textDisabled,
        c.textOnInverse,
        AppColors.chartOther,
        ...AppColors.heat,
        ...AppColors.chartSeries.skip(1),
      ];
      for (final g in grays) {
        expect(isGray(g), isTrue, reason: '$g должен быть нейтрально-серым');
      }
      expect(isGray(c.accent), isFalse);
      // Красный — только danger-токены.
      expect(c.borderDanger, c.danger);
    });

    test('контраст текста соответствует таблице 2.1.3 (WCAG AA)', () {
      expect(_contrast(c.textPrimary, c.bgBase), greaterThan(20));
      expect(_contrast(c.textSecondary, c.surface1), greaterThan(7));
      // text/tertiary — AA даже на surface/3.
      expect(_contrast(c.textTertiary, c.surface3), greaterThanOrEqualTo(4.5));
      // Белая кнопка с чёрным текстом.
      expect(_contrast(c.textOnInverse, c.surfaceInverse), greaterThan(20));
      // Синий как текст/ссылка — AA на фоне и карточках surface/1, /2.
      expect(_contrast(c.accent, c.bgBase), greaterThanOrEqualTo(4.5));
      expect(_contrast(c.accent, c.surface1), greaterThanOrEqualTo(4.5));
      expect(_contrast(c.accent, c.surface2), greaterThanOrEqualTo(4.5));
      // Как элемент интерфейса (обводка, фокус) — не ниже 3:1 на surface/3.
      expect(_contrast(c.accent, c.surface3), greaterThanOrEqualTo(3));
      // Красный — AA на surface/1 и в пилюле на dangerMuted.
      expect(_contrast(c.danger, c.surface1), greaterThanOrEqualTo(4.5));
      expect(_contrast(c.danger, c.dangerMuted), greaterThanOrEqualTo(4.5));
      // Белая иконка на светло-сером круге активной вкладки.
      expect(_contrast(c.textPrimary, c.surface4), greaterThanOrEqualTo(4.5));
      // Ряды графиков и «Прочее» — графические элементы, >= 3:1 на surface/1.
      for (final s in [...AppColors.chartSeries, AppColors.chartOther]) {
        expect(_contrast(s, c.surface1), greaterThanOrEqualTo(3));
      }
    });

    test('ThemeExtension: copyWith и lerp', () {
      expect(c.copyWith(), same(c));
      expect(c.lerp(null, 0.5), same(c));
      expect(c.lerp(c, 1), same(c));
      final t = AppTextStyles.mobile();
      expect(t.copyWith(), same(t));
      expect(t.lerp(null, 0.5), same(t));
      expect(t.lerp(AppTextStyles.desktop(), 0.9).h1.fontSize, 24);
      expect(t.lerp(AppTextStyles.desktop(), 0.1), same(t));
    });

    test('отступы, радиусы, движение', () {
      expect(AppSpacing.s4, 16);
      expect(AppSpacing.all(4), const EdgeInsets.all(4));
      expect(AppSpacing.floatingBarInset, 124);
      expect(AppRadii.l, 24);
      expect(AppRadii.borderFull.topLeft.x, 999);
      expect(AppMotion.base, const Duration(milliseconds: 220));
      expect(AppMotion.standard.transform(0), 0);
    });

    test('elevation-декорации', () {
      final card = AppElevation.card(c);
      expect(card.color, c.surface1);
      expect((card.borderRadius! as BorderRadius).topLeft.x, 24);
      expect(
        AppElevation.card(c, radius: AppRadii.borderM).borderRadius,
        AppRadii.borderM,
      );
      expect(AppElevation.raised(c).boxShadow, [AppElevation.shadow2]);
      expect(AppElevation.floating(c).boxShadow, [AppElevation.shadow3]);
    });
  });

  group('типографика', () {
    test('мобильная шкала из 02', () {
      final t = AppTextStyles.mobile();
      expect(t.h1.fontSize, 26);
      expect(t.h1.height, closeTo(32 / 26, 1e-9));
      expect(t.h1.fontWeight, FontWeight.w700);
      expect(t.h1.fontFamily, AppFonts.sans);
      expect(t.display.fontFamily, AppFonts.sans);
      expect(t.display.fontSize, 40);
      expect(t.display.fontWeight, FontWeight.w700);
      expect(t.display.fontFeatures, tabularFigures);
      expect(t.tabLabel.fontSize, 11);
      expect(t.overline.letterSpacing, closeTo(11 * 0.06, 1e-9));
      expect(t.numS.fontFamily, AppFonts.sans);
      expect(t.numM.fontFeatures, tabularFigures);
      expect(t.body.fontFeatures, isNull);
    });

    test('десктопная шкала из 02', () {
      final t = AppTextStyles.desktop();
      expect(t.h1.fontSize, 24);
      expect(t.body.fontSize, 14);
      expect(t.numL.fontSize, 16);
    });

    test('forWindow выбирает шкалу по классу ширины', () {
      expect(AppTextStyles.forWindow(WindowClass.compact).h1.fontSize, 26);
      expect(AppTextStyles.forWindow(WindowClass.large).h1.fontSize, 24);
    });

    test('Material TextTheme собран из шкалы', () {
      final tt = AppTextStyles.mobile().toTextTheme();
      expect(tt.bodyMedium!.fontSize, 15);
      expect(tt.headlineLarge!.fontSize, 26);
    });

    test('все файлы шрифтов объявлены в pubspec и загружаются', () async {
      expect(AppFonts.files, hasLength(4));
      for (final (_, _, asset) in AppFonts.files) {
        final data = await rootBundle.load(asset);
        expect(data.lengthInBytes, greaterThan(50 * 1024), reason: asset);
      }
    });
  });

  group('лицензии шрифтов', () {
    test('OFL-тексты попадают в LicenseRegistry', () async {
      registerFontLicenses();
      final entries = await LicenseRegistry.licenses.toList();
      final byPackage = {
        for (final e in entries) ...{
          for (final p in e.packages)
            p: e.paragraphs.map((x) => x.text).join(' '),
        },
      };
      expect(byPackage['Inter'], contains('SIL OPEN FONT LICENSE'));
      expect(byPackage.containsKey('JetBrains Mono'), isFalse);
    });
  });

  test('AppTheme.dark кэширует ThemeData по шкале', () {
    expect(AppTheme.dark(), same(AppTheme.dark()));
    expect(
      AppTheme.dark(WindowClass.medium),
      same(AppTheme.dark(WindowClass.large)),
    );
    expect(AppTheme.dark(), isNot(same(AppTheme.dark(WindowClass.large))));
  });
}
