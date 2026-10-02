import 'package:flutter/material.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Сегментированная кнопка (02, 4.3): группа в пилюле `surface/3`, выбранный
/// сегмент — `surface/1` и `text/primary`. Растягивается на всю ширину.
class SegmentedPill<T> extends StatelessWidget {
  const SegmentedPill({
    required this.options,
    required this.selected,
    required this.onChanged,
    this.keyPrefix = 'segment',
    super.key,
  });

  /// Значение -> подпись, в порядке показа.
  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Ключи сегментов: `<prefix>-<name>`, где name — `Enum.name` либо
  /// `toString()` значения.
  final String keyPrefix;

  static String _name(Object? value) => value is Enum ? value.name : '$value';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s1),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderFull,
      ),
      child: Row(
        children: [
          for (final entry in options.entries)
            Expanded(
              child: Semantics(
                button: true,
                selected: entry.key == selected,
                label: entry.value,
                excludeSemantics: true,
                child: InkWell(
                  key: Key('$keyPrefix-${_name(entry.key)}'),
                  borderRadius: AppRadii.borderFull,
                  onTap: () => onChanged(entry.key),
                  child: Container(
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: entry.key == selected
                          ? c.surface1
                          : Colors.transparent,
                      borderRadius: AppRadii.borderFull,
                    ),
                    child: Text(
                      entry.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.label.copyWith(
                        color: entry.key == selected
                            ? c.textPrimary
                            : c.textSecondary,
                        fontWeight: entry.key == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
