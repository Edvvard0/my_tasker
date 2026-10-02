import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/recurrence/expansion.dart';
import 'package:my_tasker/core/recurrence/rrule.dart';
import 'package:my_tasker/core/recurrence/rule_dates.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/outbox_logic.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';

/// Что изменить в одном экземпляре повторяющегося события (spec 5.4,
/// «Только это»). `null` в поле — «как в событии».
class InstanceChange {
  const InstanceChange({
    this.title,
    this.description,
    this.location,
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDate,
    this.reminders,
  });

  final String? title;
  final String? description;
  final String? location;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<int>? reminders;
}

/// Слои календаря, события и переопределения экземпляров: локальные
/// записи через [SyncStore] (строка + HLC + outbox в одной транзакции).
class CalendarRepository {
  CalendarRepository(this._store, {String Function()? newId})
    : _newId = newId ?? uuid7;

  final SyncStore _store;
  final String Function() _newId;

  static const String calendarsTable = 'calendars';
  static const String eventsTable = 'events';
  static const String overridesTable = 'event_overrides';

  // ---- слои ----------------------------------------------------------------

  /// Создаёт системные календари, которых ещё нет (детерминированные id,
  /// spec 3.1). Повторный вызов и вызов с другого устройства безопасны.
  Future<void> ensureSystemCalendars() async {
    var position = 0;
    for (final entry in systemCalendarNames.entries) {
      final id = systemCalendarId(entry.key);
      final index = position++;
      await _store.transaction(() async {
        final row = await _store.getRow(calendarsTable, id);
        if (row == null) {
          await _store.create(calendarsTable, id, {
            'name': entry.value,
            'color': null,
            'kind': 'system',
            'system_key': entry.key,
            'visible': true,
            'position': index,
          });
        } else if (row['deleted_at'] != null) {
          await _store.restore(calendarsTable, id);
        }
      });
    }
  }

  Future<CalendarLayer?> getLayer(String id) async {
    final row = await _store.getRow(calendarsTable, id);
    return row == null ? null : CalendarLayer.fromRow(row);
  }

  Future<List<CalendarLayer>> layers() async => [
    for (final r in await _store.visibleRows(
      calendarsTable,
      orderBy: 't.position, t.id',
    ))
      CalendarLayer.fromRow(r),
  ];

  /// Новый пользовательский слой в конце списка.
  Future<String> createLayer({required String name, String? color}) async {
    ensureValid(nameProblem(name, 100));
    ensureValid(colorProblem(color));
    final id = _newId();
    await _store.transaction(() async {
      final all = await layers();
      final position = all.isEmpty
          ? 0
          : (all.map((l) => l.position).reduce((a, b) => a > b ? a : b) + 1);
      await _store.create(calendarsTable, id, {
        'name': name.trim(),
        'color': color,
        'kind': 'user',
        'system_key': null,
        'visible': true,
        'position': position,
      });
    });
    return id;
  }

  Future<void> updateLayer(
    String id, {
    String? name,
    Object? color = _keep,
    bool? visible,
    int? position,
  }) async {
    final fields = <String, Object?>{};
    if (name != null) {
      ensureValid(nameProblem(name, 100));
      fields['name'] = name.trim();
    }
    if (!identical(color, _keep)) {
      ensureValid(colorProblem(color as String?));
      fields['color'] = color;
    }
    if (visible != null) fields['visible'] = visible;
    if (position != null) fields['position'] = position;
    if (fields.isEmpty) return;
    await _store.update(calendarsTable, id, fields);
  }

  /// Переставляет слои в порядке [orderedIds] (позиции 0, 1, 2…).
  Future<void> reorderLayers(List<String> orderedIds) =>
      _store.transaction(() async {
        for (var i = 0; i < orderedIds.length; i++) {
          final layer = await getLayer(orderedIds[i]);
          if (layer != null && layer.position != i) {
            await _store.update(calendarsTable, layer.id, {'position': i});
          }
        }
      });

  /// Число живых событий слоя (для предупреждения перед удалением).
  Future<int> eventCount(String calendarId) async => (await _store.visibleRows(
    eventsTable,
    where: 't.calendar_id = ?',
    args: [calendarId],
  )).length;

  /// Переносит все события слоя [from] в слой [to].
  Future<void> moveEvents(String from, String to) =>
      _store.transaction(() async {
        final rows = await _store.visibleRows(
          eventsTable,
          where: 't.calendar_id = ?',
          args: [from],
        );
        for (final r in rows) {
          await _store.update(eventsTable, r['id']! as String, {
            'calendar_id': to,
          });
        }
      });

  /// Удаляет пользовательский слой (события уходят в корзину каскадом на
  /// сервере). Системные слои удалять нельзя (spec 3.1).
  Future<void> deleteLayer(String id) async {
    final layer = await getLayer(id);
    if (layer == null) return;
    if (layer.isSystem) {
      throw const ValidationError('Системный слой нельзя удалить');
    }
    await _store.softDelete(calendarsTable, id);
  }

  // ---- события -------------------------------------------------------------

  Future<EventEntity?> getEvent(String id) async {
    final row = await _store.getRow(eventsTable, id);
    return row == null ? null : EventEntity.fromRow(row);
  }

  Future<List<EventOverride>> overridesOf(String eventId) async => [
    for (final r in await _store.visibleRows(
      overridesTable,
      where: 't.event_id = ?',
      args: [eventId],
      orderBy: 't.original_start',
    ))
      EventOverride.fromRow(r),
  ];

  /// Создаёт событие; `event.id` задаёт вызывающий (или `newEventId`).
  Future<String> createEvent(EventEntity event) async {
    ensureValid(eventProblem(event));
    await _store.create(eventsTable, event.id, _trimmed(event).toFields());
    return event.id;
  }

  /// Новый идентификатор события (UUIDv7).
  String newEventId() => _newId();

  EventEntity _trimmed(EventEntity e) => e.copyWith(title: e.title.trim());

  /// Правка события целиком — «Все в серии» (spec 5.4). Группы связанных
  /// полей уходят в операции целиком (spec 0); переопределения, чей
  /// `original_start` перестал быть экземпляром, удаляются.
  Future<void> updateEvent(EventEntity next) async {
    ensureValid(eventProblem(next));
    lastDroppedOverrides = 0;
    await _store.transaction(() async {
      final current = await getEvent(next.id);
      if (current == null) throw StateError('События ${next.id} нет');
      final before = current.toFields();
      final after = _trimmed(next).toFields();
      final fields = <String, Object?>{};
      for (final e in after.entries) {
        if (_differs(before[e.key], e.value)) fields[e.key] = e.value;
      }
      final timeChanged = eventTimeColumns.any(fields.containsKey);
      final ruleChanged = fields.containsKey('rrule');
      if (timeChanged || ruleChanged) {
        // Правило — вместе с началом серии; время — группой целиком.
        for (final k in eventTimeColumns) {
          fields[k] = after[k];
        }
        fields['rrule'] = after['rrule'];
      }
      if (fields.isEmpty) return;
      await _store.update(eventsTable, next.id, fields);
      if (timeChanged || ruleChanged) {
        lastDroppedOverrides = await _dropDanglingOverrides(current, next);
      }
    });
  }

  /// Сколько переопределений (отмены и правки экземпляров) не удалось
  /// сохранить при последнем [updateEvent]/[splitFollowing]: их ключ перестал
  /// быть экземпляром, и перенести по дате нельзя. Интерфейс предупреждает.
  int lastDroppedOverrides = 0;

  /// Ключ экземпляра [key] серии [old] в серии [next], если у серии сменилось
  /// только время суток/пояс: тот же локальный день, новое время начала.
  /// `null` — перенос по дате невозможен.
  String? _remapKey(EventEntity old, EventEntity next, String key) {
    if (old.allDay || next.allDay || old.startAt == null) return null;
    final instant = parseInstant(key);
    if (instant == null || next.startAt == null) return null;
    final date = dateOnly(utcToWall(requireLocation(old.tz!), instant));
    final newZone = requireLocation(next.tz!);
    final wall = utcToWall(newZone, next.startAt!);
    return formatInstant(
      wallToUtc(
        newZone,
        date.year,
        date.month,
        date.day,
        wall.hour,
        wall.minute,
        wall.second,
      ),
    );
  }

  /// Создаёт (или восстанавливает) переопределение [o] у события
  /// [toEventId] на экземпляр [key] (детерминированный id).
  Future<void> _moveOverride(
    EventOverride o,
    String toEventId,
    String key,
  ) async {
    final id = eventOverrideId(toEventId, key);
    final row = await _store.getRow(overridesTable, id);
    if (row == null) {
      await _store.create(overridesTable, id, {
        'event_id': toEventId,
        'original_start': key,
        ...o.toFields(),
      });
    } else {
      await _store.update(overridesTable, id, o.toFields());
      if (row['deleted_at'] != null) await _store.restore(overridesTable, id);
    }
  }

  /// Удаляет «висячие» переопределения; если у серии сменилось время суток,
  /// переопределение переезжает на тот же день с новым временем. Возвращает
  /// число потерянных.
  Future<int> _dropDanglingOverrides(EventEntity old, EventEntity event) async {
    final series = event.series;
    final overrides = await overridesOf(event.id);
    var dropped = 0;
    for (final o in overrides) {
      if (series != null && _isInstance(series, o.originalStart)) continue;
      final key = series == null
          ? null
          : _remapKey(old, event, o.originalStart);
      if (key != null && key != o.originalStart && _isInstance(series!, key)) {
        await _moveOverride(o, event.id, key);
      } else {
        dropped++;
      }
      await _store.softDelete(overridesTable, o.id);
    }
    return dropped;
  }

  bool _differs(Object? a, Object? b) {
    if (a is List && b is List) {
      return a.length != b.length || a.toString() != b.toString();
    }
    return a != b;
  }

  /// Ключ [key] — настоящий экземпляр серии.
  bool _isInstance(SeriesDefinition series, String key) {
    final date = series.dateOfKey(key);
    if (date == null) return false;
    for (final o in series.originals(hint: addDays(date, -1))) {
      final c = o.key.compareTo(key);
      if (c == 0) return true;
      if (c > 0) return false;
    }
    return false;
  }

  /// Удаляет событие целиком (в корзину, 30 дней).
  Future<void> deleteEvent(String id) => _store.softDelete(eventsTable, id);

  Future<void> restoreEvent(String id) => _store.restore(eventsTable, id);

  // ---- экземпляры (только это) -----------------------------------------------

  /// Создаёт или обновляет переопределение экземпляра [key] (spec 5.4,
  /// «Только это»); возвращённое из корзины восстанавливается.
  Future<void> overrideInstance(
    EventEntity event,
    String key,
    InstanceChange change,
  ) async {
    ensureValid(
      overrideProblem(
        originalStart: key,
        title: change.title,
        reminders: change.reminders,
        startAt: change.startAt,
        endAt: change.endAt,
        startDate: change.startDate,
        endDate: change.endDate,
      ),
    );
    final id = eventOverrideId(event.id, key);
    final fields = <String, Object?>{
      'cancelled': false,
      'title': change.title?.trim(),
      'description': change.description,
      'location': change.location,
      'start_at': storedInstant(change.startAt),
      'end_at': storedInstant(change.endAt),
      'start_date': storedDate(change.startDate),
      'end_date': storedDate(change.endDate),
      'reminders': change.reminders,
    };
    await _upsertOverride(event.id, key, id, fields);
  }

  /// «Удалить только это»: `cancelled = true` (это и есть `EXDATE`).
  Future<void> cancelInstance(EventEntity event, String key) =>
      _upsertOverride(event.id, key, eventOverrideId(event.id, key), {
        'cancelled': true,
        'title': null,
        'description': null,
        'location': null,
        'start_at': null,
        'end_at': null,
        'start_date': null,
        'end_date': null,
        'reminders': null,
      });

  /// «Вернуть»: удаляет строку переопределения.
  Future<void> restoreInstance(EventEntity event, String key) async {
    final id = eventOverrideId(event.id, key);
    final row = await _store.getRow(overridesTable, id);
    if (row != null && row['deleted_at'] == null) {
      await _store.softDelete(overridesTable, id);
    }
  }

  Future<void> _upsertOverride(
    String eventId,
    String key,
    String id,
    Json fields,
  ) => _store.transaction(() async {
    final row = await _store.getRow(overridesTable, id);
    if (row == null) {
      await _store.create(overridesTable, id, {
        'event_id': eventId,
        'original_start': key,
        ...fields,
      });
      return;
    }
    final changed = <String, Object?>{
      for (final e in fields.entries)
        if (_differs(row[e.key], e.value)) e.key: e.value,
    };
    if (changed.isNotEmpty) await _store.update(overridesTable, id, changed);
    if (row['deleted_at'] != null) await _store.restore(overridesTable, id);
  });

  // ---- «это и следующие» -------------------------------------------------------

  /// Число экземпляров серии раньше ключа [key].
  int instancesBefore(SeriesDefinition series, String key) {
    var n = 0;
    for (final o in series.originals()) {
      if (o.key.compareTo(key) >= 0) break;
      n++;
    }
    return n;
  }

  /// Правило серии [event], обрезанное перед экземпляром [key]: `UNTIL` —
  /// на секунду раньше (для «весь день» — накануне), `COUNT` убран.
  String _truncatedRule(EventEntity event, String key) {
    final rule = RRule.parse(event.rrule!, allDay: event.allDay);
    final cut = rule.copyWith(
      count: () => null,
      untilUtc: () => event.allDay
          ? null
          : parseInstant(key)!.subtract(const Duration(seconds: 1)),
      untilDate: () => event.allDay ? addDays(parseDate(key)!, -1) : null,
    );
    return cut.toRuleString();
  }

  /// «Это и следующие» (spec 5.4): разрез серии перед экземпляром [key].
  /// [edited] — содержимое нового хвоста серии (начало = изменённый
  /// экземпляр [key], правило — как задал пользователь). Одна транзакция.
  /// Возвращает id события с хвостом (или самого события, если [key] —
  /// первый экземпляр: тогда это правка «Все»).
  Future<String> splitFollowing(
    EventEntity old,
    String key,
    EventEntity edited,
  ) async {
    final series = old.series;
    if (series == null || old.rrule == null) {
      throw const ValidationError('Событие не повторяется');
    }
    final before = instancesBefore(series, key);
    if (before == 0) {
      await updateEvent(edited.copyWith(calendarId: edited.calendarId));
      return old.id;
    }
    lastDroppedOverrides = 0;
    final oldRule = RRule.parse(old.rrule!, allDay: old.allDay);
    var tailRule = edited.rrule;
    if (tailRule != null && oldRule.count != null) {
      final parsed = RRule.parse(tailRule, allDay: edited.allDay);
      if (parsed.count == oldRule.count) {
        final remaining = oldRule.count! - before;
        tailRule = parsed.copyWith(count: () => remaining).toRuleString();
      }
    }
    final tail = EventEntity(
      id: _newId(),
      calendarId: edited.calendarId,
      title: edited.title,
      description: edited.description,
      location: edited.location,
      allDay: edited.allDay,
      startAt: edited.startAt,
      endAt: edited.endAt,
      tz: edited.tz,
      startDate: edited.startDate,
      endDate: edited.endDate,
      rrule: tailRule,
      reminders: edited.reminders,
      source: edited.source,
    );
    ensureValid(eventProblem(tail));
    _ensureStartMatchesRule(tail);
    await _store.transaction(() async {
      final overrides = await overridesOf(old.id);
      await _store.update(eventsTable, old.id, {
        'rrule': _truncatedRule(old, key),
        ...old.timeFields(),
      });
      await _store.create(eventsTable, tail.id, _trimmed(tail).toFields());
      final tailSeries = tail.series;
      for (final o in overrides) {
        if (o.originalStart.compareTo(key) < 0) continue;
        await _store.softDelete(overridesTable, o.id);
        if (tailSeries == null) {
          lastDroppedOverrides++;
          continue;
        }
        var target = o.originalStart;
        if (!_isInstance(tailSeries, target)) {
          // Время суток хвоста изменилось: тот же день, новое время.
          final remapped = _remapKey(old, tail, target);
          if (remapped == null || !_isInstance(tailSeries, remapped)) {
            lastDroppedOverrides++;
            continue;
          }
          target = remapped;
        }
        await _moveOverride(o, tail.id, target);
      }
    });
    return tail.id;
  }

  /// Начало серии обязано подходить под её правило (spec 3.2): иначе первый
  /// экземпляр хвоста уехал бы на другую дату.
  void _ensureStartMatchesRule(EventEntity e) {
    final text = e.rrule;
    if (text == null) return;
    final start = e.allDay
        ? e.startDate!
        : dateOnly(utcToWall(requireLocation(e.tz!), e.startAt!));
    final rule = RRule.parse(text, allDay: e.allDay);
    final first = ruleDates(
      rule.copyWith(count: () => null),
      start,
    ).firstOrNull;
    if (first != start) {
      throw const ValidationError(
        'Начало серии не подходит под правило повторения',
      );
    }
  }

  /// «Удалить это и следующие»: серия заканчивается перед [key].
  Future<void> deleteFollowing(EventEntity event, String key) async {
    final series = event.series;
    if (series == null ||
        event.rrule == null ||
        instancesBefore(series, key) == 0) {
      await deleteEvent(event.id);
      return;
    }
    await _store.transaction(() async {
      final overrides = await overridesOf(event.id);
      await _store.update(eventsTable, event.id, {
        'rrule': _truncatedRule(event, key),
        ...event.timeFields(),
      });
      for (final o in overrides) {
        if (o.originalStart.compareTo(key) >= 0) {
          await _store.softDelete(overridesTable, o.id);
        }
      }
    });
  }
}

const Object _keep = Object();

final calendarRepositoryProvider = Provider<CalendarRepository>(
  (ref) => CalendarRepository(ref.watch(syncStoreProvider)),
);
