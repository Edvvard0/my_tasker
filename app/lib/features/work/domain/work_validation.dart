/// Проверки «Работы» на клиенте (spec Этапа 4, 1.1–1.6 и 3.3). Сервер
/// отвергает то же самое построчно; правила, где участвует больше одной
/// строки (сумма распределений ≤ платежа, доработка своего проекта),
/// проверяет только клиент — при вводе.
library;

import 'dart:convert';

import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

/// Суммы: 0…99 999 999 999 999 копеек.
const int maxWorkKopecks = maxKopecks;

/// Максимум записи времени: короче 14 суток.
const Duration maxEntryLength = Duration(days: 14);

/// Раньше этого момента платежи и время не принимаются (Москва = UTC+3
/// без перехода на летнее время, spec 4.8).
final DateTime workEpoch = DateTime.utc(2015);

const int maxLinks = 20;

/// Предел JSON-колонки `links` на сервере (`json_column(max_bytes=8192)`).
const int maxLinksJsonBytes = 8192;

bool _isRealDate(String? date) => date != null && parseDate(date) != null;

String? _moneyProblem(int? value, String what, {int min = 0}) {
  if (value == null) return null;
  if (value < min || value > maxWorkKopecks) {
    return min > 0
        ? '$what: от 0,01 ₽ до 999 999 999 999,99 ₽'
        : '$what: от 0 до 999 999 999 999,99 ₽';
  }
  return null;
}

/// Размер JSON так, как его считает сервер: компактный JSON Python
/// (`json.dumps` с `ensure_ascii`), где каждый символ вне ASCII занимает
/// 6 байт (`\uXXXX`; символ вне BMP — две такие последовательности).
int _serverJsonBytes(Object? value) {
  var bytes = 0;
  for (final unit in jsonEncode(value).codeUnits) {
    bytes += unit < 0x80 ? 1 : 6;
  }
  return bytes;
}

/// Ссылки проекта: до 20, `http(s)://`, адрес до 500, название до 100.
String? linksProblem(List<ProjectLink> links) {
  if (links.length > maxLinks) return 'Ссылок — не больше $maxLinks';
  for (final l in links) {
    if (l.url.isEmpty || l.url.length > 500) {
      return 'Адрес ссылки — от 1 до 500 символов';
    }
    if (!l.url.startsWith('http://') && !l.url.startsWith('https://')) {
      return 'Адрес ссылки начинается с http:// или https://';
    }
    if ((l.title?.length ?? 0) > 100) {
      return 'Название ссылки — не длиннее 100 символов';
    }
  }
  if (_serverJsonBytes([for (final l in links) l.toJson()]) >
      maxLinksJsonBytes) {
    return 'Ссылки занимают слишком много места — сократите адреса или названия';
  }
  return null;
}

/// Проект целиком.
String? projectProblem(WorkProject p) {
  final title = nameProblem(p.title, 200);
  if (title != null) return title;
  final color = colorProblem(p.color);
  if (color != null) return color;
  final base = _moneyProblem(p.baseAmount, 'Базовая сумма');
  if (base != null) return base;
  final rate = _moneyProblem(p.hourlyRate, 'Ставка');
  if (rate != null) return rate;
  if ((p.description?.length ?? 0) > 10000) return 'Описание слишком длинное';
  final status = p.status;
  if (p.archived && status != null && !status.archivable) {
    return 'В архив уходит только завершённый или отменённый проект';
  }
  if (p.payType == PayType.hourly && p.hourlyRate == null) {
    return 'Для почасового проекта укажите ставку';
  }
  if (status == ProjectStatus.completed && p.completedDate == null) {
    return 'Для завершённого проекта укажите дату завершения';
  }
  for (final (name, value) in [
    ('Дата начала', p.startDate),
    ('Срок', p.deadlineDate),
    ('Дата завершения', p.completedDate),
  ]) {
    if (value != null && !_isRealDate(value)) return '$name: нет такой даты';
  }
  final start = p.startDate;
  if (start != null) {
    if (p.deadlineDate != null && p.deadlineDate!.compareTo(start) < 0) {
      return 'Срок раньше даты начала';
    }
    if (p.completedDate != null && p.completedDate!.compareTo(start) < 0) {
      return 'Дата завершения раньше даты начала';
    }
  }
  return linksProblem(p.links);
}

/// Человек.
String? personProblem(WorkPerson p) {
  final name = nameProblem(p.name, 100, what: 'Имя');
  if (name != null) return name;
  if ((p.contact?.length ?? 0) > 500) return 'Контакт слишком длинный';
  return null;
}

/// Доработка.
String? changeRequestProblem(ChangeRequest c) {
  final title = nameProblem(c.title, 300);
  if (title != null) return title;
  final amount = _moneyProblem(c.amount, 'Сумма');
  if (amount != null) return amount;
  if (c.closedDate != null && !_isRealDate(c.closedDate)) {
    return 'Дата закрытия: нет такой даты';
  }
  if (c.status == ChangeRequestStatus.closed && c.closedDate == null) {
    return 'Для закрытой доработки укажите дату закрытия';
  }
  final minutes = c.estimateMinutes;
  if (minutes != null && (minutes < 0 || minutes > 600000)) {
    return 'Оценка — от 0 до 600 000 минут';
  }
  if ((c.note?.length ?? 0) > 5000) return 'Заметка слишком длинная';
  return null;
}

/// Платёж (без распределений).
String? paymentProblem(Payment p) {
  if (p.paidAt.isBefore(workEpoch)) return 'Платёж раньше 2015 года';
  final amount = _moneyProblem(p.amount, 'Сумма платежа', min: 1);
  if (amount != null) return amount;
  if ((p.comment?.length ?? 0) > 2000) return 'Комментарий слишком длинный';
  return null;
}

/// Распределение платежа (одна строка).
String? allocationProblem(Allocation a) =>
    _moneyProblem(a.amount, 'Сумма распределения', min: 1);

/// Распределения платежа целиком: каждое корректно, сумма не больше суммы
/// платежа (spec 3.3, проверяет клиент), доработка принадлежит проекту.
String? allocationsProblem(
  Payment payment,
  List<Allocation> allocations,
  Iterable<ChangeRequest> changeRequests,
) {
  var sum = 0;
  final owner = {for (final c in changeRequests) c.id: c.projectId};
  for (final a in allocations) {
    final problem = allocationProblem(a);
    if (problem != null) return problem;
    sum += a.amount;
    final link = a.changeRequestId;
    if (link != null && owner.containsKey(link) && owner[link] != a.projectId) {
      return 'Доработка относится к другому проекту';
    }
  }
  if (sum > payment.amount) {
    return 'Распределено больше, чем пришло: '
        'на ${formatAmount(sum - payment.amount)}';
  }
  return null;
}

/// Запись времени.
String? timeEntryProblem(TimeEntry e) {
  if (e.startedAt.isBefore(workEpoch)) return 'Начало раньше 2015 года';
  final end = e.endedAt;
  if (end == null) {
    return e.source == TimeSource.manual ? 'Укажите окончание' : null;
  }
  if (end.isBefore(e.startedAt)) return 'Окончание раньше начала';
  if (end.difference(e.startedAt) >= maxEntryLength) {
    return 'Запись не может длиться 14 суток и больше';
  }
  if ((e.note?.length ?? 0) > 2000) return 'Заметка слишком длинная';
  return null;
}
