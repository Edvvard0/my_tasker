import 'dart:async';

import 'package:flutter/widgets.dart';
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
