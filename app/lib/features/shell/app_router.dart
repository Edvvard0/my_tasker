import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/features/ai_chat/ai_chat_screen.dart';
import 'package:my_tasker/features/ai_chat/presentation/chat_screen.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/agent_editor_screen.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/agents_screen.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/ai_settings_screen.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/models_screen.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/presets_screen.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/usage_screen.dart';
import 'package:my_tasker/features/auth/presentation/login_screen.dart';
import 'package:my_tasker/features/calendar/calendar_screen.dart';
import 'package:my_tasker/features/calendar/presentation/calendar_settings_screen.dart';
import 'package:my_tasker/features/calendar/presentation/layers_screen.dart';
import 'package:my_tasker/features/devices/presentation/devices_screen.dart';
import 'package:my_tasker/features/finance/finance_screen.dart';
import 'package:my_tasker/features/finance/presentation/account_screen.dart';
import 'package:my_tasker/features/finance/presentation/analytics_screen.dart';
import 'package:my_tasker/features/finance/presentation/categories_screen.dart';
import 'package:my_tasker/features/finance/presentation/debt_screen.dart';
import 'package:my_tasker/features/finance/presentation/debts_screen.dart';
import 'package:my_tasker/features/finance/presentation/goal_screen.dart';
import 'package:my_tasker/features/finance/presentation/goals_screen.dart';
import 'package:my_tasker/features/finance/presentation/reconcile_screen.dart';
import 'package:my_tasker/features/finance/presentation/transactions_screen.dart';
import 'package:my_tasker/features/local_ai/presentation/local_benchmark_screen.dart';
import 'package:my_tasker/features/local_ai/presentation/local_models_screen.dart';
import 'package:my_tasker/features/settings/presentation/server_connection_screen.dart';
import 'package:my_tasker/features/settings/presentation/settings_screen.dart';
import 'package:my_tasker/features/settings/presentation/theme_showcase_screen.dart';
import 'package:my_tasker/features/shell/app_shell.dart';
import 'package:my_tasker/features/shell/sections_screen.dart';
import 'package:my_tasker/features/sleep/sleep_screen.dart';
import 'package:my_tasker/features/study/study_screen.dart';
import 'package:my_tasker/features/sync/presentation/conflicts_screen.dart';
import 'package:my_tasker/features/sync/presentation/sync_screen.dart';
import 'package:my_tasker/features/today/today_screen.dart';
import 'package:my_tasker/features/trash/presentation/trash_screen.dart';
import 'package:my_tasker/features/work/servers_screen.dart';
import 'package:my_tasker/features/work/work_screen.dart';

/// Ключ корневого навигатора: экраны поверх оболочки (сетка «Разделы»).
final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Экраны, доступные без входа: сам вход и настройка сервера (без сервера
/// войти нельзя).
const Set<String> publicLocations = {'/login', '/setup/server'};

/// Правило входа: без сессии — только [publicLocations]; с сессией экран
/// входа не нужен. Пока токены читаются ([AuthUnknown]), ничего не решаем
/// (корень приложения показывает заставку).
String? authRedirect(AuthState auth, String location) {
  if (auth is SignedOut && !publicLocations.contains(location)) {
    return '/login';
  }
  if (auth is SignedIn && location == '/login') return '/today';
  return null;
}

/// Строит роутер. Порядок веток = порядок `AppSection.values`.
GoRouter createRouter({
  String initialLocation = '/today',
  GoRouterRedirect? redirect,
  Listenable? refreshListenable,
}) => GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: initialLocation,
  redirect: redirect,
  refreshListenable: refreshListenable,
  routes: [
    GoRoute(path: '/', redirect: (_, _) => '/today'),
    GoRoute(
      path: '/login',
      parentNavigatorKey: rootNavigatorKey,
      builder: (_, _) => const LoginScreen(),
    ),
    GoRoute(
      path: '/setup/server',
      parentNavigatorKey: rootNavigatorKey,
      builder: (_, _) =>
          const Scaffold(body: ServerConnectionScreen(backLocation: '/login')),
    ),
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
                GoRoute(
                  path: 'layers',
                  builder: (_, _) => const LayersScreen(),
                ),
                GoRoute(
                  path: 'settings',
                  builder: (_, _) => const CalendarSettingsScreen(),
                ),
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
            GoRoute(
              path: '/finance',
              builder: (_, _) => const FinanceScreen(),
              routes: [
                GoRoute(
                  path: 'transactions',
                  builder: (_, _) => const TransactionsScreen(),
                ),
                GoRoute(
                  path: 'categories',
                  builder: (_, _) => const CategoriesScreen(),
                ),
                GoRoute(
                  path: 'debts',
                  builder: (_, _) => const DebtsScreen(),
                  routes: [
                    GoRoute(
                      path: ':id',
                      builder: (_, state) =>
                          DebtScreen(debtId: state.pathParameters['id']!),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'goals',
                  builder: (_, _) => const GoalsScreen(),
                  routes: [
                    GoRoute(
                      path: ':id',
                      builder: (_, state) =>
                          GoalScreen(goalId: state.pathParameters['id']!),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'analytics',
                  builder: (_, _) => const AnalyticsScreen(),
                ),
                GoRoute(
                  path: 'accounts/:id',
                  builder: (_, state) =>
                      AccountScreen(accountId: state.pathParameters['id']!),
                  routes: [
                    GoRoute(
                      path: 'reconcile',
                      builder: (_, state) => ReconcileScreen(
                        accountId: state.pathParameters['id']!,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/ai',
              builder: (_, _) => const AiChatScreen(),
              routes: [
                // Чат — на весь экран поверх оболочки (поле ввода не
                // прячется под плавающим таб-баром).
                GoRoute(
                  path: 'new',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (_, _) => const ChatScreen(),
                ),
                GoRoute(
                  path: 'chat/:id',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (_, state) =>
                      ChatScreen(conversationId: state.pathParameters['id']),
                ),
                GoRoute(
                  path: 'settings',
                  builder: (_, _) => const AiSettingsScreen(),
                  routes: [
                    GoRoute(
                      path: 'agents',
                      builder: (_, _) => const AgentsScreen(),
                      routes: [
                        GoRoute(
                          path: ':id',
                          builder: (_, state) => AgentEditorScreen(
                            agentId: state.pathParameters['id']!,
                          ),
                        ),
                      ],
                    ),
                    GoRoute(
                      path: 'models',
                      builder: (_, _) => const ModelsScreen(),
                    ),
                    GoRoute(
                      path: 'presets',
                      builder: (_, _) => const PresetsScreen(),
                    ),
                    GoRoute(
                      path: 'usage',
                      builder: (_, _) => const UsageScreen(),
                    ),
                    // Этап 10: офлайн-модель и тест локальной модели.
                    GoRoute(
                      path: 'local',
                      builder: (_, _) => const LocalModelsScreen(),
                      routes: [
                        GoRoute(
                          path: 'benchmark',
                          builder: (_, _) => const LocalBenchmarkScreen(),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
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
                GoRoute(
                  path: 'devices',
                  builder: (_, _) => const DevicesScreen(),
                ),
                GoRoute(
                  path: 'sync',
                  builder: (_, _) => const SyncScreen(),
                  routes: [
                    GoRoute(
                      path: 'conflicts',
                      builder: (_, _) => const ConflictsScreen(),
                    ),
                  ],
                ),
                GoRoute(path: 'trash', builder: (_, _) => const TrashScreen()),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

final routerProvider = Provider<GoRouter>((ref) {
  // Роутер живёт, пока живёт приложение; смена состояния входа лишь
  // перевычисляет redirect (стек экранов не пересоздаётся).
  final auth = ValueNotifier<AuthState>(ref.read(authControllerProvider));
  ref.listen<AuthState>(authControllerProvider, (_, next) => auth.value = next);
  final router = createRouter(
    redirect: (_, state) => authRedirect(auth.value, state.matchedLocation),
    refreshListenable: auth,
  );
  ref.onDispose(() {
    router.dispose();
    auth.dispose();
  });
  return router;
});
