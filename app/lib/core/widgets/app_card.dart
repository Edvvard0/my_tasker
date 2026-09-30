import 'package:flutter/material.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Карточка: `surface/1`, радиус 24, внутренний отступ 16.
class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.s4),
    this.emphasis = false,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Красная подложка (только для сбоя, 02: `emphasis/danger`).
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: emphasis ? c.dangerMuted : c.surface1,
        borderRadius: AppRadii.borderL,
        border: emphasis ? Border.all(color: c.danger) : null,
      ),
      child: child,
    );
  }
}
