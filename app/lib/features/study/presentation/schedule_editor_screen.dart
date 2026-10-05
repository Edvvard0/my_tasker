import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/data/study_repository.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';
import 'package:my_tasker/features/study/presentation/schedule_editors.dart';
import 'package:my_tasker/features/study/presentation/semester_editor.dart';
import 'package:my_tasker/features/study/presentation/study_body.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';
import 'package:my_tasker/features/study/presentation/study_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show WorkSectionHeader;

/// Раздел редактора расписания.
enum EditorTab {
  slots('Пары'),
  rules('Особые дни'),
  bells('Звонки'),
  overrides('Изменения');

  const EditorTab(this.label);

  final String label;
}

/// «Редактор расписания»: пары, особые дни, звонки и изменения на даты
/// (docs/briefs/stage-7.md, п. 2–3). Изменение — для всех пар (правка
/// пары, особого дня или сетки звонков) или только для конкретной даты.
class ScheduleEditorScreen extends ConsumerStatefulWidget {
  const ScheduleEditorScreen({super.key});

  @override
  ConsumerState<ScheduleEditorScreen> createState() =>
      _ScheduleEditorScreenState();
}

class _ScheduleEditorScreenState extends ConsumerState<ScheduleEditorScreen> {
  EditorTab _tab = EditorTab.slots;
  String? _semesterId;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      key: const Key('schedule-editor'),
      title: 'Редактор расписания',
      parentLabel: 'Расписание',
      onBack: () => studyBack(context),
      child: StudyBody(
        builder: (context, data) {
          final live = data.liveSemesters;
          final semester =
              data.semesterById[_semesterId] != null &&
                  !data.semesterById[_semesterId]!.archived
              ? data.semesterById[_semesterId]!
              : data.currentSemester;
          if (semester == null) {
            return EmptyState(
              key: const Key('editor-no-semester'),
              icon: LucideIcons.graduationCap,
              title: 'Сначала семестр',
              message: 'Расписание относится к семестру.',
              action: FilledButton(
                onPressed: () => showSemesterEditor(context),
                child: const Text('Добавить семестр'),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (live.length > 1) ...[
                ChipRow(
                  children: [
                    for (final s in live)
                      FilterPill(
                        key: Key('editor-semester-${s.id}'),
                        label: s.name,
                        selected: s.id == semester.id,
                        onTap: () => setState(() => _semesterId = s.id),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s2),
              ],
              ChipRow(
                children: [
                  for (final t in EditorTab.values)
                    FilterPill(
                      key: Key('editor-tab-${t.name}'),
                      label: t.label,
                      selected: _tab == t,
                      onTap: () => setState(() => _tab = t),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              switch (_tab) {
                EditorTab.slots => _SlotsTab(data: data, semester: semester),
                EditorTab.rules => _RulesTab(data: data, semester: semester),
                EditorTab.bells => _BellsTab(data: data, semester: semester),
                EditorTab.overrides => _OverridesTab(
                  data: data,
                  semester: semester,
                ),
              },
            ],
          );
        },
      ),
    );
  }
}

class _SlotsTab extends StatelessWidget {
  const _SlotsTab({required this.data, required this.semester});

  final StudyData data;
  final Semester semester;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final slots = data.slotsOf(semester.id);
    final bells = {for (final b in data.bellsOf(semester.id)) b.number: b};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var wd = 1; wd <= 7; wd++) ...[
          WorkSectionHeader(
            title: weekdayName(wd),
            trailing: IconButton(
              key: Key('slots-add-$wd'),
              tooltip: 'Добавить пару',
              onPressed: () =>
                  showSlotEditor(context, semesterId: semester.id, weekday: wd),
              icon: const Icon(LucideIcons.plus, size: 20),
            ),
          ),
          Builder(
            builder: (context) {
              final day = [
                for (final s in slots)
                  if (s.weekday == wd) s,
              ]..sort((a, b) => (a.number ?? 99).compareTo(b.number ?? 99));
              if (day.isEmpty) {
                return Text(
                  'Пар нет',
                  style: t.bodyS.copyWith(color: c.textTertiary),
                );
              }
              return ListCard(
                child: Column(
                  children: [
                    for (final s in day)
                      ListTile(
                        key: Key('slot-tile-${s.id}'),
                        onTap: () => showSlotEditor(context, slotId: s.id),
                        title: Text(data.slotTitle(s)),
                        subtitle: Text(
                          [
                            _slotTime(s, bells),
                            s.kind.label,
                            if (s.building != null || s.room != null)
                              formatRoom(s.building, s.room),
                            if (s.cycleWeek != null)
                              semester.weekLabel(s.cycleWeek!),
                          ].join(' · '),
                          style: t.caption.copyWith(color: c.textSecondary),
                        ),
                        trailing: Icon(
                          LucideIcons.chevronRight,
                          size: 18,
                          color: c.textTertiary,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  String _slotTime(ClassSlot s, Map<int, Bell> bells) {
    if (s.startTime != null) return lessonTime(s.startTime, s.endTime);
    final b = bells[s.number];
    final n = s.number == null ? '' : '${s.number} пара';
    return b == null ? n : '$n, ${b.startTime}–${b.endTime}';
  }
}

class _RulesTab extends ConsumerWidget {
  const _RulesTab({required this.data, required this.semester});

  final StudyData data;
  final Semester semester;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final rules = data.rulesOf(semester.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Особый день заменяет обычные пары своим набором занятий. '
          'Например, «по четвергам обычных пар нет, 3 пары — подготовка к '
          'олимпиаде». Такие занятия в пропуски не идут.',
          style: t.bodyS.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (rules.isEmpty)
          AppCard(
            child: Text(
              'Особых дней нет.',
              key: const Key('rules-empty'),
              style: t.bodyS.copyWith(color: c.textTertiary),
            ),
          )
        else
          ListCard(
            child: Column(
              children: [
                for (final r in rules)
                  ListTile(
                    key: Key('rule-tile-${r.id}'),
                    onTap: () => showRuleEditor(
                      context,
                      semesterId: semester.id,
                      ruleId: r.id,
                    ),
                    title: Text(r.title),
                    subtitle: Text(
                      [
                        if (r.onDate != null)
                          dateLong(r.onDate!)
                        else
                          _ruleScope(r, semester),
                        if (r.hideRegular) 'обычных пар нет',
                        if (r.items.isNotEmpty) 'занятий: ${r.items.length}',
                      ].join(' · '),
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                    trailing: Icon(
                      LucideIcons.chevronRight,
                      size: 18,
                      color: c.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.s2),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('rules-add'),
            onPressed: () => showRuleEditor(context, semesterId: semester.id),
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Добавить особый день'),
          ),
        ),
      ],
    );
  }
}

String _ruleScope(DayRule r, Semester semester) {
  final day = weekdayName(r.weekday ?? 1).toLowerCase();
  final week = r.cycleWeek == null
      ? ''
      : ', ${semester.weekLabel(r.cycleWeek!).toLowerCase()}';
  return 'По дням: $day$week';
}

class _BellsTab extends StatelessWidget {
  const _BellsTab({required this.data, required this.semester});

  final StudyData data;
  final Semester semester;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final regular = data.bellsOf(semester.id);
    final dated = data.dateBellsOf(semester.id);
    final dates = {for (final b in dated) b.onDate!}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (regular.isEmpty)
          AppCard(
            child: Text(
              'Звонков нет: пары без своего времени будут без времени.',
              key: const Key('bells-empty'),
              style: t.bodyS.copyWith(color: c.textTertiary),
            ),
          )
        else
          ListCard(
            child: Column(
              children: [
                for (final b in regular)
                  ListTile(
                    key: Key('bell-tile-${b.number}'),
                    dense: true,
                    leading: SizedBox(
                      width: 28,
                      child: Text('${b.number}', style: t.bodyStrong),
                    ),
                    title: Text('${b.startTime}–${b.endTime}'),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.s2),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('bells-edit'),
            onPressed: () => showBellsEditor(context, semesterId: semester.id),
            icon: const Icon(LucideIcons.clock, size: 18),
            label: const Text('Настроить звонки'),
          ),
        ),
        const WorkSectionHeader(title: 'Звонки только на дату'),
        if (dates.isEmpty)
          Text(
            'Нет. Например, в сокращённый день можно задать другие звонки.',
            style: t.bodyS.copyWith(color: c.textTertiary),
          )
        else
          ListCard(
            child: Column(
              children: [
                for (final d in dates)
                  ListTile(
                    key: Key('bells-date-$d'),
                    onTap: () => showBellsEditor(
                      context,
                      semesterId: semester.id,
                      onDate: d,
                    ),
                    title: Text(dateLabel(d)),
                    subtitle: Text(
                      [
                        for (final b in dated)
                          if (b.onDate == d)
                            '${b.number}: ${b.startTime}–${b.endTime}',
                      ].join(' · '),
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('bells-add-date'),
            onPressed: () => showBellsEditor(
              context,
              semesterId: semester.id,
              onDate: data.today,
            ),
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Звонки на дату'),
          ),
        ),
      ],
    );
  }
}

class _OverridesTab extends ConsumerWidget {
  const _OverridesTab({required this.data, required this.semester});

  final StudyData data;
  final Semester semester;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final slots = data.slotsOf(semester.id).map((s) => s.id).toSet();
    final list = [
      for (final o in data.overrides)
        if (slots.contains(o.slotId)) o,
    ]..sort((a, b) => b.date.compareTo(a.date));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Изменения только на конкретные даты: отмена, перенос, другое время '
          'или аудитория. Создаются из расписания: нажмите на занятие.',
          style: t.bodyS.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (list.isEmpty)
          AppCard(
            child: Text(
              'Изменений нет.',
              key: const Key('overrides-empty'),
              style: t.bodyS.copyWith(color: c.textTertiary),
            ),
          )
        else
          ListCard(
            child: Column(
              children: [
                for (final o in list)
                  ListTile(
                    key: Key('override-tile-${o.id}'),
                    onTap: () => showOverrideEditor(
                      context,
                      slotId: o.slotId,
                      date: o.date,
                    ),
                    title: Text(
                      '${dateLabel(o.date)} · '
                      '${data.slotById[o.slotId] == null ? 'Пара' : data.slotTitle(data.slotById[o.slotId]!)}',
                    ),
                    subtitle: Text(switch (o.action) {
                      OverrideAction.cancel => 'Отменена',
                      OverrideAction.change => 'Изменена',
                      OverrideAction.move =>
                        'Перенесена на ${dateLabel(o.newDate ?? '')}',
                    }, style: t.caption.copyWith(color: c.textSecondary)),
                    trailing: IconButton(
                      key: Key('override-remove-${o.id}'),
                      tooltip: 'Вернуть по расписанию',
                      onPressed: () => ref
                          .read(studyRepositoryProvider)
                          .clearOverride(o.slotId, o.date),
                      icon: const Icon(LucideIcons.undo2, size: 18),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
