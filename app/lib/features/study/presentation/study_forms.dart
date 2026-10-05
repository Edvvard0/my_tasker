import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/domain/study_format.dart';
import 'package:my_tasker/features/study/domain/study_models.dart';
import 'package:my_tasker/features/study/domain/study_schedule.dart';

/// Назад из экрана «Учёбы»: на шаг назад, а при прямом входе — в «Учёбу».
void studyBack(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/study');
  }
}

/// Красная карточка «Не загрузилось» с кнопкой «Повторить».
class StudyErrorCard extends ConsumerWidget {
  const StudyErrorCard({
    required this.text,
    this.retryKey = const Key('study-retry'),
    super.key,
  });

  final String text;
  final Key retryKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) => NoticeCard(
    label: 'Не загрузилось',
    tone: StatusTone.danger,
    text: text,
    actions: [
      FilledButton(
        key: retryKey,
        onPressed: () => retryStudyData(ref),
        child: const Text('Повторить'),
      ),
    ],
  );
}

/// Тон пилюли состояния лимита пропусков (монохром: красный — только
/// превышение и исчерпание).
StatusTone limitTone(AttendanceState state) => switch (state) {
  AttendanceState.noLimit => StatusTone.neutral,
  AttendanceState.ok => StatusTone.success,
  AttendanceState.near => StatusTone.warning,
  AttendanceState.reached || AttendanceState.over => StatusTone.danger,
};

/// Время `ЧЧ:ММ` вводится текстом («8:30» → «08:30»); цифровая клавиатура.
class TimeTextField extends StatelessWidget {
  const TimeTextField({
    required this.controller,
    this.hint = '08:30',
    this.onChanged,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => FormTextField(
    controller: controller,
    onChanged: onChanged,
    keyboardType: TextInputType.datetime,
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9:. ]'))],
    decoration: InputDecoration(hintText: hint),
  );
}

/// Аудитория вводится одной строкой «к1 28» ([parseRoom]).
class RoomTextField extends StatelessWidget {
  const RoomTextField({required this.controller, super.key});

  final TextEditingController controller;

  /// Корпус и кабинет из поля; пустое поле — оба `null`; слишком длинный
  /// текст — `null` (форма скажет об ошибке через [roomFieldProblem]).
  static RoomParts value(TextEditingController controller) =>
      parseRoom(controller.text) ?? const RoomParts(null, null);

  /// Текст ошибки поля или `null`.
  static String? roomFieldProblem(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    return parseRoom(text) == null
        ? 'Аудитория — не длиннее 20 символов'
        : null;
  }

  @override
  Widget build(BuildContext context) => FormTextField(
    controller: controller,
    decoration: const InputDecoration(hintText: 'Например, к1 28'),
  );
}

/// Выбор дня недели: пилюли «Пн … Вс».
class WeekdayChips extends StatelessWidget {
  const WeekdayChips({
    required this.value,
    required this.onChanged,
    this.keyPrefix = 'weekday',
    super.key,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => ChipRow(
    children: [
      for (var d = 1; d <= 7; d++)
        FilterPill(
          key: Key('$keyPrefix-$d'),
          label: weekdayShort(d),
          selected: value == d,
          onTap: () => onChanged(d),
        ),
    ],
  );
}

/// Выбор недели цикла: «Каждая» и недели `1…length` (подписи семестра).
class CycleWeekChips extends StatelessWidget {
  const CycleWeekChips({
    required this.semester,
    required this.value,
    required this.onChanged,
    this.keyPrefix = 'cycle',
    super.key,
  });

  final Semester? semester;
  final int? value;
  final ValueChanged<int?> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final length = semester?.cycleLength ?? 1;
    return ChipRow(
      children: [
        FilterPill(
          key: Key('$keyPrefix-all'),
          label: 'Каждая',
          selected: value == null,
          onTap: () => onChanged(null),
        ),
        if (length > 1)
          for (var w = 1; w <= length; w++)
            FilterPill(
              key: Key('$keyPrefix-$w'),
              label: semester?.weekLabel(w) ?? 'Неделя $w',
              selected: value == w,
              onTap: () => onChanged(w),
            ),
      ],
    );
  }
}

/// Выбор типа занятия.
class LessonKindChips extends StatelessWidget {
  const LessonKindChips({
    required this.value,
    required this.onChanged,
    this.allowNone = false,
    this.keyPrefix = 'kind',
    super.key,
  });

  final LessonKind? value;
  final ValueChanged<LessonKind?> onChanged;

  /// Показывать «Как было» (для изменения на дату).
  final bool allowNone;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => ChipRow(
    children: [
      if (allowNone)
        FilterPill(
          key: Key('$keyPrefix-none'),
          label: 'Как было',
          selected: value == null,
          onTap: () => onChanged(null),
        ),
      for (final k in LessonKind.values)
        FilterPill(
          key: Key('$keyPrefix-${k.wire}'),
          label: k.label,
          selected: value == k,
          onTap: () => onChanged(k),
        ),
    ],
  );
}

/// Дата `YYYY-MM-DD` текстом строкой выбора: «Сегодня · Завтра · Выбрать».
String? isoOf(DateTime? date) => date == null ? null : formatDate(date);

/// Строка-предупреждение в форме: иконка и текст.
class FormHint extends StatelessWidget {
  const FormHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.info, size: 16, color: context.colors.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: context.text.bodyS.copyWith(
              color: context.colors.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );
}
