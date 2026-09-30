import 'package:flutter/material.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Смысловой тон статуса (02, 4.6): цвет всегда дублируется точкой и словом.
enum StatusTone { success, warning, danger, info, neutral }

/// Статус-пилюля: точка 6 px + текст `overline` (UPPERCASE), высота 24.
class StatusPill extends StatelessWidget {
  const StatusPill({required this.label, required this.tone, super.key});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (fg, bg) = switch (tone) {
      StatusTone.success => (c.success, c.successMuted),
      StatusTone.warning => (c.warning, c.warningMuted),
      StatusTone.danger => (c.danger, c.dangerMuted),
      StatusTone.info => (c.info, c.infoMuted),
      StatusTone.neutral => (c.textSecondary, c.surface3),
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
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
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
