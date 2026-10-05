import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/banks/data/bank_pipeline.dart';
import 'package:my_tasker/features/banks/data/notification_store.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/platform/bank_platform.dart';

/// Связывает слушатель уведомлений и конвейер: при старте и при каждом
/// сигнале платформы (а также при возврате в приложение) забирает
/// накопленные уведомления и обрабатывает их. Белый список пакетов — из
/// правил. На платформах без слушателя (Windows) ничего не делает.
final Provider<void> bankLifecycleProvider = Provider<void>((ref) {
  final platform = ref.watch(bankPlatformProvider);
  if (!platform.isSupported) return;
  var disposed = false;

  Future<void> drain() async {
    if (disposed) return;
    try {
      final items = await platform.drain();
      await ref.read(bankPipelineProvider).ingest(items);
    } on Object {
      // Сбой одной выборки не должен ронять приложение: уведомления
      // остались в очереди на устройстве и будут забраны в следующий раз.
    }
  }

  unawaited(
    ref
        .read(bankDataProvider.future)
        .then(
          (data) => platform.setWatchedPackages(data.notifications.packages),
        )
        .then((_) => drain(), onError: (Object _) {}),
  );
  final wake = platform.wakeups.listen((_) => unawaited(drain()));
  final observer = _ResumeObserver(() => unawaited(drain()));
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() {
    disposed = true;
    unawaited(wake.cancel());
    WidgetsBinding.instance.removeObserver(observer);
  });
});

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this._onResume);

  final void Function() _onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResume();
  }
}

/// Не разобранные уведомления (нет правила, нечитаемая сумма).
final StreamProvider<List<BankNotification>> unrecognizedNotificationsProvider =
    StreamProvider<List<BankNotification>>(
      (ref) => ref
          .watch(notificationStoreProvider)
          .watchByState(NotificationState.unrecognized),
    );

/// Разобранные уведомления, которым нужен счёт.
final StreamProvider<List<BankNotification>> needsAccountNotificationsProvider =
    StreamProvider<List<BankNotification>>(
      (ref) => ref
          .watch(notificationStoreProvider)
          .watchByState(NotificationState.needsAccount),
    );
