import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Разбор суммы со знаком (начальный остаток, фактический баланс): пустое
/// поле — `null` без ошибки; мусор — ошибка.
({int? kopecks, String? error}) parseSignedMoney(String text, String what) {
  if (text.trim().isEmpty) return (kopecks: null, error: null);
  final value = tryParseAmount(text);
  if (value == null) {
    return (
      kopecks: null,
      error: '$what: введите сумму, например 1 500, -99,50',
    );
  }
  return (kopecks: value, error: null);
}

/// Фильтр поля суммы со знаком: цифры, пробелы, `,`, `.`, минус.
final List<TextInputFormatter> signedMoneyFormatters = [
  FilteringTextInputFormatter.allow(RegExp(r'[0-9 ,.\-−]')),
];

/// Сумма для подстановки в поле: `-1500` копеек -> «-15».
String signedMoneyText(int? kopecks) {
  if (kopecks == null) return '';
  final sign = kopecks < 0 ? '-' : '';
  final abs = kopecks.abs();
  final rubles = abs ~/ 100;
  final cents = abs % 100;
  return cents == 0
      ? '$sign$rubles'
      : '$sign$rubles,${cents.toString().padLeft(2, '0')}';
}

/// Поле суммы со знаком.
class SignedMoneyField extends StatelessWidget {
  const SignedMoneyField({
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
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: signedMoneyFormatters,
      decoration: InputDecoration(hintText: hint, suffixText: '₽'),
    );
  }
}

/// Чипы выбора счёта (один).
class AccountChips extends StatelessWidget {
  const AccountChips({
    required this.accounts,
    required this.selectedId,
    required this.onSelect,
    this.keyPrefix = 'account',
    this.noneLabel,
    super.key,
  });

  final List<Account> accounts;
  final String? selectedId;
  final ValueChanged<String?> onSelect;
  final String keyPrefix;

  /// Если задан — первым идёт чип «без счёта» с этой подписью.
  final String? noneLabel;

  @override
  Widget build(BuildContext context) {
    return ChipRow(
      children: [
        if (noneLabel != null)
          FilterPill(
            key: Key('$keyPrefix-none'),
            label: noneLabel!,
            selected: selectedId == null,
            onTap: () => onSelect(null),
          ),
        for (final a in accounts)
          FilterPill(
            key: Key('$keyPrefix-${a.id}'),
            label: a.name,
            selected: selectedId == a.id,
            icon: LucideIcons.wallet,
            onTap: () => onSelect(a.id),
          ),
      ],
    );
  }
}

/// Строка-«кнопка выбора» в форме: подпись значения и шеврон.
class PickerField extends StatelessWidget {
  const PickerField({
    required this.text,
    required this.onTap,
    this.placeholder = false,
    super.key,
  });

  final String text;
  final bool placeholder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      borderRadius: AppRadii.borderS,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s3,
          vertical: AppSpacing.s3,
        ),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: AppRadii.borderS,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.body.copyWith(
                  color: placeholder ? c.textTertiary : c.textPrimary,
                ),
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Кнопки «Удалить» (слева) и «Сохранить» (справа) внизу формы.
class EditorActions extends StatelessWidget {
  const EditorActions({
    required this.saveKey,
    required this.onSave,
    this.saving = false,
    this.deleteKey,
    this.onDelete,
    this.saveLabel = 'Сохранить',
    super.key,
  });

  final Key saveKey;
  final VoidCallback onSave;
  final bool saving;
  final Key? deleteKey;
  final VoidCallback? onDelete;
  final String saveLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s6,
        AppSpacing.s2,
        AppSpacing.s6,
        AppSpacing.s4,
      ),
      child: Row(
        children: [
          if (onDelete != null)
            OutlinedButton.icon(
              key: deleteKey,
              onPressed: onDelete,
              style: OutlinedButton.styleFrom(
                foregroundColor: c.danger,
                side: BorderSide(color: c.danger),
              ),
              icon: const Icon(LucideIcons.trash2, size: 18),
              label: const Text('Удалить'),
            ),
          const Spacer(),
          FilledButton(
            key: saveKey,
            onPressed: saving ? null : onSave,
            child: Text(saveLabel),
          ),
        ],
      ),
    );
  }
}

/// Заглушка формы, пока строка не прочитана или её удалили.
class EditorLoading extends StatelessWidget {
  const EditorLoading({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 240,
    child: Center(child: CircularProgressIndicator()),
  );
}
