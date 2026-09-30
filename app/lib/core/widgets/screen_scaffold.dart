import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Каркас экрана: верхняя панель (56 на телефоне / 64 на десктопе) и
/// контент с полями по классу ширины (02, 2.3 и 3.2).
///
/// Ограничивает ширину контента (макс. 1440) и учитывает нижний отступ
/// от [MediaQuery] — оболочка увеличивает его под плавающий таб-бар.
class ScreenScaffold extends StatelessWidget {
  const ScreenScaffold({
    required this.title,
    required this.child,
    this.parentLabel,
    this.onBack,
    this.actions = const [],
    this.scrollable = true,
    super.key,
  });

  final String title;

  /// Подпись-родитель на вложенных экранах («Работа ›»).
  final String? parentLabel;

  /// Если задан — слева стрелка «назад».
  final VoidCallback? onBack;

  /// Иконки справа (максимум три по дизайну).
  final List<Widget> actions;

  /// Оборачивать контент в прокрутку. Экран с собственным списком ставит
  /// `false` и сам использует отступы.
  final bool scrollable;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final windowClass = context.windowClass;
    final gutter = windowClass.gutter;
    final t = context.text;
    final c = context.colors;
    final bottom = MediaQuery.paddingOf(context).bottom;

    final body = Padding(
      padding: EdgeInsets.fromLTRB(gutter, AppSpacing.s2, gutter, 0),
      child: child,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SafeArea(
          bottom: false,
          child: ConstrainedBox(
            // Минимальная высота: при крупном шрифте панель растёт, а не
            // обрезает заголовок.
            constraints: BoxConstraints(minHeight: windowClass.topBarHeight),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: gutter,
                vertical: AppSpacing.s1,
              ),
              child: Row(
                children: [
                  if (onBack != null) ...[
                    IconButton(
                      tooltip: 'Назад',
                      onPressed: onBack,
                      icon: const Icon(LucideIcons.arrowLeft, size: 24),
                    ),
                    const SizedBox(width: AppSpacing.s1),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (parentLabel != null)
                          Text(
                            '$parentLabel ›',
                            style: t.caption.copyWith(color: c.textSecondary),
                          ),
                        Text(
                          title,
                          style: t.h1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1440),
              child: scrollable
                  ? SingleChildScrollView(
                      padding: EdgeInsets.only(bottom: bottom + AppSpacing.s6),
                      child: body,
                    )
                  : body,
            ),
          ),
        ),
      ],
    );
  }
}
