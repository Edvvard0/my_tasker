import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';

const int _maxWholeDigits = 12;

/// Автоформат поля суммы (02, 4.4): цифры и один разделитель «,»; разряды
/// группируются неразрывными пробелами на лету, не больше двух знаков после
/// запятой и 12 цифр целой части; «.» превращается в «,». Минус допускается
/// только первым символом и только при [allowNegative]. Курсор остаётся за
/// теми же цифрами.
class AmountInputFormatter extends TextInputFormatter {
  const AmountInputFormatter({this.allowNegative = false});

  final bool allowNegative;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    final caret = newValue.selection.isValid
        ? newValue.selection.extentOffset.clamp(0, raw.length)
        : raw.length;
    var negative = false;
    var whole = '';
    String? fraction;
    // Значащие символы (знак, цифры, запятая) левее курсора.
    var caretSig = 0;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      final before = i < caret;
      if (i == 0 && allowNegative && (ch == '-' || ch == '−')) {
        negative = true;
        if (before) caretSig++;
      } else if (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39) {
        if (fraction != null) {
          if (fraction.length < 2) {
            fraction += ch;
            if (before) caretSig++;
          }
        } else if (whole == '0') {
          // Ведущий ноль заменяется цифрой («05» -> «5»); второй ноль
          // игнорируется.
          if (ch != '0') whole = ch;
        } else if (whole.length < _maxWholeDigits) {
          whole += ch;
          if (before) caretSig++;
        }
      } else if ((ch == ',' || ch == '.') && fraction == null) {
        if (whole.isEmpty) {
          whole = '0';
          if (before) caretSig++;
        }
        fraction = '';
        if (before) caretSig++;
      }
    }
    final out = <(String, bool)>[];
    if (negative) out.add(('−', true));
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) out.add((' ', false));
      out.add((whole[i], true));
    }
    if (fraction != null) {
      out.add((',', true));
      for (final d in fraction.split('')) {
        out.add((d, true));
      }
    }
    var offset = 0;
    var seen = 0;
    while (offset < out.length && seen < caretSig) {
      if (out[offset].$2) seen++;
      offset++;
    }
    return TextEditingValue(
      text: out.map((e) => e.$1).join(),
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

/// Поле суммы (02, 4.4): табличные цифры, выравнивание вправо, цифровая
/// клавиатура, «₽» справа. Значение читается из [controller] через
/// [parseAmountField].
class AmountField extends StatelessWidget {
  const AmountField({
    required this.controller,
    this.onChanged,
    this.allowNegative = false,
    this.autofocus = false,
    this.hint = '0',
    this.errorText,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final bool allowNegative;
  final bool autofocus;
  final String hint;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    return FormTextField(
      controller: controller,
      autofocus: autofocus,
      textAlign: TextAlign.end,
      style: t.kpi.copyWith(fontSize: 26, height: 1.2),
      keyboardType: TextInputType.numberWithOptions(
        decimal: true,
        signed: allowNegative,
      ),
      inputFormatters: [AmountInputFormatter(allowNegative: allowNegative)],
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: t.kpi.copyWith(
          fontSize: 26,
          height: 1.2,
          color: c.textTertiary,
        ),
        suffixText: ' ₽',
        suffixStyle: t.kpi.copyWith(
          fontSize: 26,
          height: 1.2,
          color: c.textSecondary,
        ),
        errorText: errorText,
      ),
    );
  }
}

/// Значение поля суммы в копейках (со знаком); `null` — пусто или не число.
int? parseAmountField(String text) {
  final trimmed = text.trim();
  final fixed = trimmed.endsWith(',')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
  if (fixed.isEmpty) return null;
  final value = tryParseAmount(fixed);
  if (value == null || value.abs() > maxKopecks) return null;
  return value;
}

/// Быстрые чипы под полем суммы: «+1 000», «+5 000» (02, 4.4). Добавляют
/// сумму к текущей.
class AmountChips extends StatelessWidget {
  const AmountChips({
    required this.controller,
    this.onChanged,
    this.keyPrefix = 'amount-chip',
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final String keyPrefix;

  static const List<int> steps = [1000, 5000];

  void _add(int rubles) {
    final current = parseAmountField(controller.text) ?? 0;
    final next = (current + rubles * 100).clamp(-maxKopecks, maxKopecks);
    controller.value = TextEditingValue(
      text: amountInputText(next),
      selection: TextSelection.collapsed(offset: amountInputText(next).length),
    );
    onChanged?.call(controller.text);
  }

  @override
  Widget build(BuildContext context) => ChipRow(
    children: [
      for (final step in steps)
        FilterPill(
          key: Key('$keyPrefix-$step'),
          label: '+${moneyText(step * 100).replaceAll(' ₽', '')}',
          selected: false,
          onTap: () => _add(step),
        ),
    ],
  );
}
