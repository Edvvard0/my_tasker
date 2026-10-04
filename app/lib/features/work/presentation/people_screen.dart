import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/project_list.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

/// Открывает форму человека: [personId] — правка, иначе новый.
Future<void> showPersonEditor(BuildContext context, {String? personId}) =>
    showEditorSheet<void>(
      context,
      builder: (_) => PersonEditor(personId: personId),
    );

/// «Люди»: заказчики и другие; у заказчика видны его проекты и долг.
class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key});

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  bool _archived = false;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(workDataProvider);
    return ScreenScaffold(
      key: const Key('people-screen'),
      title: 'Люди',
      parentLabel: 'Работа',
      onBack: () => workBack(context),
      actions: [
        IconButton(
          key: const Key('people-add'),
          tooltip: 'Новый человек',
          onPressed: () => showPersonEditor(context),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: data.when(
        loading: () => const ListSkeleton(),
        error: (error, _) => const NoticeCard(
          label: 'Не загрузилось',
          tone: StatusTone.danger,
          text: 'Не удалось прочитать людей на устройстве.',
        ),
        data: (d) => _body(context, d),
      ),
    );
  }

  Widget _body(BuildContext context, WorkData data) {
    final people = [
      for (final p in data.people)
        if (p.archived == _archived) p,
    ];
    final archivedCount = data.people.where((p) => p.archived).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChipRow(
          children: [
            FilterPill(
              key: const Key('people-filter-active'),
              label: 'Активные',
              selected: !_archived,
              onTap: () => setState(() => _archived = false),
            ),
            FilterPill(
              key: const Key('people-filter-archive'),
              label: archivedCount == 0 ? 'Архив' : 'Архив · $archivedCount',
              selected: _archived,
              onTap: () => setState(() => _archived = true),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),
        if (people.isEmpty)
          EmptyState(
            key: const Key('people-empty'),
            icon: LucideIcons.users,
            title: _archived ? 'Архив пуст' : 'Людей пока нет',
            message: _archived
                ? 'Сюда попадают люди, которых вы убрали в архив.'
                : 'Добавьте заказчика, чтобы видеть, кто сколько должен.',
          )
        else
          for (final p in people) ...[
            _PersonCard(data: data, person: p),
            const SizedBox(height: AppSpacing.s2),
          ],
      ],
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.data, required this.person});

  final WorkData data;
  final WorkPerson person;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final projects = [
      for (final p in data.projects)
        if (p.clientId == person.id) p,
    ];
    var owed = 0;
    for (final g in data.receivablesAll.clients) {
      if (g.clientId == person.id) owed = g.remaining;
    }
    final caption = [
      person.role?.label ?? PersonRole.other.label,
      if (projects.isNotEmpty)
        '${projects.length} ${pluralWord(projects.length, 'проект', 'проекта', 'проектов')}',
      if ((person.contact ?? '').isNotEmpty) person.contact!,
    ].join(' · ');
    return InkWell(
      key: Key('person-${person.id}'),
      borderRadius: AppRadii.borderL,
      onTap: () => showPersonEditor(context, personId: person.id),
      child: AppCard(
        child: Row(
          children: [
            PersonAvatar(name: person.name),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    style: t.h3,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    caption,
                    style: t.bodyS.copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (owed > 0)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatAmount(owed),
                    key: Key('person-owed-${person.id}'),
                    style: t.numL,
                  ),
                  Text(
                    'должен',
                    style: t.caption.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Форма человека: имя, роль, контакт (свободный текст), архив и удаление.
class PersonEditor extends ConsumerStatefulWidget {
  const PersonEditor({this.personId, super.key});

  final String? personId;

  @override
  ConsumerState<PersonEditor> createState() => _PersonEditorState();
}

class _PersonEditorState extends ConsumerState<PersonEditor> {
  final _name = TextEditingController();
  final _contact = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  WorkPerson? _original;
  PersonRole _role = PersonRole.client;
  bool _archived = false;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.personId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final person = await ref
        .read(workRepositoryProvider)
        .getPerson(widget.personId!);
    if (!mounted) return;
    if (person == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _original = person;
      _name.text = person.name;
      _contact.text = person.contact ?? '';
      _role = person.role ?? PersonRole.other;
      _archived = person.archived;
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(workRepositoryProvider);
    try {
      final draft = (_original ?? WorkPerson(id: repo.newId(), name: ''))
          .copyWith(
            name: _name.text,
            role: _role,
            contact: _contact.text.trim().isEmpty ? null : _contact.text.trim(),
            archived: _archived,
          );
      if (_isNew) {
        await repo.createPerson(draft);
      } else {
        await repo.updatePerson(draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить «${_name.text}»?',
      message:
          'Проекты и платежи останутся, у них будет «заказчик не указан». '
          'Человека можно вернуть из корзины.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(workRepositoryProvider).deletePerson(widget.personId!);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_missing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Человек'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Человек не найден: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый человек' : 'Человек'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Имя',
                    child: FormTextField(
                      key: const Key('person-name'),
                      controller: _name,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(hintText: 'Имя'),
                    ),
                  ),
                  FormBlock(
                    label: 'Роль',
                    child: ChipRow(
                      children: [
                        for (final r in PersonRole.values)
                          FilterPill(
                            key: Key('person-role-${r.wire}'),
                            label: r.label,
                            selected: _role == r,
                            onTap: () => setState(() => _role = r),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Контакт',
                    child: FormTextField(
                      key: const Key('person-contact'),
                      controller: _contact,
                      decoration: const InputDecoration(
                        hintText: 'Телефон, Telegram, почта',
                      ),
                    ),
                  ),
                  if (!_isNew)
                    SwitchListTile(
                      key: const Key('person-archived'),
                      contentPadding: EdgeInsets.zero,
                      title: Text('В архиве', style: t.body),
                      value: _archived,
                      onChanged: (v) => setState(() => _archived = v),
                    ),
                  if (_error != null)
                    FormError(_error!, key: const Key('person-error')),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s6,
              AppSpacing.s2,
              AppSpacing.s6,
              AppSpacing.s4,
            ),
            child: Row(
              children: [
                if (!_isNew)
                  OutlinedButton.icon(
                    key: const Key('person-delete'),
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.danger,
                      side: BorderSide(color: c.danger),
                    ),
                    icon: const Icon(LucideIcons.trash2, size: 18),
                    label: const Text('Удалить'),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('person-save'),
                  onPressed: _saving ? null : _save,
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
