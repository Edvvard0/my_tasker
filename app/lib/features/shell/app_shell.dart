import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/features/shell/app_section.dart';
import 'package:my_tasker/features/shell/bottom_tab_bar.dart';
import 'package:my_tasker/features/shell/quick_create_sheet.dart';
import 'package:my_tasker/features/shell/side_navigation.dart';

/// Пользователь свернул левую панель десктопа в рейл (кнопка `≡`).
class SideNavCollapsed extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final sideNavCollapsedProvider = NotifierProvider<SideNavCollapsed, bool>(
  SideNavCollapsed.new,
);

/// Адаптивная оболочка приложения (02, 3.2–3.3, 7.1):
///
/// * Compact (< 600) — плавающий таб-бар снизу + «+»;
/// * Medium (600–1023) — рейл 72 px слева;
/// * Expanded / Large (≥ 1024) — левая панель 256 px (сворачивается в рейл).
class AppShell extends ConsumerWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  AppSection get _current => AppSection.values[navigationShell.currentIndex];

  void _select(AppSection section) {
    navigationShell.goBranch(
      section.index,
      // Повторный тап по активному разделу возвращает к его корню.
      initialLocation: section.index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windowClass = context.windowClass;
    final content = navigationShell;

    if (windowClass.isCompact) {
      final mq = MediaQuery.of(context);
      // Контент не прячется под плавающим таб-баром.
      const inset = AppSpacing.floatingBarInset;
      return Scaffold(
        body: Stack(
          children: [
            MediaQuery(
              data: mq.copyWith(
                padding: mq.padding.copyWith(bottom: mq.padding.bottom + inset),
              ),
              child: content,
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: FloatingTabBar(
                  selected: _current.isTab ? _current : null,
                  onSelect: _select,
                  onCreate: () => showQuickCreate(context, section: _current),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final userCollapsed = ref.watch(sideNavCollapsedProvider);
    final isMedium = windowClass == WindowClass.medium;
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SideNavigation(
            collapsed: isMedium || userCollapsed,
            selected: _current,
            onSelect: _select,
            onCreate: () => showQuickCreate(context, section: _current),
            // В узком окне панель всегда рейл: сворачивать нечего.
            onToggleCollapsed: isMedium
                ? null
                : ref.read(sideNavCollapsedProvider.notifier).toggle,
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}
