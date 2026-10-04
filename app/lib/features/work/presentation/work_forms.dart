import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';

/// Результат разбора поля суммы: копейки или понятная ошибка.
class MoneyField {
  const MoneyField(this.kopecks, this.error);

  /// `null` у пустого поля.
  final int? kopecks;
  final String? error;
}

/// Разбирает введённую сумму (`1 234,56`, `500 ₽`). Пустое поле — `null`
/// без ошибки; минус и мусор — ошибка.
MoneyField parseMoneyField(String text, String what) {
  if (text.trim().isEmpty) return const MoneyField(null, null);
  final value = tryParseAmount(text);
  if (value == null) {
    return MoneyField(null, '$what: введите сумму, например 1 500 или 99,50');
  }
  if (value < 0) return MoneyField(null, '$what не может быть отрицательной');
  return MoneyField(value, null);
}

/// Сумма для подстановки в поле: `1500` копеек → «15», без «₽».
String moneyFieldText(int? kopecks) {
  if (kopecks == null) return '';
  final rubles = kopecks ~/ 100;
  final cents = kopecks % 100;
  return cents == 0 ? '$rubles' : '$rubles,${cents.toString().padLeft(2, '0')}';
}

/// Дата `YYYY-MM-DD` ↔ гражданская дата.
DateTime? dateFromText(String? text) => text == null ? null : parseDate(text);

String? dateToText(DateTime? date) => date == null ? null : formatDate(date);

/// Фильтр поля суммы: цифры, пробелы, `,` и `.`.
final List<TextInputFormatter> moneyInputFormatters = [
  FilteringTextInputFormatter.allow(RegExp('[0-9 ,.]')),
];

/// Поле суммы формы: цифровая клавиатура, подсказка «0 ₽».
class MoneyTextField extends StatelessWidget {
  const MoneyTextField({
    required this.controller,
    this.onChanged,
    this.hint = '0',
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return FormTextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: moneyInputFormatters,
      decoration: InputDecoration(hintText: hint, suffixText: '₽'),
    );
  }
}

/// Спрашивает короткий текст (имя нового заказчика); `null` — отмена.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String hint = '',
  String initial = '',
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _AskTextDialog(title: title, hint: hint, initial: initial),
  );
  final text = result?.trim();
  return text == null || text.isEmpty ? null : text;
}

class _AskTextDialog extends StatefulWidget {
  const _AskTextDialog({
    required this.title,
    required this.hint,
    required this.initial,
  });

  final String title;
  final String hint;
  final String initial;

  @override
  State<_AskTextDialog> createState() => _AskTextDialogState();
}

class _AskTextDialogState extends State<_AskTextDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: context.text.h3),
      content: FormTextField(
        key: const Key('ask-text'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        AppSpacing.s6,
        0,
        AppSpacing.s6,
        AppSpacing.s4,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('ask-text-ok'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}

/// Строка ошибки формы.
class FormError extends StatelessWidget {
  const FormError(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        children: [
          Icon(LucideIcons.circleAlert, size: 16, color: c.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: context.text.bodyS.copyWith(color: c.danger),
            ),
          ),
        ],
      ),
    );
  }
}
