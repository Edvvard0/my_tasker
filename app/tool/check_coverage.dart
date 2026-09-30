// Проверка порога покрытия строк по `coverage/lcov.info`.
//
// Запуск (из каталога app/):
//   dart tool/check_coverage.dart [--min=90] [--lcov=coverage/lcov.info]
//
// Учитываются файлы `lib/**/*.dart`, кроме сгенерированных (`*.g.dart`,
// `*.freezed.dart`). Файл, которого нет в lcov (ни один тест его не
// загрузил), считается полностью непокрытым — иначе непротестированный код
// незаметно выпадал бы из отчёта.
import 'dart:io';

const _generatedSuffixes = ['.g.dart', '.freezed.dart', '.drift.dart'];

bool _isGenerated(String path) => _generatedSuffixes.any(path.endsWith);

/// Оценка числа исполняемых строк файла, которого нет в lcov: строки-
/// операторы (оканчиваются на `;`), кроме объявлений констант и директив.
/// Файл только с константами даёт 0 и на итог не влияет.
int _countCodeLines(File file) => file
    .readAsLinesSync()
    .map((l) => l.trim())
    .where(
      (l) =>
          l.endsWith(';') &&
          !l.startsWith('//') &&
          !l.startsWith('import ') &&
          !l.startsWith('export ') &&
          !l.startsWith('part ') &&
          !l.startsWith('library') &&
          !l.startsWith('static const') &&
          !l.startsWith('const ') &&
          !l.startsWith('final ') &&
          !l.startsWith('static final '),
    )
    .length;

void main(List<String> args) {
  var min = 90.0;
  var lcovPath = 'coverage/lcov.info';
  for (final arg in args) {
    if (arg.startsWith('--min=')) min = double.parse(arg.substring(6));
    if (arg.startsWith('--lcov=')) lcovPath = arg.substring(7);
  }

  final lcov = File(lcovPath);
  if (!lcov.existsSync()) {
    stderr.writeln('Нет $lcovPath: сначала `flutter test --coverage`.');
    exit(2);
  }

  // path -> (найдено строк, покрыто строк)
  final files = <String, ({int found, int hit})>{};
  String? current;
  var found = 0;
  var hit = 0;
  for (final line in lcov.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      current = line.substring(3).replaceAll(r'\', '/');
      found = 0;
      hit = 0;
    } else if (line.startsWith('DA:')) {
      found++;
      if (int.parse(line.substring(3).split(',')[1]) > 0) hit++;
    } else if (line == 'end_of_record' && current != null) {
      files[current] = (found: found, hit: hit);
      current = null;
    }
  }

  // Файлы lib/, не попавшие в отчёт.
  final missing = <String>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\', '/');
    if (_isGenerated(path)) continue;
    if (!files.keys.any((k) => k == path || k.endsWith('/$path'))) {
      missing.add(path);
      files[path] = (found: _countCodeLines(entity), hit: 0);
    }
  }

  var totalFound = 0;
  var totalHit = 0;
  final rows = <(String, int, int)>[];
  files.forEach((path, v) {
    if (_isGenerated(path)) return;
    totalFound += v.found;
    totalHit += v.hit;
    rows.add((path, v.hit, v.found));
  });

  rows.sort((a, b) {
    double ratio((String, int, int) r) => r.$3 == 0 ? 1 : r.$2 / r.$3;
    return ratio(a).compareTo(ratio(b));
  });
  for (final (path, h, f) in rows.take(8)) {
    final pct = f == 0 ? 100.0 : h * 100 / f;
    stdout.writeln('  ${pct.toStringAsFixed(1).padLeft(5)}%  $h/$f  $path');
  }
  if (missing.isNotEmpty) {
    stdout.writeln('Не загружены ни одним тестом: ${missing.join(', ')}');
  }

  final percent = totalFound == 0 ? 100.0 : totalHit * 100 / totalFound;
  stdout.writeln(
    'Покрытие строк (без сгенерированных): '
    '${percent.toStringAsFixed(2)}% ($totalHit/$totalFound), порог $min%',
  );
  if (percent < min) {
    stderr.writeln('Покрытие ниже порога.');
    exit(1);
  }
}
