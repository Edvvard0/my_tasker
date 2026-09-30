import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/features/ai_chat/ai_chat_screen.dart';
import 'package:my_tasker/features/calendar/calendar_screen.dart';
import 'package:my_tasker/features/finance/finance_screen.dart';
import 'package:my_tasker/features/settings/presentation/server_connection_screen.dart';
import 'package:my_tasker/features/settings/presentation/settings_screen.dart';
import 'package:my_tasker/features/settings/presentation/theme_showcase_screen.dart';
import 'package:my_tasker/features/shell/app_shell.dart';
import 'package:my_tasker/features/shell/sections_screen.dart';
import 'package:my_tasker/features/sleep/sleep_screen.dart';
import 'package:my_tasker/features/study/study_screen.dart';
import 'package:my_tasker/features/today/today_screen.dart';
import 'package:my_tasker/features/work/servers_screen.dart';
import 'package:my_tasker/features/work/work_screen.dart';

/// Ключ корневого навигатора: экраны поверх оболочки (сетка «Разделы»).
final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Строит роутер. Порядок веток = порядок `AppSection.values`.
GoRouter createRouter({String initialLocation = '/today'}) => GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: initialLocation,
  routes: [
    GoRoute(path: '/', redirect: (_, _) => '/today'),
    GoRoute(
      path: '/sections',
      parentNavigatorKey: rootNavigatorKey,
      builder: (_, _) => const SectionsScreen(),
    ),
    StatefulShellRoute.indexedStack(
      builder: (_, _, shell) => AppShell(navigationShell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/today', builder: (_, _) => const TodayScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/calendar',
              builder: (_, _) => const CalendarScreen(),
              routes: [
                GoRoute(path: 'tasks', builder: (_, _) => const TasksScreen()),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/work',
              builder: (_, _) => const WorkScreen(),
              routes: [
                GoRoute(
                  path: 'servers',
                  builder: (_, _) => const ServersScreen(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/finance', builder: (_, _) => const FinanceScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/ai', builder: (_, _) => const AiChatScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/study', builder: (_, _) => const StudyScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/sleep', builder: (_, _) => const SleepScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, _) => const SettingsScreen(),
              routes: [
                GoRoute(
                  path: 'server',
                  builder: (_, _) => const ServerConnectionScreen(),
                ),
                GoRoute(
                  path: 'theme',
                  builder: (_, _) => const ThemeShowcaseScreen(),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

final routerProvider = Provider<GoRouter>((ref) {
  final router = createRouter();
  ref.onDispose(router.dispose);
  return router;
});
