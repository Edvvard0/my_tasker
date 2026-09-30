import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/shell/app_router.dart';

/// Корневой виджет приложения.
class MyTaskerApp extends ConsumerWidget {
  const MyTaskerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'My Tasker',
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(routerProvider),
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // Шкала шрифтов зависит от класса ширины (мобильная / десктопная).
      builder: (context, child) => Theme(
        data: AppTheme.dark(context.windowClass),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
