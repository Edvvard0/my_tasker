import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart'
    show moscowDay;
import 'package:my_tasker/features/work/domain/work_format.dart';

/// Время по Москве `ЧЧ:ММ` (банки пишут московское время).
String moscowClock(DateTime instant) {
  final t = instant.toUtc().add(const Duration(hours: 3));
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// «15 окт., 11:30» по Москве; без времени для строки выписки только с датой.
String momentText(DateTime instant, DateTime now, {bool withTime = true}) {
  final day = formatDateText(moscowDay(instant), now);
  return withTime ? '$day, ${moscowClock(instant)}' : day;
}

/// Название банка по пакету Android-приложения.
String bankNameOfPackage(NotificationRules rules, String package) =>
    rules.bankOfPackage(package)?.name ?? 'Банк';

/// Короткая карточка-подсказка с иконкой (инструкции онбординга).
class StepNote extends StatelessWidget {
  const StepNote({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: c.textTertiary),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              text,
              style: context.text.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Иконка вида операции для списков Банков.
IconData bankKindIcon(String kind) =>
    kind == 'income' ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight;
