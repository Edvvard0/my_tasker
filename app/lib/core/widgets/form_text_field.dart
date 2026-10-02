import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Поле ввода форм календаря и задач: то же кольцо фокуса, что у
/// `AppTextField` (2 px акцента с зазором 2 px), но с `onChanged`,
/// `onSubmitted`, `autofocus`, `textInputAction` и `focusNode`.
class FormTextField extends StatefulWidget {
  const FormTextField({
    required this.controller,
    this.decoration,
    this.style,
    this.keyboardType,
    this.minLines,
    this.maxLines = 1,
    this.autofocus = false,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.inputFormatters,
    this.focusNode,
    this.maxLength,
    this.textAlign = TextAlign.start,
    super.key,
  });

  final TextEditingController controller;
  final InputDecoration? decoration;
  final TextStyle? style;
  final TextInputType? keyboardType;
  final int? minLines;
  final int? maxLines;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final FocusNode? focusNode;
  final int? maxLength;
  final TextAlign textAlign;

  @override
  State<FormTextField> createState() => _FormTextFieldState();
}

class _FormTextFieldState extends State<FormTextField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ring = context.colors.borderFocus;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.m + 2),
          border: Border.all(
            color: _focused ? ring : Colors.transparent,
            width: 2,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            decoration: widget.decoration,
            style: widget.style,
            textAlign: widget.textAlign,
            keyboardType: widget.keyboardType,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            maxLength: widget.maxLength,
            autofocus: widget.autofocus,
            textInputAction: widget.textInputAction,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            inputFormatters: widget.inputFormatters,
            buildCounter: widget.maxLength == null
                ? null
                : (
                    _, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null,
          ),
        ),
      ),
    );
  }
}
