import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Случаи одного файла общих векторов
/// (`../shared-test-vectors/<домен>/<файл>` относительно `app/`).
/// Падает, если файла нет или в нём нет случаев.
List<Map<String, Object?>> loadVectors(String domain, String file) {
  final path = '../shared-test-vectors/$domain/$file';
  final f = File(path);
  if (!f.existsSync()) fail('Файл векторов не найден: $path');
  final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  final cases = (json['cases']! as List<Object?>).cast<Map<String, Object?>>();
  if (cases.isEmpty) fail('В $path нет случаев');
  return cases;
}

/// Имена всех `*.json` домена на диске.
List<String> vectorFiles(String domain) {
  final dir = Directory('../shared-test-vectors/$domain');
  if (!dir.existsSync()) fail('Нет каталога векторов ${dir.path}');
  return dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.json'))
      .toList()
    ..sort();
}

bool isErrorExpected(Object? expected) =>
    expected is Map && expected['error'] == true;
