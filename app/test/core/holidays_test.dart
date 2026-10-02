import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/holidays/holiday_calendar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('встроенная копия байт-в-байт равна shared-data', () {
    final canonical = File('../shared-data/calendar/holidays_ru.json');
    final copy = File(holidaysAssetPath);
    expect(copy.readAsBytesSync(), canonical.readAsBytesSync());
  });

  test('разбор: годы, статус, типы дней', () {
    final c = HolidayCalendar.fromJsonString(
      File(holidaysAssetPath).readAsStringSync(),
    );
    expect(c.hasYear(2026), isTrue);
    expect(c.hasYear(1999), isFalse);
    expect(c.year(2026)!.isProvisional, isFalse);
    expect(c.year(2027)!.isProvisional, isTrue);
    expect(c.year(1999), isNull);
    expect(c.updated, isNotNull);
    final ny = c.dayInfo(DateTime.utc(2026));
    expect(ny.isDayOff, isTrue);
    expect(ny.isNamed, isTrue);
    expect(ny.type, HolidayType.holiday);
    final moved = c.dayInfo(DateTime.utc(2026, 1, 9));
    expect(moved.type, HolidayType.transferOff);
    expect(moved.isDayOff, isTrue);
    expect(c.holidayName(DateTime.utc(2026, 1, 9)), contains('Перенос'));
  });

  test('день без записи: выходной только в субботу и воскресенье', () {
    final c = HolidayCalendar.empty();
    expect(c.dayInfo(DateTime.utc(2026, 10, 3)).isDayOff, isTrue); // сб
    expect(c.dayInfo(DateTime.utc(2026, 10, 5)).isDayOff, isFalse); // пн
    expect(c.holidayName(DateTime.utc(2026, 10, 3)), isNull);
    expect(c.dayInfo(DateTime.utc(2026, 10, 3)).isNamed, isFalse);
  });

  test('рабочая суббота и неизвестный тип', () {
    final c = HolidayCalendar.fromJsonString('''
{"updated":"2026-01-01","years":{"2026":{"status":"official","days":[
 {"date":"2026-02-28","type":"working_weekend","name":"Рабочая суббота"},
 {"date":"2026-03-01","type":"weird","name":"x"}]}}}''');
    final work = c.dayInfo(DateTime.utc(2026, 2, 28));
    expect(work.isDayOff, isFalse);
    expect(work.type, HolidayType.workingWeekend);
    // запись неизвестного типа пропускается: воскресенье как обычно
    final unknown = c.dayInfo(DateTime.utc(2026, 3));
    expect(unknown.isDayOff, isTrue);
    expect(unknown.name, isNull);
  });
}
