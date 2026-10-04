import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/work/application/timer_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

/// Запускает таймер по проекту (доработке, задаче). Идущий раньше
/// останавливается, о чём сообщает снэкбар «Таймер X остановлен · 01:12»
/// (02, 4.11). Возвращает `false`, если запуск не удался.
Future<bool> startTimerFor(
  BuildContext context,
  WidgetRef ref, {
  required String projectId,
  String? changeRequestId,
  String? taskId,
  String? note,
}) async {
  final repo = ref.read(workRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);
  final titles = {
    for (final t in ref.read(runningTimersProvider)) t.entry.id: t.title,
  };
  try {
    final result = await repo.startTimer(
      projectId: projectId,
      changeRequestId: changeRequestId,
      taskId: taskId,
      note: note,
    );
    for (final stopped in result.stopped) {
      final length = stopped.endedAt!.difference(stopped.startedAt);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Таймер ${titles[stopped.id] ?? 'проекта'} остановлен · '
              '${formatHours(length.inSeconds)}',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
    }
    return true;
  } on ValidationError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
}

/// Останавливает таймер и сообщает, сколько записано.
Future<void> stopTimerWithToast(
  BuildContext context,
  WidgetRef ref,
  RunningTimer timer,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final stopped = await ref
      .read(workRepositoryProvider)
      .stopTimer(timer.entry.id);
  if (stopped == null) return;
  final seconds = stopped.endedAt!.difference(stopped.startedAt).inSeconds;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text('Записано ${formatHours(seconds)} · ${timer.title}'),
        duration: const Duration(seconds: 5),
      ),
    );
}

/// Плавающая плашка «идёт таймер» (02, 4.11): синяя точка, проект, время
/// и «Стоп». Пока таймера нет — ничего не занимает. Тап открывает лист
/// таймера.
class RunningTimerPill extends ConsumerWidget {
  const RunningTimerPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(primaryTimerProvider);
    if (timer == null) return const SizedBox.shrink();
    final now = ref.watch(timerTickProvider);
    final c = context.colors;
    final t = context.text;
    return Material(
      key: const Key('timer-pill'),
      color: c.surface2,
      elevation: 3,
      shape: StadiumBorder(
        side: BorderSide(color: c.accent.withValues(alpha: 0.4)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => showTimerSheet(context),
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Flexible(
                child: Text(
                  timer.title,
                  style: t.bodyS,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Text(
                formatTimer(timer.elapsed(now)),
                key: const Key('timer-pill-time'),
                style: t.numL,
              ),
              IconButton(
                key: const Key('timer-pill-stop'),
                tooltip: 'Остановить таймер',
                onPressed: () => stopTimerWithToast(context, ref, timer),
                icon: const Icon(LucideIcons.square, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Открывает лист таймера.
Future<void> showTimerSheet(BuildContext context) =>
    showEditorSheet<void>(context, builder: (_) => const TimerSheet());

/// Лист таймера: крупное время, проект, заметка, «Стоп» и «Отменить
/// запись». Если таймеров два (после синхронизации) — показаны оба.
class TimerSheet extends ConsumerStatefulWidget {
  const TimerSheet({super.key});

  @override
  ConsumerState<TimerSheet> createState() => _TimerSheetState();
}

class _TimerSheetState extends ConsumerState<TimerSheet> {
  final _note = TextEditingController();
  String? _noteFor;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _saveNote(RunningTimer timer) async {
    final text = _note.text.trim();
    final next = text.isEmpty ? null : text;
    if (next == timer.entry.note) return;
    await ref
        .read(workRepositoryProvider)
        .updateEntry(timer.entry.copyWith(note: next));
  }

  @override
  Widget build(BuildContext context) {
    final timers = ref.watch(runningTimersProvider);
    final now = ref.watch(timerTickProvider);
    final c = context.colors;
    final t = context.text;
    final main = ref.watch(primaryTimerProvider);
    if (main != null && _noteFor != main.entry.id) {
      _noteFor = main.entry.id;
      _note.text = main.entry.note ?? '';
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Таймер'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: timers.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s6),
                      child: Text(
                        'Таймер остановлен.',
                        key: const Key('timer-sheet-empty'),
                        style: t.body.copyWith(color: c.textSecondary),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (timers.length > 1)
                          const Padding(
                            padding: EdgeInsets.only(bottom: AppSpacing.s3),
                            child: TimerConflictBanner(),
                          ),
                        if (main != null) ...[
                          Center(
                            child: Text(
                              formatTimer(main.elapsed(now)),
                              key: const Key('timer-sheet-time'),
                              style: t.display,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.s1),
                          Center(
                            child: Text(
                              main.title,
                              style: t.body.copyWith(color: c.textSecondary),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.s4),
                          FormBlock(
                            label: 'Заметка',
                            child: FormTextField(
                              key: const Key('timer-note'),
                              controller: _note,
                              onSubmitted: (_) => _saveNote(main),
                              decoration: const InputDecoration(
                                hintText: 'Над чем работаешь',
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  key: const Key('timer-discard'),
                                  onPressed: () async {
                                    final nav = Navigator.of(context);
                                    await ref
                                        .read(workRepositoryProvider)
                                        .discardTimer(main.entry.id);
                                    nav.pop();
                                  },
                                  icon: const Icon(
                                    LucideIcons.trash2,
                                    size: 18,
                                  ),
                                  label: const Text('Отменить запись'),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.s3),
                              Expanded(
                                child: FilledButton.icon(
                                  key: const Key('timer-stop'),
                                  onPressed: () async {
                                    final nav = Navigator.of(context);
                                    await _saveNote(main);
                                    if (!context.mounted) return;
                                    await stopTimerWithToast(
                                      context,
                                      ref,
                                      main,
                                    );
                                    nav.pop();
                                  },
                                  icon: const Icon(
                                    LucideIcons.square,
                                    size: 18,
                                  ),
                                  label: const Text('Стоп'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.s4),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Предупреждение «идёт больше одного таймера» с остановкой любого из них
/// (spec 1.6: сервер хранит оба, решает пользователь).
class TimerConflictBanner extends ConsumerWidget {
  const TimerConflictBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timers = ref.watch(runningTimersProvider);
    if (timers.length < 2) return const SizedBox.shrink();
    final now = ref.watch(timerTickProvider);
    return WorkWarning(
      key: const Key('timer-conflict'),
      text:
          'Идёт ${timers.length} таймера: их запустили офлайн на разных '
          'устройствах. Остановите лишний.',
      actions: [
        for (final timer in timers)
          OutlinedButton(
            key: Key('timer-conflict-stop-${timer.entry.id}'),
            onPressed: () => stopTimerWithToast(context, ref, timer),
            child: Text(
              'Стоп: ${timer.title} · '
              '${formatTimer(timer.elapsed(now))}',
            ),
          ),
      ],
    );
  }
}

/// Кнопка-значок «старт / стоп» таймера проекта для верхней панели.
class ProjectTimerButton extends ConsumerWidget {
  const ProjectTimerButton({
    required this.projectId,
    this.changeRequestId,
    super.key,
  });

  final String projectId;
  final String? changeRequestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref
        .watch(runningTimersProvider)
        .where((t) => t.entry.projectId == projectId)
        .toList();
    if (running.isNotEmpty) {
      return IconButton(
        key: const Key('project-timer-stop'),
        tooltip: 'Остановить таймер',
        onPressed: () => stopTimerWithToast(context, ref, running.last),
        icon: const Icon(LucideIcons.square, size: 22),
      );
    }
    return IconButton(
      key: const Key('project-timer-start'),
      tooltip: 'Запустить таймер',
      onPressed: () => startTimerFor(
        context,
        ref,
        projectId: projectId,
        changeRequestId: changeRequestId,
      ),
      icon: const Icon(LucideIcons.play, size: 22),
    );
  }
}
