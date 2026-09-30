import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Источник текущего времени. В тестах подменяется управляемым.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
