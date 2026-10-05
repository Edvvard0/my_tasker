import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/db/database_bootstrap.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/banks/application/bank_providers.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_service.dart';
import 'package:my_tasker/features/calendar/reminders/reminder_taps.dart';
import 'package:my_tasker/features/recovery/presentation/recovery_screen.dart';
import 'package:my_tasker/features/shell/app_router.dart';
import 'package:my_tasker/features/shell/splash_screen.dart';
import 'package:my_tasker/features/work/application/timer_providers.dart';

/// Корневой виджет приложения.
///
/// Пока БД открывается и читаются токены — заставка; если БД не открылась
/// (потерян ключ) — экран восстановления вместо падения; иначе роутер.
class MyTaskerApp extends ConsumerWidget {
  const MyTaskerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boot = ref.watch(databaseBootstrapProvider);
    final ok = boot.value?.isOk ?? false;
    // Синхронизация стартует сама после входа; без рабочей БД не трогаем её.
    if (ok) {
      ref
        ..watch(syncLifecycleProvider)
        // Локальные напоминания (Этап 2): следят за данными календаря.
        ..watch(reminderLifecycleProvider)
        // Нажатие на напоминание открывает событие или задачу.
        ..watch(reminderTapHandlerProvider)
        // Таймер времени (Этап 4): уведомление/трей и «Стоп» из системы.
        ..watch(timerLifecycleProvider)
        // Банки (Этап 6): уведомления банков -> черновики операций.
        ..watch(bankLifecycleProvider);
    }
    final auth = ok ? ref.watch(authControllerProvider) : const AuthUnknown();
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
      builder: (context, child) {
        final Widget body;
        final failure = boot.value?.failure;
        if (failure != null) {
          // Собственный Navigator: диалоги подтверждения нужен корень выше
          // роутера, которого на этом экране нет.
          body = Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => RecoveryScreen(failure: failure),
            ),
          );
        } else if (!ok || auth is AuthUnknown) {
          body = const SplashScreen();
        } else {
          body = child ?? const SizedBox.shrink();
        }
        return Theme(data: AppTheme.dark(context.windowClass), child: body);
      },
    );
  }
}
