import 'package:flutter/material.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Пустое состояние (02, 2.9.2): иконка 32 -> заголовок -> пояснение
/// -> (необязательная) кнопка. Без иллюстраций.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: c.textTertiary),
              const SizedBox(height: AppSpacing.s3),
              Text(title, style: t.h3, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.s1),
              Text(
                message,
                style: t.bodyS.copyWith(color: c.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (action != null) ...[
                const SizedBox(height: AppSpacing.s4),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
