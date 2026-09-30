import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Допуск на различие пикселей в golden-тестах (доля от всех пикселей).
///
/// Golden-файлы генерируются на Linux (CI ubuntu). Допуск 0,1 % гасит
/// микроразличия антиалиасинга между версиями драйвера/движка, но реальное
/// изменение вёрстки (сдвиг, другой цвет, пропавший элемент) его превышает.
const double goldenTolerance = 0.001;

/// Подменяет стандартный компаратор на терпимый к [goldenTolerance].
void installTolerantGoldenComparator() {
  final current = goldenFileComparator;
  if (current is LocalFileComparator) {
    goldenFileComparator = _TolerantComparator(current);
  }
}

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(LocalFileComparator base)
    : super(Uri.parse('${base.basedir}dummy_test.dart'));

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (!result.passed && result.diffPercent <= goldenTolerance * 100) {
      return true;
    }
    if (!result.passed) {
      final error = await generateFailureOutput(result, golden, basedir);
      throw FlutterError(error);
    }
    return true;
  }
}
