import 'package:flutter/services.dart';
import 'package:my_tasker/core/theme/app_typography.dart';

/// Загружает настоящие шрифты приложения (Inter, Lucide) в
/// тестовый движок. Без этого golden-тесты рисуют текст шрифтом Ahem.
///
/// Файлы берутся из ассетов приложения, поэтому картинка одинакова на любой
/// машине (не зависит от системных шрифтов).
Future<void> loadAppFonts() async {
  final byFamily = <String, FontLoader>{};
  for (final (family, _, asset) in AppFonts.files) {
    byFamily
        .putIfAbsent(family, () => FontLoader(family))
        .addFont(rootBundle.load(asset));
  }
  final lucide = FontLoader('packages/lucide_icons_flutter/Lucide')
    ..addFont(
      rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
    );
  for (final loader in [...byFamily.values, lucide]) {
    await loader.load();
  }
}
