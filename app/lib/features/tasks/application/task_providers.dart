import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';
import 'package:my_tasker/features/tasks/domain/task_views.dart';

/// Данные для списков задач: записи и справочники.
@immutable
class TaskListData {
  const TaskListData({
    required this.entries,
    required this.projects,
    required this.people,
    required this.tags,
    required this.subtaskProgress,
    required this.tagLinks,
  });

  final List<TaskEntry> entries;
  final Map<String, Project> projects;
  final Map<String, Person> people;
  final List<Tag> tags;

  /// `task_id -> (сделано, всего)`.
  final Map<String, (int, int)> subtaskProgress;

  /// `task_id -> {tag_id}`.
  final Map<String, Set<String>> tagLinks;

  /// Задачи без даты — бэклог «Без даты» (не закрытые и не в архиве).
  List<TaskEntry> get backlog => [
    for (final e in entries)
      if (e.localDate == null &&
          e.task.isOpen &&
          e.task.archivedAt == null &&
          !e.done)
        e,
  ]..sort(compareEntries);
}

/// Записи списка задач: собираются из потоков БД; ошибка любого потока —
/// ошибка всего экрана, пока хотя бы один загружается — загрузка.
final Provider<AsyncValue<TaskListData>> taskListDataProvider =
    Provider<AsyncValue<TaskListData>>((ref) {
      final tasks = ref.watch(tasksProvider);
      final completions = ref.watch(taskCompletionsProvider);
      final subtasks = ref.watch(subtasksProvider);
      final projects = ref.watch(projectsProvider);
      final people = ref.watch(peopleProvider);
      final tags = ref.watch(tagsProvider);
      final links = ref.watch(taskTagLinksProvider);
      final zone = ref.watch(deviceTimeZoneProvider);
      final now = ref.watch(nowProvider);
      final all = <AsyncValue<Object?>>[
        tasks,
        completions,
        subtasks,
        projects,
        people,
        tags,
        links,
      ];
      for (final v in all) {
        if (v.hasError && !v.hasValue) {
          return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
        }
      }
      if (all.any((v) => !v.hasValue)) return const AsyncValue.loading();
      final progress = <String, (int, int)>{};
      for (final s in subtasks.requireValue) {
        final p = progress[s.taskId] ?? (0, 0);
        progress[s.taskId] = (p.$1 + (s.done ? 1 : 0), p.$2 + 1);
      }
      return AsyncValue.data(
        TaskListData(
          entries: buildTaskEntries(
            tasks.requireValue,
            completions.requireValue,
            now: now,
            zone: zone,
          ),
          projects: {for (final p in projects.requireValue) p.id: p},
          people: {for (final p in people.requireValue) p.id: p},
          tags: tags.requireValue,
          subtaskProgress: progress,
          tagLinks: links.requireValue,
        ),
      );
    });

/// Фильтр списка задач (состояние экрана).
class TaskFilterNotifier extends Notifier<TaskFilter> {
  @override
  TaskFilter build() => const TaskFilter();

  void setRange(TaskRange range) => state = state.copyWith(range: range);

  void toggleStatus(TaskStatus status) {
    final next = {...state.statuses};
    if (!next.remove(status)) next.add(status);
    state = state.copyWith(statuses: next);
  }

  /// Приоритет 1…5, `0` — «без приоритета».
  void togglePriority(int priority) {
    final next = {...state.priorities};
    if (!next.remove(priority)) next.add(priority);
    state = state.copyWith(priorities: next);
  }

  void setProject(String? id) => state = state.copyWith(projectId: id);

  void setTag(String? id) => state = state.copyWith(tagId: id);

  void setQuery(String query) => state = state.copyWith(query: query);

  void setShowCancelled({required bool value}) =>
      state = state.copyWith(showCancelled: value);

  void setShowArchived({required bool value}) =>
      state = state.copyWith(showArchived: value);

  void reset() => state = const TaskFilter();
}

final NotifierProvider<TaskFilterNotifier, TaskFilter> taskFilterProvider =
    NotifierProvider<TaskFilterNotifier, TaskFilter>(TaskFilterNotifier.new);
