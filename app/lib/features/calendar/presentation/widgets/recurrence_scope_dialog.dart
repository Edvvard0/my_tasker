import 'package:flutter/material.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/calendar/domain/recurrence_scope.dart';

export 'package:my_tasker/features/calendar/domain/recurrence_scope.dart';

/// Диалог «Только это · Это и следующие · Все в серии». `null` — отмена.
/// [title] называет действие («Изменить событие», «Удалить событие»).
Future<RecurrenceScope?> showRecurrenceScopeDialog(
  BuildContext context, {
  required String title,
  bool allowFollowing = true,
}) => showDialog<RecurrenceScope>(
  context: context,
  builder: (context) => SimpleDialog(
    key: const Key('scope-dialog'),
    title: Text(title, style: context.text.h3),
    children: [
      for (final scope in RecurrenceScope.values)
        if (allowFollowing || scope != RecurrenceScope.following)
          SimpleDialogOption(
            key: Key('scope-${scope.name}'),
            onPressed: () => Navigator.of(context).pop(scope),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(scope.label, style: context.text.body),
            ),
          ),
    ],
  ),
);
