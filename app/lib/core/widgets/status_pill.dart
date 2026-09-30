import 'package:flutter/material.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Смысловой тон статуса (02, 4.6). Цветов статусов нет: тон различается
/// формой точки и словом, синий и красный — только у `info` и `danger`.
///
/// * `success` — сплошная белая точка («работает», «готово»);
/// * `warning` — полая белая точка («частично», «сверь»);
/// * `info` — синяя точка («проверяем», «ИИ предлагает»);
/// * `danger` — красный (единственное исключение: сбой, сервер недоступен);
/// * `neutral` — серая точка.
enum StatusTone { success, warning, danger, info, neutral }

/// Статус-пилюля: точка 8 px + текст `overline` (UPPERCASE), высота 24.
class StatusPill extends StatelessWidget {
  const StatusPill({required this.label, required this.tone, super.key});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (fg, bg) = switch (tone) {
      StatusTone.danger => (c.danger, c.dangerMuted),
      StatusTone.neutral => (c.textSecondary, c.surface3),
      _ => (c.textPrimary, c.surface3),
    };
    final dot = switch (tone) {
      StatusTone.success => BoxDecoration(
        color: c.textPrimary,
        shape: BoxShape.circle,
      ),
      StatusTone.warning => BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: c.textPrimary, width: 1.5),
      ),
      StatusTone.info => BoxDecoration(color: c.accent, shape: BoxShape.circle),
      StatusTone.danger => BoxDecoration(
        color: c.danger,
        shape: BoxShape.circle,
      ),
      StatusTone.neutral => BoxDecoration(
        color: c.textTertiary,
        shape: BoxShape.circle,
      ),
    };
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: bg, borderRadius: AppRadii.borderFull),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, decoration: dot),
            const SizedBox(width: 6),
            Text(
              label.toUpperCase(),
              style: context.text.overline.copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
