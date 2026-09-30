import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/app.dart';
import 'package:my_tasker/core/theme/font_licenses.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  runApp(const ProviderScope(child: MyTaskerApp()));
}
