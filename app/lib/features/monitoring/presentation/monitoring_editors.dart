import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_repository.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_validation.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_models.dart'
    show WorkProject;
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

// ---------------------------------------------------------------- общее

/// Нижняя панель формы: «Удалить» слева (у существующей строки) и
/// «Сохранить» справа.
class _EditorActions extends StatelessWidget {
  const _EditorActions({
    required this.keyPrefix,
    required this.saving,
    required this.onSave,
    this.onDelete,
  });

  final String keyPrefix;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s6,
        AppSpacing.s2,
        AppSpacing.s6,
        AppSpacing.s4,
      ),
      child: Row(
        children: [
          if (onDelete != null)
            TextButton(
              key: Key('$keyPrefix-delete'),
              onPressed: onDelete,
              child: Text(
                'Удалить',
                style: TextStyle(color: context.colors.danger),
              ),
            ),
          const Spacer(),
          FilledButton(
            key: Key('$keyPrefix-save'),
            onPressed: saving ? null : onSave,
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SheetHeader(title: title),
      Padding(
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: Text(
          text,
          style: context.text.body.copyWith(
            color: context.colors.textSecondary,
          ),
        ),
      ),
    ],
  );
}

String? _blankToNull(String text) {
  final t = text.trim();
  return t.isEmpty ? null : t;
}

/// Целое из текста поля: пусто — `null`; не число — `-1` (даст ошибку
/// проверки, а не молчаливое «пусто»).
int? _intOf(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  return int.tryParse(t) ?? -1;
}

// ---------------------------------------------------------------- сервер

/// Редактор сервера: [serverId] — правка, иначе создание. Возвращает id.
Future<String?> showServerEditor(BuildContext context, {String? serverId}) =>
    showEditorSheet<String>(
      context,
      builder: (_) => ServerEditor(serverId: serverId),
    );

class ServerEditor extends ConsumerStatefulWidget {
  const ServerEditor({this.serverId, super.key});

  final String? serverId;

  @override
  ConsumerState<ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends ConsumerState<ServerEditor> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _provider = TextEditingController();
  final _note = TextEditingController();
  MonitorServer? _original;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.serverId == null;

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
    _host.dispose();
    _provider.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await ref
        .read(monitoringRepositoryProvider)
        .getServer(widget.serverId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (s == null) {
        _missing = true;
      } else {
        _original = s;
        _name.text = s.name;
        _host.text = s.host;
        _provider.text = s.provider ?? '';
        _note.text = s.note ?? '';
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final repo = ref.read(monitoringRepositoryProvider);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final draft = MonitorServer(
        id: _original?.id ?? repo.newId(),
        name: _name.text,
        host: _host.text,
        provider: _blankToNull(_provider.text),
        note: _blankToNull(_note.text),
      );
      if (_isNew) {
        await repo.createServer(draft);
      } else {
        await repo.updateServer(draft);
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

  Future<void> _delete() async {
    final s = _original;
    if (s == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить сервер «${s.name}»?',
      message:
          'Сервисы и проверки сервера уйдут в корзину на 30 дней, мониторинг '
          'перестанет их проверять. Сами серверы приложение не трогает.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(monitoringRepositoryProvider).deleteServer(s.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_missing) {
      return const _Missing(
        title: 'Сервер',
        text: 'Сервер не найден: возможно, его удалили на другом устройстве.',
      );
    }
    final hostText = _host.text;
    final hostProblem = hostText.trim().isEmpty
        ? null
        : hostFieldProblem(hostText);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый сервер' : 'Сервер'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('server-name'),
                      controller: _name,
                      autofocus: _isNew,
                      decoration: const InputDecoration(
                        hintText: 'Например, Основной VPS',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Адрес: имя или публичный IP',
                    child: FormTextField(
                      key: const Key('server-host'),
                      controller: _host,
                      keyboardType: TextInputType.url,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'example.com или 203.0.113.7',
                        errorText: hostProblem,
                        errorMaxLines: 3,
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Провайдер (необязательно)',
                    child: FormTextField(
                      key: const Key('server-provider'),
                      controller: _provider,
                      decoration: const InputDecoration(
                        hintText: 'Например, Timeweb',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Заметка (необязательно)',
                    child: FormTextField(
                      key: const Key('server-note'),
                      controller: _note,
                      minLines: 2,
                      maxLines: 4,
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('server-error')),
                ],
              ),
            ),
          ),
          _EditorActions(
            keyPrefix: 'server',
            saving: _saving,
            onSave: _save,
            onDelete: _isNew ? null : _delete,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- сервис

/// Редактор сервиса на сервере [serverId]: [serviceId] — правка, иначе
/// создание. Возвращает id.
Future<String?> showServiceEditor(
  BuildContext context, {
  required String serverId,
  String? serviceId,
}) => showEditorSheet<String>(
  context,
  builder: (_) => ServiceEditor(serverId: serverId, serviceId: serviceId),
);

class ServiceEditor extends ConsumerStatefulWidget {
  const ServiceEditor({required this.serverId, this.serviceId, super.key});

  final String serverId;
  final String? serviceId;

  @override
  ConsumerState<ServiceEditor> createState() => _ServiceEditorState();
}

class _ServiceEditorState extends ConsumerState<ServiceEditor> {
  final _name = TextEditingController();
  final _note = TextEditingController();
  MonitorService? _original;
  bool _critical = false;
  String? _projectId;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.serviceId == null;

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
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await ref
        .read(monitoringRepositoryProvider)
        .getService(widget.serviceId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (s == null) {
        _missing = true;
      } else {
        _original = s;
        _name.text = s.name;
        _note.text = s.note ?? '';
        _critical = s.critical;
        _projectId = s.workProjectId;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final repo = ref.read(monitoringRepositoryProvider);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final draft = MonitorService(
        id: _original?.id ?? repo.newId(),
        serverId: _original?.serverId ?? widget.serverId,
        name: _name.text,
        workProjectId: _projectId,
        critical: _critical,
        note: _blankToNull(_note.text),
      );
      if (_isNew) {
        await repo.createService(draft);
      } else {
        await repo.updateService(draft);
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

  Future<void> _delete() async {
    final s = _original;
    if (s == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить сервис «${s.name}»?',
      message:
          'Его проверки уйдут в корзину на 30 дней, сервис исчезнет из '
          '«Пульса», а тревоги по нему прекратятся.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(monitoringRepositoryProvider).deleteService(s.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_missing) {
      return const _Missing(
        title: 'Сервис',
        text: 'Сервис не найден: возможно, его удалили на другом устройстве.',
      );
    }
    final projects = [
      for (final p
          in ref.watch(workProjectsProvider).value ?? const <WorkProject>[])
        if (!p.archived || p.id == _projectId) p,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый сервис' : 'Сервис'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('service-name'),
                      controller: _name,
                      autofocus: _isNew,
                      decoration: const InputDecoration(
                        hintText: 'Например, Сайт (VPS)',
                      ),
                    ),
                  ),
                  SwitchListTile(
                    key: const Key('service-critical'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Критичный'),
                    subtitle: const Text('Тревога приходит и в тихие часы.'),
                    value: _critical,
                    onChanged: (v) => setState(() => _critical = v),
                  ),
                  if (projects.isNotEmpty)
                    FormBlock(
                      label: 'Проект из «Работы» (необязательно)',
                      child: ChipRow(
                        children: [
                          FilterPill(
                            key: const Key('service-project-none'),
                            label: 'Без проекта',
                            selected: _projectId == null,
                            onTap: () => setState(() => _projectId = null),
                          ),
                          for (final p in projects)
                            FilterPill(
                              key: Key('service-project-${p.id}'),
                              label: p.title,
                              selected: _projectId == p.id,
                              onTap: () => setState(() => _projectId = p.id),
                            ),
                        ],
                      ),
                    ),
                  FormBlock(
                    label: 'Заметка (необязательно)',
                    child: FormTextField(
                      key: const Key('service-note'),
                      controller: _note,
                      minLines: 2,
                      maxLines: 4,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          LucideIcons.info,
                          size: 16,
                          color: c.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Пауза и «Выключить» не предусмотрены: ненужный '
                            'сервис удаляется в корзину.',
                            style: context.text.bodyS.copyWith(
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('service-error')),
                ],
              ),
            ),
          ),
          _EditorActions(
            keyPrefix: 'service',
            saving: _saving,
            onSave: _save,
            onDelete: _isNew ? null : _delete,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- проверка

/// Редактор проверки сервиса [serviceId]: [checkId] — правка (вид не
/// меняется), иначе создание. Возвращает id.
Future<String?> showCheckEditor(
  BuildContext context, {
  required String serviceId,
  String? checkId,
}) => showEditorSheet<String>(
  context,
  builder: (_) => CheckEditor(serviceId: serviceId, checkId: checkId),
);

/// Форма проверки: поля зависят от вида (HTTP / TCP / DNS / SSL), адрес
/// проверяется теми же правилами, что на сервере (SSRF, общие векторы), и
/// ошибка видна сразу под полем.
class CheckEditor extends ConsumerStatefulWidget {
  const CheckEditor({required this.serviceId, this.checkId, super.key});

  final String serviceId;
  final String? checkId;

  @override
  ConsumerState<CheckEditor> createState() => _CheckEditorState();
}

class _CheckEditorState extends ConsumerState<CheckEditor> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _status = TextEditingController();
  final _keyword = TextEditingController();
  final _expected = TextEditingController();
  final _days = TextEditingController();
  final _interval = TextEditingController(
    text: '${MonitorCheck.defaultInterval}',
  );
  final _timeout = TextEditingController(
    text: '${MonitorCheck.defaultTimeout}',
  );
  MonitorCheck? _original;
  CheckKind _kind = CheckKind.http;
  String _record = 'A';
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.checkId == null;

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
    for (final c in [
      _name,
      _url,
      _host,
      _port,
      _status,
      _keyword,
      _expected,
      _days,
      _interval,
      _timeout,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final c = await ref
        .read(monitoringRepositoryProvider)
        .getCheck(widget.checkId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (c == null) {
        _missing = true;
        return;
      }
      _original = c;
      _kind = c.kind;
      _name.text = c.name;
      _url.text = c.url ?? '';
      _host.text = c.host ?? '';
      _port.text = c.port?.toString() ?? '';
      _status.text = c.expectedStatus?.toString() ?? '';
      _keyword.text = c.keyword ?? '';
      _expected.text = c.expectedValue ?? '';
      _days.text = c.sslMinDays?.toString() ?? '';
      _record = c.dnsRecordType ?? 'A';
      _interval.text = '${c.intervalSeconds}';
      _timeout.text = '${c.timeoutSeconds}';
    });
  }

  /// Черновик проверки из полей формы (поля чужих видов пустые).
  MonitorCheck _draft(String id) {
    final http = _kind == CheckKind.http;
    final dns = _kind == CheckKind.dns;
    final ssl = _kind == CheckKind.ssl;
    final tcp = _kind == CheckKind.tcp;
    return MonitorCheck(
      id: id,
      serviceId: _original?.serviceId ?? widget.serviceId,
      kind: _kind,
      name: _name.text,
      url: http ? _url.text : null,
      host: http ? null : _host.text,
      port: (tcp || ssl) ? _intOf(_port.text) : null,
      dnsRecordType: dns ? _record : null,
      expectedValue: dns ? _blankToNull(_expected.text) : null,
      expectedStatus: http ? _intOf(_status.text) : null,
      keyword: http ? _blankToNull(_keyword.text) : null,
      sslMinDays: ssl ? _intOf(_days.text) : null,
      intervalSeconds: _intOf(_interval.text) ?? -1,
      timeoutSeconds: _intOf(_timeout.text) ?? -1,
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final repo = ref.read(monitoringRepositoryProvider);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final draft = _draft(_original?.id ?? repo.newId());
      if (_isNew) {
        await repo.createCheck(draft);
      } else {
        await repo.updateCheck(draft);
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

  Future<void> _delete() async {
    final c = _original;
    if (c == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить проверку «${c.name}»?',
      message:
          'Проверка уйдёт в корзину на 30 дней и перестанет запускаться. Вид '
          'проверки не меняется: нужна другая — создайте новую.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(monitoringRepositoryProvider).deleteCheck(c.id);
    if (mounted) Navigator.of(context).pop();
  }

  /// Ошибка поля цели, когда в нём уже что-то введено.
  String? _targetProblem() {
    if (_kind == CheckKind.http) {
      return _url.text.trim().isEmpty ? null : urlFieldProblem(_url.text);
    }
    return _host.text.trim().isEmpty ? null : hostFieldProblem(_host.text);
  }

  String? _numberProblem(TextEditingController c, int min, int max) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    return n == null || n < min || n > max ? 'От $min до $max' : null;
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
      return const _Missing(
        title: 'Проверка',
        text: 'Проверка не найдена: возможно, её удалили на другом устройстве.',
      );
    }
    final digits = [FilteringTextInputFormatter.digitsOnly];
    final targetProblem = _targetProblem();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новая проверка' : 'Проверка'),
          Flexible(
            child: SingleChildScrollView(
              key: const Key('check-form'),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Вид проверки',
                    child: _isNew
                        ? ChipRow(
                            children: [
                              for (final k in CheckKind.values)
                                FilterPill(
                                  key: Key('check-kind-${k.wire}'),
                                  label: k.label,
                                  selected: _kind == k,
                                  onTap: () => setState(() => _kind = k),
                                ),
                            ],
                          )
                        : Text(
                            '${_kind.label} · вид не меняется',
                            key: const Key('check-kind-fixed'),
                            style: t.body,
                          ),
                  ),
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('check-name'),
                      controller: _name,
                      autofocus: _isNew,
                      decoration: const InputDecoration(
                        hintText: 'Например, Главная',
                      ),
                    ),
                  ),
                  ..._kindFields(digits, targetProblem),
                  FormBlock(
                    label: 'Как часто проверять, секунд',
                    child: FormTextField(
                      key: const Key('check-interval'),
                      controller: _interval,
                      keyboardType: TextInputType.number,
                      inputFormatters: digits,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        helperText: 'От 10 до 3600; рекомендуем 20',
                        errorText: _numberProblem(_interval, 10, 3600),
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Сколько ждать ответа, секунд',
                    child: FormTextField(
                      key: const Key('check-timeout'),
                      controller: _timeout,
                      keyboardType: TextInputType.number,
                      inputFormatters: digits,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        helperText: 'От 1 до 30 и меньше интервала',
                        errorText: _numberProblem(_timeout, 1, 30),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          LucideIcons.info,
                          size: 16,
                          color: c.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Проверяет сервер мониторинга, а не телефон. '
                            'Адреса внутренней сети и имена без точки '
                            'недоступны; редиректы не выполняются.',
                            style: t.bodyS.copyWith(color: c.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('check-error')),
                ],
              ),
            ),
          ),
          _EditorActions(
            keyPrefix: 'check',
            saving: _saving,
            onSave: _save,
            onDelete: _isNew ? null : _delete,
          ),
        ],
      ),
    );
  }

  List<Widget> _kindFields(
    List<TextInputFormatter> digits,
    String? targetProblem,
  ) {
    InputDecoration target(String hint, String? error) =>
        InputDecoration(hintText: hint, errorText: error, errorMaxLines: 3);
    switch (_kind) {
      case CheckKind.http:
        return [
          FormBlock(
            label: 'Адрес (URL)',
            child: FormTextField(
              key: const Key('check-url'),
              controller: _url,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              decoration: target('https://example.com/health', targetProblem),
            ),
          ),
          FormBlock(
            label: 'Ожидаемый код ответа (необязательно)',
            child: FormTextField(
              key: const Key('check-status'),
              controller: _status,
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                helperText: 'Пусто — любой код меньше 400',
                errorText: _numberProblem(_status, 100, 599),
              ),
            ),
          ),
          FormBlock(
            label: 'Слово, которое должно быть на странице (необязательно)',
            child: FormTextField(
              key: const Key('check-keyword'),
              controller: _keyword,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                helperText:
                    'Одно слово, без пробелов и знаков * ( ) [ ] \' " < >',
                helperMaxLines: 2,
                errorText:
                    _keyword.text.isEmpty ||
                        keywordPattern.hasMatch(_keyword.text)
                    ? null
                    : 'Нужно одно слово без пробелов и запрещённых знаков',
                errorMaxLines: 2,
              ),
            ),
          ),
        ];
      case CheckKind.tcp:
        return [
          FormBlock(
            label: 'Хост',
            child: FormTextField(
              key: const Key('check-host'),
              controller: _host,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              decoration: target('db.example.com', targetProblem),
            ),
          ),
          FormBlock(
            label: 'Порт',
            child: FormTextField(
              key: const Key('check-port'),
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '5432',
                errorText: _numberProblem(_port, 1, 65535),
              ),
            ),
          ),
        ];
      case CheckKind.dns:
        return [
          FormBlock(
            label: 'Имя для запроса',
            child: FormTextField(
              key: const Key('check-host'),
              controller: _host,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              decoration: target('example.com', targetProblem),
            ),
          ),
          FormBlock(
            label: 'Тип записи',
            child: ChipRow(
              children: [
                for (final r in dnsRecordTypes)
                  FilterPill(
                    key: Key('check-record-$r'),
                    label: r,
                    selected: _record == r,
                    onTap: () => setState(() => _record = r),
                  ),
              ],
            ),
          ),
          FormBlock(
            label: 'Ожидаемое значение (необязательно)',
            child: FormTextField(
              key: const Key('check-expected'),
              controller: _expected,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                helperText: 'Одно слово из букв, цифр и знаков . _ : / -',
                errorText:
                    _expected.text.isEmpty ||
                        expectedValuePattern.hasMatch(_expected.text)
                    ? null
                    : 'Допустимы буквы, цифры и знаки . _ : / - без пробелов',
                errorMaxLines: 2,
              ),
            ),
          ),
        ];
      case CheckKind.ssl:
        return [
          FormBlock(
            label: 'Хост',
            child: FormTextField(
              key: const Key('check-host'),
              controller: _host,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              decoration: target('example.com', targetProblem),
            ),
          ),
          FormBlock(
            label: 'Порт (необязательно)',
            child: FormTextField(
              key: const Key('check-port'),
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                helperText: 'Пусто — 443',
                errorText: _numberProblem(_port, 1, 65535),
              ),
            ),
          ),
          FormBlock(
            label: 'Минимум дней до конца сертификата (необязательно)',
            child: FormTextField(
              key: const Key('check-days'),
              controller: _days,
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                helperText: 'Пусто — 14',
                errorText: _numberProblem(_days, 1, 365),
              ),
            ),
          ),
        ];
    }
  }
}
