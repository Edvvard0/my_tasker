import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Чип-фильтр или чип-выбор (02, 4.5): пилюля 32 px `surface/3`; выбранный
/// — белая заливка и чёрный текст (у фильтра — с галочкой слева).
class FilterPill extends StatelessWidget {
  const FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.check = false,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  /// Показывать галочку у выбранного (мультивыбор-фильтр).
  final bool check;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = selected ? c.textOnInverse : c.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: AppRadii.borderFull,
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? c.surfaceInverse : c.surface3,
            borderRadius: AppRadii.borderFull,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected && check) ...[
                Icon(LucideIcons.check, size: 14, color: fg),
                const SizedBox(width: 4),
              ] else if (icon != null) ...[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: context.text.label.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Чип ввода (распознанный токен): серый, с иконкой типа и крестиком.
class InputPill extends StatelessWidget {
  const InputPill({
    required this.label,
    required this.onRemove,
    this.icon,
    super.key,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderFull,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: c.textSecondary),
            const SizedBox(width: 6),
          ],
          Text(label, style: context.text.label.copyWith(color: c.textPrimary)),
          if (onRemove != null)
            Semantics(
              button: true,
              label: 'Убрать: $label',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: AppRadii.borderFull,
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(LucideIcons.x, size: 14, color: c.textSecondary),
                ),
              ),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// Метаданные: иконка + текст без фона (`⏱ ~81 мин`, `↻`, `☰ 2/5`).
class MetaInline extends StatelessWidget {
  const MetaInline({this.icon, this.text, this.strong = false, super.key});

  final IconData? icon;
  final String? text;

  /// Белым жирным (просрочка, 02, 4.2).
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = strong ? c.textPrimary : c.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) Icon(icon, size: 13, color: color),
        if (icon != null && text != null) const SizedBox(width: 3),
        if (text != null)
          Text(
            text!,
            style: context.text.bodyS.copyWith(
              color: color,
              fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
      ],
    );
  }
}

/// Горизонтальный ряд чипов с прокруткой (на телефоне) и переносом-без-переноса.
class ChipRow extends StatelessWidget {
  const ChipRow({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.s2),
            children[i],
          ],
        ],
      ),
    );
  }
}
