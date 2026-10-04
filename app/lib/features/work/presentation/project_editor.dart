import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart';

/// Открывает редактор проекта: [projectId] — правка, иначе создание.
Future<String?> showProjectEditor(BuildContext context, {String? projectId}) =>
    showEditorSheet<String>(
      context,
      builder: (_) => ProjectEditor(projectId: projectId),
    );

class _LinkDraft {
  _LinkDraft(this.url, this.title);

  final String url;
  final String title;
}

/// Редактор проекта: название, заказчик, статус, тип оплаты, базовая
/// сумма, ставка, даты, описание и ссылки. Итоговая сумма не вводится:
/// база плюс доработки (spec 4.2).
class ProjectEditor extends ConsumerStatefulWidget {
  const ProjectEditor({this.projectId, super.key});

  final String? projectId;

  @override
  ConsumerState<ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends ConsumerState<ProjectEditor> {
  final _title = TextEditingController();
  final _base = TextEditingController();
  final _rate = TextEditingController();
  final _description = TextEditingController();
  final _linkUrl = TextEditingController();
  final _linkTitle = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  WorkProject? _original;
  String? _clientId;
  ProjectStatus _status = ProjectStatus.active;
  PayType _payType = PayType.fixed;
  DateTime? _start;
  DateTime? _deadline;
  DateTime? _completed;
  final List<_LinkDraft> _links = [];
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.projectId == null;

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
    _title.dispose();
    _base.dispose();
    _rate.dispose();
    _description.dispose();
    _linkUrl.dispose();
    _linkTitle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final project = await ref
        .read(workRepositoryProvider)
        .getProject(widget.projectId!);
    if (!mounted) return;
    if (project == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _original = project;
      _title.text = project.title;
      _clientId = project.clientId;
      _status = project.effectiveStatus;
      _payType = project.effectivePayType;
      _base.text = moneyFieldText(project.baseAmount);
      _rate.text = moneyFieldText(project.hourlyRate);
      _description.text = project.description ?? '';
      _start = dateFromText(project.startDate);
      _deadline = dateFromText(project.deadlineDate);
      _completed = dateFromText(project.completedDate);
      for (final l in project.links) {
        _links.add(_LinkDraft(l.url, l.title ?? ''));
      }
      _loading = false;
    });
  }

  void _addLink() {
    final url = _linkUrl.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _links.add(_LinkDraft(url, _linkTitle.text.trim()));
      _linkUrl.clear();
      _linkTitle.clear();
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final base = parseMoneyField(_base.text, 'Базовая сумма');
    final rate = parseMoneyField(_rate.text, 'Ставка');
    final problem = base.error ?? rate.error;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    if (_linkUrl.text.trim().isNotEmpty) _addLink();
    final repo = ref.read(workRepositoryProvider);
    try {
      final today = ref.read(todayProvider);
      final completed = _status == ProjectStatus.completed
          ? (_completed ?? today)
          : _completed;
      final draft = (_original ?? WorkProject(id: repo.newId(), title: ''))
          .copyWith(
            title: _title.text,
            clientId: _clientId,
            status: _status,
            payType: _payType,
            baseAmount: base.kopecks,
            hourlyRate: rate.kopecks,
            startDate: dateToText(_start),
            deadlineDate: dateToText(_deadline),
            completedDate: dateToText(completed),
            description: _description.text.trim().isEmpty
                ? null
                : _description.text.trim(),
            links: [
              for (final l in _links)
                ProjectLink(
                  url: l.url,
                  title: l.title.isEmpty ? null : l.title,
                ),
            ],
            // Возврат в работу снимает архив (в архиве — только завершённые).
            archived: _status.archivable ? _original?.archived : false,
          );
      if (_isNew) {
        await repo.createProject(draft);
      } else {
        await repo.updateProject(draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop(draft.id);
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _newClient() async {
    final name = await askText(
      context,
      title: 'Новый заказчик',
      hint: 'Имя заказчика',
    );
    if (name == null || !mounted) return;
    final repo = ref.read(workRepositoryProvider);
    try {
      final id = repo.newId();
      await repo.createPerson(
        WorkPerson(id: id, name: name, role: PersonRole.client),
      );
      if (mounted) setState(() => _clientId = id);
    } on ValidationError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
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
          const SheetHeader(title: 'Проект'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Проект не найден: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = ref.watch(todayProvider);
    final people = ref.watch(workPeopleProvider).value ?? const <WorkPerson>[];
    final clients = [
      for (final p in people)
        if (!p.archived || p.id == _clientId) p,
    ]..sort((a, b) => (b.isClient ? 1 : 0).compareTo(a.isClient ? 1 : 0));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый проект' : 'Проект'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('project-title'),
                      controller: _title,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Например, Бот разборов',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Заказчик',
                    child: ChipRow(
                      children: [
                        FilterPill(
                          key: const Key('project-client-none'),
                          label: 'Не указан',
                          selected: _clientId == null,
                          onTap: () => setState(() => _clientId = null),
                        ),
                        for (final p in clients)
                          FilterPill(
                            key: Key('project-client-${p.id}'),
                            label: p.name,
                            selected: _clientId == p.id,
                            icon: LucideIcons.user,
                            onTap: () => setState(() => _clientId = p.id),
                          ),
                        FilterPill(
                          key: const Key('project-client-new'),
                          label: 'Новый',
                          selected: false,
                          icon: LucideIcons.plus,
                          onTap: _newClient,
                        ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Статус',
                    child: ChipRow(
                      children: [
                        for (final s in ProjectStatus.values)
                          FilterPill(
                            key: Key('project-status-${s.wire}'),
                            label: s.label,
                            selected: _status == s,
                            onTap: () => setState(() => _status = s),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Оплата',
                    child: ChipRow(
                      children: [
                        for (final p in PayType.values)
                          FilterPill(
                            key: Key('project-paytype-${p.wire}'),
                            label: p.label,
                            selected: _payType == p,
                            onTap: () => setState(() => _payType = p),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Базовая сумма',
                    child: MoneyTextField(
                      key: const Key('project-base'),
                      controller: _base,
                    ),
                  ),
                  if (_payType == PayType.hourly)
                    FormBlock(
                      label: 'Ставка в час',
                      child: MoneyTextField(
                        key: const Key('project-rate'),
                        controller: _rate,
                      ),
                    ),
                  FormBlock(
                    label: 'Дата начала',
                    child: DateChoiceRow(
                      keyPrefix: 'project-start',
                      today: today,
                      value: _start,
                      allowNone: true,
                      noneLabel: 'Не указана',
                      onChanged: (d) => setState(() => _start = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Срок',
                    child: DateChoiceRow(
                      keyPrefix: 'project-deadline',
                      today: today,
                      value: _deadline,
                      allowNone: true,
                      noneLabel: 'Без срока',
                      onChanged: (d) => setState(() => _deadline = d),
                    ),
                  ),
                  if (_status == ProjectStatus.completed)
                    FormBlock(
                      label: 'Дата завершения',
                      child: DateChoiceRow(
                        keyPrefix: 'project-completed',
                        today: today,
                        value: _completed ?? today,
                        onChanged: (d) => setState(() => _completed = d),
                      ),
                    ),
                  FormBlock(
                    label: 'Описание',
                    child: FormTextField(
                      key: const Key('project-description'),
                      controller: _description,
                      minLines: 2,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        hintText: 'Договорённости, доступы, заметки',
                      ),
                    ),
                  ),
                  FormBlock(label: 'Ссылки', child: _linksField(context)),
                  if (_error != null)
                    FormError(_error!, key: const Key('project-error')),
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
                const Spacer(),
                FilledButton(
                  key: const Key('project-save'),
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

  Widget _linksField(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _links.length; i++)
          Row(
            key: Key('project-link-$i'),
            children: [
              Icon(LucideIcons.link, size: 16, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  _links[i].title.isEmpty
                      ? _links[i].url
                      : '${_links[i].title} · ${_links[i].url}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Убрать ссылку',
                onPressed: () => setState(() => _links.removeAt(i)),
                icon: const Icon(LucideIcons.x, size: 18),
              ),
            ],
          ),
        FormTextField(
          key: const Key('project-link-url'),
          controller: _linkUrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://…'),
        ),
        FormTextField(
          key: const Key('project-link-title'),
          controller: _linkTitle,
          decoration: const InputDecoration(
            hintText: 'Название (необязательно)',
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('project-link-add'),
            onPressed: _addLink,
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Добавить ссылку'),
          ),
        ),
      ],
    );
  }
}
