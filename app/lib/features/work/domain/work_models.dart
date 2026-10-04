import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';

/// Модели «Работы» (spec Этапа 4, раздел 1). Даты — строки `YYYY-MM-DD`
/// (как в эталоне расчётов: сравнение строк), моменты — UTC [DateTime],
/// деньги — целые копейки.
///
/// Чтение «мягкое»: строка с неизвестным значением перечисления (новая
/// версия сервера) читается как значение по умолчанию, а не ломает экран.

const Object _unset = Object();

DateTime? _instant(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String? _instantText(DateTime? value) {
  if (value == null) return null;
  final t = value.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
}

/// Момент в виде, который уходит в колонку `datetime` (`…Z`, без долей).
String? storedWorkInstant(DateTime? value) => _instantText(value);

/// Статус проекта (`projects.status`); `null` в строке ≡ [active].
enum ProjectStatus {
  lead('Лид', 'lead'),
  active('В работе', 'active'),
  paused('Пауза', 'paused'),
  completed('Завершён', 'completed'),
  cancelled('Отменён', 'cancelled');

  const ProjectStatus(this.label, this.wire);

  final String label;
  final String wire;

  static ProjectStatus? parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return null;
  }

  /// Такой проект можно отправить в архив (spec 1.1).
  bool get archivable => this == completed || this == cancelled;
}

/// Тип оплаты проекта; `null` ≡ [fixed].
enum PayType {
  fixed('Фикс', 'fixed'),
  hourly('Почасовая', 'hourly');

  const PayType(this.label, this.wire);

  final String label;
  final String wire;

  static PayType? parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return null;
  }
}

/// Роль человека; `null` ≡ [other].
enum PersonRole {
  client('Заказчик', 'client'),
  other('Другое', 'other');

  const PersonRole(this.label, this.wire);

  final String label;
  final String wire;

  static PersonRole? parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return null;
  }
}

/// Статус доработки.
enum ChangeRequestStatus {
  inProgress('В работе', 'in_progress'),
  closed('Закрыта', 'closed'),
  cancelled('Отменена', 'cancelled');

  const ChangeRequestStatus(this.label, this.wire);

  final String label;
  final String wire;

  static ChangeRequestStatus parse(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return inProgress;
  }
}

/// Источник записи времени.
enum TimeSource {
  timer('timer'),
  manual('manual');

  const TimeSource(this.wire);

  final String wire;

  static TimeSource parse(Object? value) => value == 'manual' ? manual : timer;
}

/// Ссылка проекта (`projects.links`).
@immutable
class ProjectLink {
  const ProjectLink({required this.url, this.title});

  final String url;
  final String? title;

  Json toJson() => {
    'url': url,
    if (title != null && title!.isNotEmpty) 'title': title,
  };
}

List<ProjectLink> _links(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map && item['url'] is String)
        ProjectLink(
          url: item['url']! as String,
          title: item['title'] is String ? item['title']! as String : null,
        ),
  ];
}

/// Проект (`projects`, Этапы 2 и 4).
@immutable
class WorkProject {
  const WorkProject({
    required this.id,
    required this.title,
    this.color,
    this.archived = false,
    this.clientId,
    this.status,
    this.payType,
    this.baseAmount,
    this.hourlyRate,
    this.startDate,
    this.deadlineDate,
    this.completedDate,
    this.description,
    this.links = const [],
  });

  factory WorkProject.fromRow(Json row) => WorkProject(
    id: row['id']! as String,
    title: (row['title'] as String?) ?? '',
    color: row['color'] as String?,
    archived: row['archived'] == true,
    clientId: row['client_id'] as String?,
    status: ProjectStatus.parse(row['status']),
    payType: PayType.parse(row['pay_type']),
    baseAmount: row['base_amount'] as int?,
    hourlyRate: row['hourly_rate'] as int?,
    startDate: row['start_date'] as String?,
    deadlineDate: row['deadline_date'] as String?,
    completedDate: row['completed_date'] as String?,
    description: row['description'] as String?,
    links: _links(row['links']),
  );

  final String id;
  final String title;
  final String? color;
  final bool archived;

  /// Заказчик → `people.id` (мягкая ссылка).
  final String? clientId;

  /// Сырое значение колонки; `null` ≡ «в работе».
  final ProjectStatus? status;
  final PayType? payType;
  final int? baseAmount;
  final int? hourlyRate;
  final String? startDate;
  final String? deadlineDate;
  final String? completedDate;
  final String? description;
  final List<ProjectLink> links;

  ProjectStatus get effectiveStatus => status ?? ProjectStatus.active;
  PayType get effectivePayType => payType ?? PayType.fixed;
  int get base => baseAmount ?? 0;

  /// Прикладные колонки строки `projects`.
  Json toFields() => {
    'title': title,
    'color': color,
    'archived': archived,
    'client_id': clientId,
    'status': status?.wire,
    'pay_type': payType?.wire,
    'base_amount': baseAmount,
    'hourly_rate': hourlyRate,
    'start_date': startDate,
    'deadline_date': deadlineDate,
    'completed_date': completedDate,
    'description': description,
    'links': links.isEmpty ? null : [for (final l in links) l.toJson()],
  };

  WorkProject copyWith({
    String? title,
    Object? color = _unset,
    bool? archived,
    Object? clientId = _unset,
    Object? status = _unset,
    Object? payType = _unset,
    Object? baseAmount = _unset,
    Object? hourlyRate = _unset,
    Object? startDate = _unset,
    Object? deadlineDate = _unset,
    Object? completedDate = _unset,
    Object? description = _unset,
    List<ProjectLink>? links,
  }) => WorkProject(
    id: id,
    title: title ?? this.title,
    color: identical(color, _unset) ? this.color : color as String?,
    archived: archived ?? this.archived,
    clientId: identical(clientId, _unset) ? this.clientId : clientId as String?,
    status: identical(status, _unset) ? this.status : status as ProjectStatus?,
    payType: identical(payType, _unset) ? this.payType : payType as PayType?,
    baseAmount: identical(baseAmount, _unset)
        ? this.baseAmount
        : baseAmount as int?,
    hourlyRate: identical(hourlyRate, _unset)
        ? this.hourlyRate
        : hourlyRate as int?,
    startDate: identical(startDate, _unset)
        ? this.startDate
        : startDate as String?,
    deadlineDate: identical(deadlineDate, _unset)
        ? this.deadlineDate
        : deadlineDate as String?,
    completedDate: identical(completedDate, _unset)
        ? this.completedDate
        : completedDate as String?,
    description: identical(description, _unset)
        ? this.description
        : description as String?,
    links: links ?? this.links,
  );
}

/// Человек (`people`, Этапы 2 и 4).
@immutable
class WorkPerson {
  const WorkPerson({
    required this.id,
    required this.name,
    this.archived = false,
    this.role,
    this.contact,
  });

  factory WorkPerson.fromRow(Json row) => WorkPerson(
    id: row['id']! as String,
    name: (row['name'] as String?) ?? '',
    archived: row['archived'] == true,
    role: PersonRole.parse(row['role']),
    contact: row['contact'] as String?,
  );

  final String id;
  final String name;
  final bool archived;
  final PersonRole? role;
  final String? contact;

  bool get isClient => role == PersonRole.client;

  Json toFields() => {
    'name': name,
    'archived': archived,
    'role': role?.wire,
    'contact': contact,
  };

  WorkPerson copyWith({
    String? name,
    bool? archived,
    Object? role = _unset,
    Object? contact = _unset,
  }) => WorkPerson(
    id: id,
    name: name ?? this.name,
    archived: archived ?? this.archived,
    role: identical(role, _unset) ? this.role : role as PersonRole?,
    contact: identical(contact, _unset) ? this.contact : contact as String?,
  );
}

/// Доработка (`change_requests`).
@immutable
class ChangeRequest {
  const ChangeRequest({
    required this.id,
    required this.projectId,
    required this.title,
    required this.amount,
    required this.status,
    this.closedDate,
    this.estimateMinutes,
    this.note,
  });

  factory ChangeRequest.fromRow(Json row) => ChangeRequest(
    id: (row['id'] as String?) ?? '',
    projectId: row['project_id']! as String,
    title: (row['title'] as String?) ?? '',
    amount: (row['amount'] as int?) ?? 0,
    status: ChangeRequestStatus.parse(row['status']),
    closedDate: row['closed_date'] as String?,
    estimateMinutes: row['estimate_minutes'] as int?,
    note: row['note'] as String?,
  );

  final String id;
  final String projectId;
  final String title;
  final int amount;
  final ChangeRequestStatus status;
  final String? closedDate;

  /// Оценка в минутах.
  final int? estimateMinutes;
  final String? note;

  /// Колонки для создания (`project_id` неизменяема и в правку не идёт).
  Json toFields() => {
    'title': title,
    'amount': amount,
    'status': status.wire,
    'closed_date': closedDate,
    'estimate_minutes': estimateMinutes,
    'note': note,
  };

  ChangeRequest copyWith({
    String? title,
    int? amount,
    ChangeRequestStatus? status,
    Object? closedDate = _unset,
    Object? estimateMinutes = _unset,
    Object? note = _unset,
  }) => ChangeRequest(
    id: id,
    projectId: projectId,
    title: title ?? this.title,
    amount: amount ?? this.amount,
    status: status ?? this.status,
    closedDate: identical(closedDate, _unset)
        ? this.closedDate
        : closedDate as String?,
    estimateMinutes: identical(estimateMinutes, _unset)
        ? this.estimateMinutes
        : estimateMinutes as int?,
    note: identical(note, _unset) ? this.note : note as String?,
  );
}

/// Платёж — факт поступления денег (`payments`).
@immutable
class Payment {
  const Payment({
    required this.id,
    required this.paidAt,
    required this.amount,
    this.payerId,
    this.comment,
  });

  factory Payment.fromRow(Json row) => Payment(
    id: (row['id'] as String?) ?? '',
    paidAt: _instant(row['paid_at']) ?? DateTime.utc(2015),
    amount: (row['amount'] as int?) ?? 0,
    payerId: row['payer_id'] as String?,
    comment: row['comment'] as String?,
  );

  final String id;
  final DateTime paidAt;
  final int amount;
  final String? payerId;
  final String? comment;

  Json toFields() => {
    'paid_at': _instantText(paidAt),
    'amount': amount,
    'payer_id': payerId,
    'comment': comment,
  };
}

/// Распределение платежа на проект или доработку (`payment_allocations`).
@immutable
class Allocation {
  const Allocation({
    required this.id,
    required this.paymentId,
    required this.projectId,
    required this.amount,
    this.changeRequestId,
  });

  factory Allocation.fromRow(Json row) => Allocation(
    id: (row['id'] as String?) ?? '',
    paymentId: row['payment_id']! as String,
    projectId: row['project_id']! as String,
    changeRequestId: row['change_request_id'] as String?,
    amount: (row['amount'] as int?) ?? 0,
  );

  final String id;
  final String paymentId;
  final String projectId;

  /// `null` — оплата базовой суммы.
  final String? changeRequestId;
  final int amount;

  Json toFields() => {
    'payment_id': paymentId,
    'project_id': projectId,
    'change_request_id': changeRequestId,
    'amount': amount,
  };
}

/// Запись времени (`time_entries`); `endedAt == null` — таймер идёт.
@immutable
class TimeEntry {
  const TimeEntry({
    required this.id,
    required this.projectId,
    required this.startedAt,
    required this.billable,
    required this.source,
    this.endedAt,
    this.changeRequestId,
    this.taskId,
    this.note,
    this.originDeviceId,
  });

  factory TimeEntry.fromRow(Json row) => TimeEntry(
    id: (row['id'] as String?) ?? '',
    projectId: row['project_id']! as String,
    changeRequestId: row['change_request_id'] as String?,
    taskId: row['task_id'] as String?,
    startedAt: _instant(row['started_at']) ?? DateTime.utc(2015),
    endedAt: _instant(row['ended_at']),
    billable: row['billable'] != false,
    note: row['note'] as String?,
    source: TimeSource.parse(row['source']),
    originDeviceId: row['origin_device_id'] as String?,
  );

  final String id;
  final String projectId;
  final String? changeRequestId;
  final String? taskId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool billable;
  final String? note;
  final TimeSource source;

  /// Устройство, создавшее запись (служебная колонка).
  final String? originDeviceId;

  bool get isRunning => endedAt == null;

  Json toFields() => {
    'project_id': projectId,
    'change_request_id': changeRequestId,
    'task_id': taskId,
    'started_at': _instantText(startedAt),
    'ended_at': _instantText(endedAt),
    'billable': billable,
    'note': note,
    'source': source.wire,
  };

  TimeEntry copyWith({
    String? projectId,
    Object? changeRequestId = _unset,
    Object? taskId = _unset,
    DateTime? startedAt,
    Object? endedAt = _unset,
    bool? billable,
    Object? note = _unset,
  }) => TimeEntry(
    id: id,
    projectId: projectId ?? this.projectId,
    changeRequestId: identical(changeRequestId, _unset)
        ? this.changeRequestId
        : changeRequestId as String?,
    taskId: identical(taskId, _unset) ? this.taskId : taskId as String?,
    startedAt: startedAt ?? this.startedAt,
    endedAt: identical(endedAt, _unset) ? this.endedAt : endedAt as DateTime?,
    billable: billable ?? this.billable,
    note: identical(note, _unset) ? this.note : note as String?,
    source: source,
    originDeviceId: originDeviceId,
  );
}
