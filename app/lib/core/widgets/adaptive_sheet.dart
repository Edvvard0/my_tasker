import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Открывает форму: на телефоне — нижний лист (до 92 % высоты), на
/// десктопе — панель справа шириной 480 (02, 4.7–4.8).
Future<T?> showEditorSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  if (context.windowClass.isCompact) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => Dialog(
      alignment: Alignment.centerRight,
      insetPadding: const EdgeInsets.all(AppSpacing.s4),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(dialogContext).height - 2 * 16,
        ),
        child: builder(dialogContext),
      ),
    ),
  );
}

/// Заголовок формы: название слева, крестик справа.
class SheetHeader extends StatelessWidget {
  const SheetHeader({required this.title, this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s6,
        AppSpacing.s2,
        AppSpacing.s3,
        AppSpacing.s2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: context.text.h2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
          IconButton(
            tooltip: 'Закрыть',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(LucideIcons.x, size: 22),
          ),
        ],
      ),
    );
  }
}

/// Подпись поля формы **над** полем (02, 4.4).
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s2),
    child: Text(
      text,
      style: context.text.bodyS.copyWith(color: context.colors.textSecondary),
    ),
  );
}

/// Блок формы: подпись и содержимое с отступом снизу.
class FormBlock extends StatelessWidget {
  const FormBlock({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [FieldLabel(label), child],
    ),
  );
}
