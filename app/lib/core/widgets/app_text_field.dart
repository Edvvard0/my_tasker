import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Поле ввода со стилем фокуса из 02, 2.9.1: кольцо 2 px синего акцента с
/// зазором 2 px от поля, радиус кольца = радиус поля + 2.
///
/// Место под кольцо (4 px со всех сторон) резервируется всегда, поэтому
/// раскладка не прыгает при фокусе.
class AppTextField extends StatefulWidget {
  const AppTextField({
    required this.controller,
    this.decoration,
    this.style,
    this.keyboardType,
    this.minLines,
    this.maxLines = 1,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.inputFormatters,
    super.key,
  });

  final TextEditingController controller;
  final InputDecoration? decoration;
  final TextStyle? style;
  final TextInputType? keyboardType;
  final int? minLines;
  final int? maxLines;
  final bool autocorrect;
  final bool enableSuggestions;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ring = context.colors.borderFocus;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: DecoratedBox(
        key: const Key('focus-ring'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.m + 2),
          border: Border.all(
            color: _focused ? ring : Colors.transparent,
            width: 2,
          ),
        ),
        child: Padding(
          // DecoratedBox не сдвигает потомка: 2 px кольца + 2 px зазора.
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: widget.controller,
            decoration: widget.decoration,
            style: widget.style,
            keyboardType: widget.keyboardType,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            autocorrect: widget.autocorrect,
            enableSuggestions: widget.enableSuggestions,
            inputFormatters: widget.inputFormatters,
          ),
        ),
      ),
    );
  }
}
