import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Подключает тексты лицензий OFL встроенных шрифтов к `LicenseRegistry`
/// (они видны на странице лицензий Flutter).
void registerFontLicenses({AssetBundle? bundle}) {
  const files = {'Inter': 'assets/fonts/licenses/Inter-OFL.txt'};
  LicenseRegistry.addLicense(() async* {
    for (final entry in files.entries) {
      final text = await (bundle ?? rootBundle).loadString(entry.value);
      yield LicenseEntryWithLineBreaks([entry.key], text);
    }
  });
}
