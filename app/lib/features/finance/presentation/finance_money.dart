import 'package:flutter/widgets.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';

/// Так выглядит любая сумма Финансов в режиме «скрыть суммы» (и под замком).
const String hiddenMoneyText = '•••• ₽';

/// То же на оси графика (там «₽» не пишут).
const String hiddenAxisText = '••••';

/// Режим «скрыть суммы» для поддерева. Кладётся над приложением
/// (`MyTaskerApp`), поэтому действует и в окнах поверх навигатора: листах,
/// диалогах, снекбарах. Виджеты Финансов читают его через `context.money`.
class AmountsVisibility extends InheritedWidget {
  const AmountsVisibility({
    required this.hidden,
    required super.child,
    super.key,
  });

  final bool hidden;

  /// Скрыты ли суммы; без [AmountsVisibility] в дереве — нет.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AmountsVisibility>()?.hidden ??
      false;

  @override
  bool updateShouldNotify(AmountsVisibility oldWidget) =>
      hidden != oldWidget.hidden;
}

/// Единая точка показа сумм Финансов: все экраны, листы, диалоги и подписи
/// форматируют деньги только через неё (сырой `moneyText` — внутри неё и
/// для текста полей ввода). Тест «единая точка форматирования сумм» в
/// `test/features/finance/privacy/hide_amounts_test.dart` следит, чтобы
/// обходных вызовов не появилось (и чтобы заголовки корзины в
/// `finance_sync_specs.dart` не содержали сумм).
extension FinanceMoneyContext on BuildContext {
  bool get amountsHidden => AmountsVisibility.of(this);

  /// «1 234,56 ₽» или `•••• ₽`.
  String money(int kopecks, {bool signed = false}) =>
      amountsHidden ? hiddenMoneyText : moneyText(kopecks, signed: signed);

  /// Сумма операции со знаком по виду или `•••• ₽`.
  String transactionAmount(FinanceTransaction t) =>
      amountsHidden ? hiddenMoneyText : transactionAmountText(t);
}
