import 'package:flutter/material.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Диалог подтверждения (02, 4.8): называет объект и последствия; слева
/// «Отмена» (фокус по умолчанию), справа основное действие. При [danger] —
/// красная заливка с чёрным текстом (единственное красное действие).
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = false,
}) async {
  final c = context.colors;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('confirm-dialog'),
      title: Text(title, style: context.text.h3),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Text(
          message,
          style: context.text.body.copyWith(color: c.textSecondary),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        AppSpacing.s6,
        0,
        AppSpacing.s6,
        AppSpacing.s4,
      ),
      actions: [
        ElevatedButton(
          key: const Key('confirm-cancel'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('confirm-ok'),
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: c.danger,
                  foregroundColor: Colors.black,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
