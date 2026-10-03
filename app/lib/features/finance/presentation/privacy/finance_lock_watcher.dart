import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';

/// Сообщает замку «Финансов», где пользователь: в разделе или нет, на
/// переднем плане приложение или свёрнуто. Из этого замок выводит момент
/// «ушёл» и взводит блокировку по выбранному времени.
///
/// Свёрнутым считаем `hidden`/`paused`/`detached`: `inactive` (шторка,
/// системный диалог, потеря фокуса окна на десктопе) приложение не прячет.
class FinanceLockWatcher extends ConsumerStatefulWidget {
  const FinanceLockWatcher({
    required this.inFinance,
    required this.child,
    super.key,
  });

  /// Открыт раздел «Финансы».
  final bool inFinance;
  final Widget child;

  @override
  ConsumerState<FinanceLockWatcher> createState() => _FinanceLockWatcherState();
}

class _FinanceLockWatcherState extends ConsumerState<FinanceLockWatcher>
    with WidgetsBindingObserver {
  late final FinanceLockController _lock;

  @override
  void initState() {
    super.initState();
    _lock = ref.read(financeLockProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    // Провайдеры нельзя менять во время сборки: сообщаем после кадра.
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  @override
  void didUpdateWidget(FinanceLockWatcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inFinance != widget.inFinance) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Оболочка ушла из дерева (например, открыта сетка «Разделы»): в разделе
    // «Финансы» пользователя больше нет. Ref после dispose недоступен,
    // поэтому замок взят заранее, а сообщаем после размонтирования.
    final lock = _lock;
    unawaited(Future.microtask(() => lock.setSectionActive(value: false)));
    super.dispose();
  }

  void _report() {
    if (!mounted) return;
    ref
        .read(financeLockProvider.notifier)
        .setSectionActive(value: widget.inFinance);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
    ref.read(financeLockProvider.notifier).setForeground(value: foreground);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Закрывает всё, что висит поверх навигатора, в момент блокировки
/// «Финансов» (замок сменился «открыт» -> «закрыт»: «заблокировать сейчас»,
/// таймер, сворачивание): листы и панели редакторов, диалоги, выпадающие
/// выборы и снекбары. Иначе открытый редактор операции (с введённой суммой,
/// счётом, комментарием) пережил бы блокировку; несохранённый черновик при
/// этом пропадает.
///
/// Закрываются только окна поверх страниц — `PopupRoute` без `Page`.
/// Страницы самого роутера не трогаются. Стоит выше роутера, поэтому
/// работает и когда оболочки (`AppShell`) нет в дереве.
class FinanceLockDismisser extends ConsumerWidget {
  const FinanceLockDismisser({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  /// Корневой навигатор приложения: на нём открываются листы и диалоги.
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  /// Окно поверх страниц: его можно закрыть, не ломая стек роутера.
  static bool _isOverlay(Route<dynamic> route) =>
      route is PopupRoute && route.settings is! Page<dynamic>;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(financeLockProvider.select((s) => s.closed), (was, closed) {
      if (was != false || !closed) return;
      navigatorKey.currentState?.popUntil((route) => !_isOverlay(route));
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    });
    return child;
  }
}
