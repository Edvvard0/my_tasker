# ruff: noqa: E501, N802, N806, PLR0915 - case tables read best one case per line, short helper names
"""Source of the shared calendar vectors: case inputs live here, expected values come from the
reference implementations.

Regenerate after a deliberate rule change (and review the diff by eye!):

    cd backend && uv run python -m tests.calendar_vectors_gen

``tests/test_calendar_vectors.py`` checks that the files on disk equal this output.
"""

import json
import sys
import uuid
from datetime import date, datetime
from pathlib import Path
from typing import Any

from tasker.calendar import ids
from tasker.calendar.holidays import day_info, load
from tasker.calendar.reference_expand import expand
from tasker.calendar.reference_quick_input import parse_quick_input
from tasker.calendar.rrule_subset import rrule_problem
from tasker.calendar.week_cycle import Cycle, cycle_week, first_date, monday_of
from tests.vectors import VECTORS_DIR

Case = dict[str, Any]
NOW = "2026-09-30T14:05"  # a Wednesday


def quick_input() -> list[Case]:
    groups: dict[str, list[tuple[str, ...]]] = {
        "plain": [
            ("Купить хлеб",),
            ("",),
            ("   ",),
            ("Позвонить маме",),
            ("  Купить   хлеб  ",),
            ("Купить\u00a0хлеб\u202fи\u2009молоко",),
            ("Купить\tхлеб",),
        ],
        "priority": [
            ("!1 срочно",),
            ("срочно !2",),
            ("!5",),
            ("!3 !1 дважды",),
            ("!0 задача",),
            ("!6 задача",),
            ("Срочно!1",),
            ("текст ! 1",),
            ("!4 !4",),
        ],
        "meta": [
            ("#работа",),
            ("Отчёт #работа",),
            ("#Мой_проект отчёт",),
            ("#1c обновление",),
            ("#! задача",),
            ("# задача",),
            ("@Рома",),
            ("@Рома @рома @РОМА",),
            ("+тег +Тег +другой",),
            ("+1 задача",),
            ("@ задача",),
            ("почта a@b.ru",),
            ("#работа #дом",),
            ("#работа, отчёт",),
            ("+тег. конец",),
            ("позвонить @Рома, потом @Елена; +звонок",),
            ("+#тег",),
        ],
        "day_words": [
            ("сегодня",),
            ("завтра",),
            ("послезавтра",),
            ("завтра, позвонить",),
            ("в пятницу",),
            ("во вторник",),
            ("среду",),
            ("ср",),
            ("в среду",),
            ("следующую пятницу",),
            ("следующий понедельник",),
            ("в следующую среду",),
            ("в понедельник",),
            ("вс",),
            ("пн вт",),
            ("на выходных",),
            ("в выходные",),
            ("на выходные",),
            ("на выходные", "2026-10-03T10:00"),
            ("в выходные", "2026-10-04T23:30"),
            ("в понедельник", "2026-09-28T00:00"),
            ("следующий понедельник", "2026-09-28T00:00"),
            ("в воскресенье", "2026-10-04T08:00"),
            ("следующее воскресенье", "2026-10-04T08:00"),
        ],
        "explicit": [
            ("15.10",),
            ("15.10.2026",),
            ("15.10.27",),
            ("2026-10-15",),
            ("1.1",),
            ("30.09",),
            ("29.09",),
            ("31.02",),
            ("29.02",),
            ("29.02", "2027-09-30T10:00"),
            ("15 октября",),
            ("5 янв",),
            ("15 октября 2027",),
            ("31 июня",),
            ("1 сентября",),
            ("до 15 октября сдать отчёт",),
            ("к 20 октября",),
            ("с 5 октября",),
            ("10.30 дата",),
            ("15.10.2020",),
            ("2026-13-01",),
            ("9 мая", "2028-05-10T12:00"),
            ("3 сен 2026 г",),
            ("30 сентября",),
            ("0 января",),
        ],
        "relative": [
            ("через 3 дня",),
            ("через 1 день",),
            ("через день",),
            ("через неделю",),
            ("через 2 недели",),
            ("через 5 недель",),
            ("через месяц",),
            ("через 3 месяца",),
            ("через месяц", "2026-01-31T09:00"),
            ("через 366 дней",),
            ("через 0 дней",),
            ("через 3 дня", "2026-12-30T09:00"),
            ("через 1 месяц", "2026-12-31T23:00"),
            ("через 12 месяцев",),
            ("через 2 месяца", "2028-01-31T10:00"),
        ],
        "clock": [
            ("15:00",),
            ("9:05",),
            ("24:00",),
            ("12:60",),
            ("14:05",),
            ("13:00",),
            ("14:06",),
            ("в 15:00",),
            ("завтра 15:00",),
            ("завтра в 15:00",),
            ("в 15:00 завтра",),
            ("утром",),
            ("завтра утром",),
            ("вечером",),
            ("днем",),
            ("днём",),
            ("сегодня вечером",),
            ("сегодня утром",),
            ("в 9 утра",),
            ("в 3 часа дня",),
            ("в 8 вечера",),
            ("в 12 дня",),
            ("в 12 утра",),
            ("в 15 часов",),
            ("в 1 час",),
            ("к 5 вечера",),
            ("9 утра",),
            ("в 13 утра",),
            ("в 15",),
            ("в 15 позвонить",),
            ("завтра в 15 позвонить",),
            ("в 24",),
            ("в 0",),
            ("позвонить в 9",),
            ("в 7 часов вечера",),
            ("00:00",),
            ("23:59",),
            ("в 24 часа",),
        ],
        "duration": [
            ("с 10:00 до 12:00",),
            ("10:00-12:00",),
            ("10:00–12:30",),
            ("10:00—11:00",),
            ("с 10:00 до 09:00",),
            ("10:00-10:00",),
            ("на 30 минут",),
            ("на 2 часа",),
            ("на час",),
            ("на полчаса",),
            ("на полтора часа",),
            ("на 90 мин",),
            ("на 25 часов",),
            ("на 1 ч",),
            ("на 0 минут",),
            ("завтра с 14:00 до 15:30 встреча",),
            ("встреча завтра 14:00 на 1 час",),
            ("на 2 часа и 30 минут",),
            ("на 15 минут завтра в 9 утра",),
        ],
        "combo": [
            ("завтра 15:00 позвонить Роме !1 #работа @Рома +звонок",),
            ("Сдать отчёт по проекту до 15 октября в 18:00 !2 #работа",),
            ("завтра послезавтра",),
            ("в 10:00 в 11:00",),
            ("через 2 часа завтра",),
            ("через 30 минут",),
            ("через час",),
            ("через полчаса",),
            ("через 2 часа выпить чай",),
            ("через 45 минут", "2026-09-30T23:30"),
            ("в пятницу в 18:30",),
            ("пт 18:30 бар",),
            ("25 декабря в 20:00",),
            ("31 декабря 23:59",),
            ("встреча с Ромой в среду в 11",),
            ("созвон завтра в 11 на полчаса",),
            ("завтра в 15 !1",),
            ("в 15 #дом", "2026-09-30T16:00"),
            ("сдать 15.10 в 12:00",),
            ("!1 !2 #a #b @x +t завтра",),
            ("завтра, 15:00, позвонить",),
            ("ЗАВТРА В 15:00 ЗВОНОК",),
            ("Завтра Утром",),
            ("В ПЯТНИЦУ",),
            ("четверг 09:00 планерка",),
            ("в четверг",),
            ("день рождения 5 декабря",),
            ("купить 3 хлеба",),
            ("Встреча ср",),
            ("1.5 кг сахара",),
            ("в 5 магазинов",),
            ("в 5 магазинов завтра",),
            ("ёлка 30 декабря", "2026-12-30T09:00"),
            ("завтра", "2026-12-31T23:59"),
            ("15:00", "2026-12-31T16:00"),
            ("сегодня", "2026-12-30T09:00"),
            ("на выходных в 11 утра",),
            ("на следующей неделе",),
            ("напомнить в 20:00 про таблетки",),
            ("в 20:00 с 21:00 до 22:00",),
        ],
    }
    cases: list[Case] = []
    for group, items in groups.items():
        for i, item in enumerate(items, 1):
            text, now = item[0], (item[1] if len(item) > 1 else NOW)
            expected = parse_quick_input(text, datetime.fromisoformat(now)).as_json()
            cases.append(
                {
                    "name": f"{group}_{i:02d}",
                    "input": {"text": text, "now": now},
                    "expected": expected,
                }
            )
    return cases


def rrule_expand() -> list[Case]:
    cases: list[Case] = []

    def add(
        name: str,
        all_day: bool,
        tz: str | None,
        start: str,
        end: str,
        rrule: str | None,
        win: tuple[str, str],
        cancelled: list[str] | None = None,
        overrides: list[Case] | None = None,
        title: str = "Событие",
    ) -> None:
        inp: Case = {
            "all_day": all_day,
            "tz": None if all_day else tz,
            "start": start,
            "end": end,
            "rrule": rrule,
            "title": title,
            "cancelled": cancelled or [],
            "overrides": overrides or [],
            "window": {"from": win[0], "to": win[1]},
        }
        cases.append({"name": name, "input": inp, "expected": expand(inp)})

    def T(
        name: str, tz: str, start: str, end: str, rrule: str | None, win: tuple[str, str], **kw: Any
    ) -> None:
        add(name, False, tz, start, end, rrule, win, **kw)

    def D(
        name: str, start: str, end: str, rrule: str | None, win: tuple[str, str], **kw: Any
    ) -> None:
        add(name, True, None, start, end, rrule, win, **kw)

    Z = "T00:00:00Z"
    B, M, NY = "Europe/Berlin", "Europe/Moscow", "America/New_York"
    # --- single events and window edges
    T(
        "single_in_window",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        None,
        ("2026-10-05" + Z, "2026-10-06" + Z),
    )
    T(
        "single_outside_window",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        None,
        ("2026-10-06" + Z, "2026-10-07" + Z),
    )
    T(
        "single_ends_at_window_start",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        None,
        ("2026-10-05T08:00:00Z", "2026-10-06" + Z),
    )
    T(
        "single_starts_at_window_end",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        None,
        ("2026-10-04" + Z, "2026-10-05T07:00:00Z"),
    )
    T(
        "single_overlaps_window_start",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T09:00:00Z",
        None,
        ("2026-10-05T08:00:00Z", "2026-10-06" + Z),
    )
    T(
        "zero_length_at_window_start",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T07:00:00Z",
        None,
        ("2026-10-05T07:00:00Z", "2026-10-06" + Z),
    )
    T(
        "zero_length_at_window_end",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T07:00:00Z",
        None,
        ("2026-10-04" + Z, "2026-10-05T07:00:00Z"),
    )
    # --- daily and DST (Europe/Berlin)
    T(
        "daily_count_across_spring_forward",
        B,
        "2026-03-26T08:30:00Z",
        "2026-03-26T09:30:00Z",
        "FREQ=DAILY;COUNT=6",
        ("2026-03-25" + Z, "2026-04-05" + Z),
    )
    T(
        "daily_0230_missing_wall_time_moves_forward",
        B,
        "2026-03-28T01:30:00Z",
        "2026-03-28T02:30:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-03-27" + Z, "2026-04-01" + Z),
    )
    T(
        "daily_0230_ambiguous_wall_time_first_offset",
        B,
        "2026-10-24T00:30:00Z",
        "2026-10-24T01:30:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-23" + Z, "2026-10-28" + Z),
    )
    T(
        "daily_0930_across_fall_back",
        B,
        "2026-10-23T07:30:00Z",
        "2026-10-23T08:00:00Z",
        "FREQ=DAILY;COUNT=5",
        ("2026-10-22" + Z, "2026-11-01" + Z),
    )
    T(
        "daily_interval_3_until_inclusive",
        M,
        "2026-10-01T07:00:00Z",
        "2026-10-01T08:00:00Z",
        "FREQ=DAILY;INTERVAL=3;UNTIL=20261010T070000Z",
        ("2026-09-30" + Z, "2026-11-01" + Z),
    )
    T(
        "daily_until_one_second_early_excludes_last",
        M,
        "2026-10-01T07:00:00Z",
        "2026-10-01T08:00:00Z",
        "FREQ=DAILY;INTERVAL=3;UNTIL=20261010T065959Z",
        ("2026-09-30" + Z, "2026-11-01" + Z),
    )
    T(
        "daily_unbounded_window_far_from_start",
        M,
        "2020-01-01T07:00:00Z",
        "2020-01-01T08:00:00Z",
        "FREQ=DAILY",
        ("2026-10-05" + Z, "2026-10-08" + Z),
    )
    T(
        "daily_count_cancelled_instances_still_count",
        M,
        "2026-10-01T07:00:00Z",
        "2026-10-01T08:00:00Z",
        "FREQ=DAILY;COUNT=5",
        ("2026-09-30" + Z, "2026-11-01" + Z),
        cancelled=["2026-10-02T07:00:00Z", "2026-10-04T07:00:00Z"],
    )
    T(
        "daily_window_inside_series_only",
        M,
        "2026-10-01T07:00:00Z",
        "2026-10-01T08:00:00Z",
        "FREQ=DAILY;COUNT=30",
        ("2026-10-10" + Z, "2026-10-13" + Z),
    )
    T(
        "daily_crossing_midnight_utc_duration",
        M,
        "2026-10-01T20:00:00Z",
        "2026-10-02T02:00:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-02" + Z, "2026-10-03" + Z),
    )
    T(
        "daily_new_york_spring_forward",
        NY,
        "2026-03-07T14:00:00Z",
        "2026-03-07T15:00:00Z",
        "FREQ=DAILY;COUNT=4",
        ("2026-03-06" + Z, "2026-03-12" + Z),
    )
    # --- weekly
    T(
        "weekly_mo_we_fr_count",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        "FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=7",
        ("2026-10-01" + Z, "2026-11-01" + Z),
    )
    T(
        "weekly_default_weekday_from_start",
        M,
        "2026-10-07T07:00:00Z",
        "2026-10-07T08:00:00Z",
        "FREQ=WEEKLY;COUNT=4",
        ("2026-10-01" + Z, "2026-11-30" + Z),
    )
    T(
        "weekly_byday_earlier_than_start_weekday_skips_first_week",
        M,
        "2026-10-07T07:00:00Z",
        "2026-10-07T08:00:00Z",
        "FREQ=WEEKLY;BYDAY=MO,FR;COUNT=4",
        ("2026-10-01" + Z, "2026-11-30" + Z),
    )
    T(
        "weekly_sunday_start_week_is_monday_based",
        M,
        "2026-10-04T07:00:00Z",
        "2026-10-04T08:00:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;COUNT=5",
        ("2026-10-01" + Z, "2026-12-01" + Z),
    )
    T(
        "weekly_across_year_boundary",
        M,
        "2026-12-28T07:00:00Z",
        "2026-12-28T08:00:00Z",
        "FREQ=WEEKLY;BYDAY=MO,TH;COUNT=6",
        ("2026-12-25" + Z, "2027-02-01" + Z),
    )
    T(
        "weekly_new_york_fall_back",
        NY,
        "2026-10-28T22:00:00Z",
        "2026-10-28T23:00:00Z",
        "FREQ=WEEKLY;COUNT=3",
        ("2026-10-27" + Z, "2026-11-20" + Z),
    )
    T(
        "weekly_berlin_spring_forward",
        B,
        "2026-03-24T17:00:00Z",
        "2026-03-24T18:00:00Z",
        "FREQ=WEEKLY;COUNT=3",
        ("2026-03-20" + Z, "2026-04-20" + Z),
    )
    # --- alternating weeks (even/odd): WEEKLY;INTERVAL=2 anchored by the first occurrence
    T(
        "alt_odd_weeks_tuesday",
        M,
        "2026-09-01T07:40:00Z",
        "2026-09-01T09:10:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU",
        ("2026-08-31" + Z, "2026-10-20" + Z),
    )
    T(
        "alt_even_weeks_tuesday",
        M,
        "2026-09-08T07:40:00Z",
        "2026-09-08T09:10:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU",
        ("2026-08-31" + Z, "2026-10-20" + Z),
    )
    T(
        "alt_odd_weeks_monday_thursday",
        M,
        "2026-08-31T09:00:00Z",
        "2026-08-31T10:30:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH",
        ("2026-08-31" + Z, "2026-10-05" + Z),
    )
    T(
        "alt_three_week_cycle_second_week",
        M,
        "2026-09-08T09:00:00Z",
        "2026-09-08T10:30:00Z",
        "FREQ=WEEKLY;INTERVAL=3;BYDAY=TU",
        ("2026-08-31" + Z, "2026-11-15" + Z),
    )
    T(
        "alt_odd_weeks_skip_holiday_week_by_cancelling",
        M,
        "2026-09-01T07:40:00Z",
        "2026-09-01T09:10:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU",
        ("2026-08-31" + Z, "2026-11-01" + Z),
        cancelled=["2026-09-29T07:40:00Z"],
    )
    T(
        "alt_odd_weeks_until_semester_end",
        M,
        "2026-09-01T07:40:00Z",
        "2026-09-01T09:10:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;UNTIL=20261013T074000Z",
        ("2026-08-31" + Z, "2027-01-01" + Z),
    )
    T(
        "alt_odd_weeks_moved_instance",
        M,
        "2026-09-01T07:40:00Z",
        "2026-09-01T09:10:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU",
        ("2026-09-14" + Z, "2026-09-20" + Z),
        overrides=[
            {
                "original_start": "2026-09-15T07:40:00Z",
                "start": "2026-09-17T11:00:00Z",
                "end": "2026-09-17T12:30:00Z",
                "title": "Перенесено",
            }
        ],
    )
    T(
        "alt_split_series_old_part_ends_new_part_shifts_parity",
        M,
        "2026-09-01T07:40:00Z",
        "2026-09-01T09:10:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;UNTIL=20260915T074000Z",
        ("2026-08-31" + Z, "2026-11-01" + Z),
    )
    T(
        "alt_shifted_parity_new_series",
        M,
        "2026-09-22T07:40:00Z",
        "2026-09-22T09:10:00Z",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU",
        ("2026-08-31" + Z, "2026-11-01" + Z),
    )
    D(
        "alt_all_day_every_other_monday",
        "2026-08-31",
        "2026-08-31",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO",
        ("2026-08-31", "2026-10-15"),
    )
    # --- monthly
    T(
        "monthly_bymonthday_31_skips_short_months",
        M,
        "2026-01-31T07:00:00Z",
        "2026-01-31T08:00:00Z",
        "FREQ=MONTHLY;BYMONTHDAY=31",
        ("2026-01-01" + Z, "2027-01-01" + Z),
    )
    T(
        "monthly_bymonthday_minus_1_last_day",
        M,
        "2026-01-31T07:00:00Z",
        "2026-01-31T08:00:00Z",
        "FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=6",
        ("2026-01-01" + Z, "2027-01-01" + Z),
    )
    T(
        "monthly_default_day_30_skips_february",
        M,
        "2026-01-30T07:00:00Z",
        "2026-01-30T08:00:00Z",
        "FREQ=MONTHLY;COUNT=4",
        ("2026-01-01" + Z, "2027-01-01" + Z),
    )
    T(
        "monthly_last_friday",
        M,
        "2026-01-30T07:00:00Z",
        "2026-01-30T08:00:00Z",
        "FREQ=MONTHLY;BYDAY=-1FR;COUNT=6",
        ("2026-01-01" + Z, "2027-01-01" + Z),
    )
    T(
        "monthly_second_tuesday",
        M,
        "2026-01-13T07:00:00Z",
        "2026-01-13T08:00:00Z",
        "FREQ=MONTHLY;BYDAY=2TU;COUNT=4",
        ("2026-01-01" + Z, "2027-01-01" + Z),
    )
    T(
        "monthly_first_and_third_monday",
        M,
        "2026-01-05T07:00:00Z",
        "2026-01-05T08:00:00Z",
        "FREQ=MONTHLY;BYDAY=1MO,3MO;COUNT=5",
        ("2026-01-01" + Z, "2027-01-01" + Z),
    )
    T(
        "monthly_fifth_friday_skips_months_without_one",
        M,
        "2026-01-30T07:00:00Z",
        "2026-01-30T08:00:00Z",
        "FREQ=MONTHLY;BYDAY=5FR",
        ("2026-01-01" + Z, "2027-01-01" + Z),
    )
    T(
        "monthly_1st_and_15th",
        M,
        "2026-10-01T07:00:00Z",
        "2026-10-01T08:00:00Z",
        "FREQ=MONTHLY;BYMONTHDAY=1,15;COUNT=5",
        ("2026-09-01" + Z, "2027-01-01" + Z),
    )
    T(
        "monthly_every_third_month",
        M,
        "2026-01-15T07:00:00Z",
        "2026-01-15T08:00:00Z",
        "FREQ=MONTHLY;INTERVAL=3;COUNT=5",
        ("2026-01-01" + Z, "2028-01-01" + Z),
    )
    T(
        "monthly_plain_byday_every_friday_of_month",
        M,
        "2026-10-02T07:00:00Z",
        "2026-10-02T08:00:00Z",
        "FREQ=MONTHLY;BYDAY=FR;COUNT=6",
        ("2026-10-01" + Z, "2026-12-01" + Z),
    )
    T(
        "monthly_berlin_day_28_across_dst",
        B,
        "2026-02-28T08:00:00Z",
        "2026-02-28T09:00:00Z",
        "FREQ=MONTHLY;BYMONTHDAY=28;COUNT=5",
        ("2026-02-01" + Z, "2026-08-01" + Z),
    )
    T(
        "monthly_last_friday_berlin_across_dst",
        B,
        "2026-03-27T08:00:00Z",
        "2026-03-27T09:00:00Z",
        "FREQ=MONTHLY;BYDAY=-1FR;COUNT=3",
        ("2026-03-01" + Z, "2026-07-01" + Z),
    )
    # --- yearly
    T(
        "yearly_leap_day_only_in_leap_years",
        M,
        "2028-02-29T07:00:00Z",
        "2028-02-29T08:00:00Z",
        "FREQ=YEARLY",
        ("2028-01-01" + Z, "2037-01-01" + Z),
    )
    T(
        "yearly_count",
        M,
        "2026-05-09T07:00:00Z",
        "2026-05-09T08:00:00Z",
        "FREQ=YEARLY;COUNT=3",
        ("2026-01-01" + Z, "2030-01-01" + Z),
    )
    T(
        "yearly_interval_2_berlin",
        B,
        "2026-06-01T08:00:00Z",
        "2026-06-01T09:00:00Z",
        "FREQ=YEARLY;INTERVAL=2;COUNT=3",
        ("2026-01-01" + Z, "2032-01-01" + Z),
    )
    # --- overrides
    T(
        "override_moves_instance_and_renames",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        "FREQ=DAILY;COUNT=4",
        ("2026-10-04" + Z, "2026-10-10" + Z),
        overrides=[
            {
                "original_start": "2026-10-06T07:00:00Z",
                "start": "2026-10-06T12:00:00Z",
                "end": "2026-10-06T13:30:00Z",
                "title": "Перенос",
            }
        ],
    )
    T(
        "override_only_title_keeps_time",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-04" + Z, "2026-10-10" + Z),
        overrides=[{"original_start": "2026-10-06T07:00:00Z", "title": "Другое название"}],
    )
    T(
        "override_moved_into_window_from_outside",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-20" + Z, "2026-10-22" + Z),
        overrides=[
            {
                "original_start": "2026-10-06T07:00:00Z",
                "start": "2026-10-21T07:00:00Z",
                "end": "2026-10-21T08:00:00Z",
            }
        ],
    )
    T(
        "override_moved_out_of_window",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-05" + Z, "2026-10-08" + Z),
        overrides=[
            {
                "original_start": "2026-10-06T07:00:00Z",
                "start": "2026-10-21T07:00:00Z",
                "end": "2026-10-21T08:00:00Z",
            }
        ],
    )
    T(
        "override_for_a_non_occurrence_is_ignored",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-01" + Z, "2026-10-20" + Z),
        overrides=[{"original_start": "2026-10-06T09:00:00Z", "title": "Призрак"}],
    )
    T(
        "cancelled_wins_over_override_for_the_same_instance",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-01" + Z, "2026-10-20" + Z),
        cancelled=["2026-10-06T07:00:00Z"],
        overrides=[{"original_start": "2026-10-06T07:00:00Z", "title": "Не покажется"}],
    )
    T(
        "override_on_single_event",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        None,
        ("2026-10-01" + Z, "2026-10-20" + Z),
        overrides=[
            {
                "original_start": "2026-10-05T07:00:00Z",
                "start": "2026-10-06T07:00:00Z",
                "end": "2026-10-06T08:00:00Z",
            }
        ],
    )
    T(
        "cancelled_single_event",
        M,
        "2026-10-05T07:00:00Z",
        "2026-10-05T08:00:00Z",
        None,
        ("2026-10-01" + Z, "2026-10-20" + Z),
        cancelled=["2026-10-05T07:00:00Z"],
    )
    T(
        "override_key_of_dst_shifted_instance",
        B,
        "2026-03-28T01:30:00Z",
        "2026-03-28T02:30:00Z",
        "FREQ=DAILY;COUNT=3",
        ("2026-03-27" + Z, "2026-04-01" + Z),
        cancelled=["2026-03-29T01:30:00Z"],
    )
    T(
        "multi_day_timed_instances_overlap_window_start",
        M,
        "2026-10-05T18:00:00Z",
        "2026-10-07T06:00:00Z",
        "FREQ=WEEKLY;COUNT=3",
        ("2026-10-06" + Z, "2026-10-07" + Z),
    )
    # --- all-day
    D(
        "allday_daily_count",
        "2026-10-05",
        "2026-10-05",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-01", "2026-11-01"),
    )
    D(
        "allday_multi_day_weekly_overlaps_window_start",
        "2026-10-02",
        "2026-10-04",
        "FREQ=WEEKLY;COUNT=3",
        ("2026-10-11", "2026-10-13"),
    )
    D(
        "allday_window_end_exclusive",
        "2026-10-05",
        "2026-10-05",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-04", "2026-10-06"),
    )
    D(
        "allday_monthly_31",
        "2026-01-31",
        "2026-01-31",
        "FREQ=MONTHLY;BYMONTHDAY=31",
        ("2026-01-01", "2026-09-01"),
    )
    D(
        "allday_until_inclusive",
        "2026-10-05",
        "2026-10-05",
        "FREQ=DAILY;UNTIL=20261007",
        ("2026-10-01", "2026-11-01"),
    )
    D(
        "allday_yearly_birthday_cancelled_one",
        "2026-12-05",
        "2026-12-05",
        "FREQ=YEARLY;COUNT=4",
        ("2026-01-01", "2031-01-01"),
        cancelled=["2027-12-05"],
    )
    D(
        "allday_override_moves_date",
        "2026-10-05",
        "2026-10-05",
        "FREQ=DAILY;COUNT=3",
        ("2026-10-01", "2026-10-20"),
        overrides=[
            {
                "original_start": "2026-10-06",
                "start": "2026-10-09",
                "end": "2026-10-10",
                "title": "Два дня",
            }
        ],
    )
    D(
        "allday_last_friday_of_month",
        "2026-01-30",
        "2026-01-30",
        "FREQ=MONTHLY;BYDAY=-1FR;COUNT=3",
        ("2026-01-01", "2026-12-31"),
    )
    D("allday_single_multi_day", "2026-12-30", "2027-01-02", None, ("2027-01-01", "2027-01-05"))
    D(
        "allday_leap_day_yearly",
        "2028-02-29",
        "2028-02-29",
        "FREQ=YEARLY",
        ("2028-01-01", "2037-01-01"),
    )

    return cases


def rrule_validate() -> list[Case]:
    R = [
        ("FREQ=DAILY", False),
        ("FREQ=DAILY;INTERVAL=2", False),
        ("FREQ=WEEKLY;BYDAY=MO,WE,FR", False),
        ("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU", False),
        ("FREQ=MONTHLY;BYMONTHDAY=31", False),
        ("FREQ=MONTHLY;BYMONTHDAY=-1", False),
        ("FREQ=MONTHLY;BYDAY=-1FR", False),
        ("FREQ=MONTHLY;BYDAY=2TU,4TU", False),
        ("FREQ=MONTHLY;BYDAY=FR", False),
        ("FREQ=YEARLY", False),
        ("FREQ=YEARLY;COUNT=3", False),
        ("FREQ=DAILY;COUNT=1000", False),
        ("FREQ=DAILY;UNTIL=20261231T210000Z", False),
        ("FREQ=DAILY;UNTIL=20261231", True),
        ("FREQ=WEEKLY;BYDAY=MO;UNTIL=20270101", True),
        ("FREQ=DAILY;INTERVAL=999", False),
        ("FREQ=MONTHLY;BYMONTHDAY=1,15", False),
        ("", False),
        ("RRULE:FREQ=DAILY", False),
        ("freq=daily", False),
        ("FREQ=HOURLY", False),
        ("FREQ=SECONDLY", False),
        ("INTERVAL=2", False),
        ("FREQ=DAILY;FREQ=WEEKLY", False),
        ("FREQ=DAILY;INTERVAL=0", False),
        ("FREQ=DAILY;INTERVAL=1000", False),
        ("FREQ=DAILY;INTERVAL=02", False),
        ("FREQ=DAILY;INTERVAL=-1", False),
        ("FREQ=DAILY;COUNT=0", False),
        ("FREQ=DAILY;COUNT=1001", False),
        ("FREQ=DAILY;COUNT=5;UNTIL=20261231T210000Z", False),
        ("FREQ=DAILY;UNTIL=20261231", False),
        ("FREQ=DAILY;UNTIL=20261231T210000Z", True),
        ("FREQ=DAILY;UNTIL=20261301T000000Z", False),
        ("FREQ=DAILY;UNTIL=20261232", True),
        ("FREQ=DAILY;UNTIL=2026-12-31", True),
        ("FREQ=DAILY;BYDAY=MO", False),
        ("FREQ=YEARLY;BYDAY=MO", False),
        ("FREQ=WEEKLY;BYDAY=1MO", False),
        ("FREQ=WEEKLY;BYDAY=MO,MO", False),
        ("FREQ=WEEKLY;BYDAY=XX", False),
        ("FREQ=MONTHLY;BYDAY=6MO", False),
        ("FREQ=MONTHLY;BYDAY=0MO", False),
        ("FREQ=MONTHLY;BYDAY=+1MO", False),
        ("FREQ=MONTHLY;BYDAY=MO;BYMONTHDAY=1", False),
        ("FREQ=WEEKLY;BYMONTHDAY=1", False),
        ("FREQ=MONTHLY;BYMONTHDAY=0", False),
        ("FREQ=MONTHLY;BYMONTHDAY=32", False),
        ("FREQ=MONTHLY;BYMONTHDAY=-32", False),
        ("FREQ=MONTHLY;BYMONTHDAY=1,1", False),
        ("FREQ=MONTHLY;BYSETPOS=-1;BYDAY=MO,TU", False),
        ("FREQ=WEEKLY;WKST=SU", False),
        ("FREQ=YEARLY;BYMONTH=5", False),
        ("FREQ=DAILY;BYHOUR=9", False),
        ("FREQ=DAILY;;COUNT=2", False),
        ("FREQ=DAILY;", False),
        (" FREQ=DAILY", False),
        ("FREQ=DAILY;COUNT=", False),
        ("FREQ=DAILY;COUNT=2\n", False),
        ("FREQ=" + "DAILY" + ";X=" + "1" * 200, False),
    ]
    return [
        {
            "name": f"rrule_{i:02d}",
            "input": {"rrule": text, "all_day": all_day},
            "expected": {"valid": rrule_problem(text, all_day=all_day) is None},
        }
        for i, (text, all_day) in enumerate(R, 1)
    ]


def week_cycle() -> list[Case]:
    W: list[Case] = []

    def wk(week1: str, length: int, day: str) -> None:
        W.append({"op": "week_number", "week1_start": week1, "length": length, "date": day})

    for d in [
        "2026-08-31",
        "2026-09-01",
        "2026-09-06",
        "2026-09-07",
        "2026-09-13",
        "2026-09-14",
        "2026-09-30",
        "2026-10-04",
        "2026-10-05",
        "2026-12-31",
        "2027-01-01",
        "2027-01-03",
        "2027-01-04",
    ]:
        wk("2026-08-31", 2, d)
    for d in ["2026-08-30", "2026-08-24", "2026-08-23", "2026-08-17", "2026-06-01", "2025-12-31"]:
        wk("2026-08-31", 2, d)  # before the anchor
    for d in ["2026-09-01", "2026-09-07", "2026-09-14", "2026-09-21", "2026-09-28", "2026-10-05"]:
        wk("2026-09-01", 3, d)  # anchor is a Tuesday: normalised to Monday 2026-08-31
        wk("2026-09-01", 1, d)
    for d in ["2026-08-30", "2026-08-10", "2026-07-20"]:
        wk("2026-09-01", 3, d)
    wk("2028-02-28", 4, "2028-03-27")
    wk("2028-02-28", 4, "2028-03-26")

    def fd(after: str, weekday: int, week: int, week1: str, length: int) -> None:
        W.append(
            {
                "op": "first_date",
                "after": after,
                "weekday": weekday,
                "week": week,
                "week1_start": week1,
                "length": length,
            }
        )

    fd("2026-09-01", 1, 1, "2026-08-31", 2)
    fd("2026-09-01", 1, 2, "2026-08-31", 2)
    fd("2026-09-02", 1, 1, "2026-08-31", 2)
    fd("2026-09-01", 0, 2, "2026-08-31", 2)
    fd("2026-09-07", 0, 1, "2026-08-31", 2)
    fd("2026-09-06", 6, 1, "2026-08-31", 2)
    fd("2026-09-06", 6, 2, "2026-08-31", 2)
    fd("2026-09-01", 4, 3, "2026-08-31", 3)
    fd("2026-09-01", 4, 2, "2026-08-31", 3)
    fd("2026-09-01", 1, 1, "2026-08-31", 1)
    fd("2026-08-01", 2, 2, "2026-08-31", 2)
    fd("2026-12-30", 3, 1, "2026-08-31", 2)
    one_shift = [{"from": "2026-11-02", "weeks": 1}]
    two_shifts = [*one_shift, {"from": "2027-01-11", "weeks": 1}]
    base = {"op": "week_number", "week1_start": "2026-08-31", "length": 2}
    for iso_day in [
        "2026-10-26",
        "2026-11-01",
        "2026-11-02",
        "2026-11-08",
        "2026-11-09",
        "2026-11-16",
    ]:
        W.append({**base, "date": iso_day, "shifts": one_shift})
    for iso_day in ["2027-01-04", "2027-01-10", "2027-01-11", "2027-01-18"]:
        W.append({**base, "date": iso_day, "shifts": two_shifts})
    W.append({**base, "date": "2026-11-05", "shifts": [{"from": "2026-11-04", "weeks": 1}]})
    W.append({**base, "date": "2026-11-02", "shifts": [{"from": "2026-11-02", "weeks": -1}]})
    W.append(
        {**base, "date": "2026-11-02", "length": 3, "shifts": [{"from": "2026-11-02", "weeks": 2}]}
    )
    first = {"op": "first_date", "week1_start": "2026-08-31", "length": 2, "shifts": one_shift}
    W.append({**first, "after": "2026-11-02", "weekday": 1, "week": 1})
    W.append({**first, "after": "2026-11-02", "weekday": 1, "week": 2})
    out: list[Case] = []
    for i, c in enumerate(W, 1):
        cycle = Cycle(
            date.fromisoformat(c["week1_start"]),
            c["length"],
            tuple((date.fromisoformat(s["from"]), s["weeks"]) for s in c.get("shifts", [])),
        )
        if c["op"] == "week_number":
            day = date.fromisoformat(c["date"])
            expected: Any = {
                "monday": monday_of(day).isoformat(),
                "week_number": cycle_week(day, cycle.week1_start, cycle.length, cycle.shifts),
            }
        else:
            expected = first_date(
                date.fromisoformat(c["after"]), c["weekday"], c["week"], cycle
            ).isoformat()
        out.append({"name": f"{c['op']}_{i:02d}", "input": c, "expected": expected})
    return out


def holidays() -> list[Case]:
    data = load()
    ds = [
        "2026-01-01",
        "2026-01-02",
        "2026-01-07",
        "2026-01-08",
        "2026-01-09",
        "2026-01-10",
        "2026-01-11",
        "2026-01-12",
        "2026-02-22",
        "2026-02-23",
        "2026-03-07",
        "2026-03-08",
        "2026-03-09",
        "2026-05-01",
        "2026-05-09",
        "2026-05-11",
        "2026-06-12",
        "2026-06-13",
        "2026-11-03",
        "2026-11-04",
        "2026-11-05",
        "2026-12-30",
        "2026-12-31",
        "2026-09-30",
        "2026-10-03",
        "2026-10-04",
        "2025-12-31",
        "2025-01-01",
        "2028-01-01",
        "2027-01-01",
        "2027-01-02",
        "2027-01-03",
        "2027-01-04",
        "2027-01-08",
        "2027-01-09",
        "2027-01-11",
        "2027-01-12",
        "2027-01-13",
        "2027-02-23",
        "2027-03-08",
        "2027-05-01",
        "2027-05-03",
        "2027-05-10",
        "2027-06-12",
        "2027-06-14",
        "2027-11-04",
        "2027-12-31",
    ]
    return [
        {
            "name": f"day_{i:02d}",
            "input": s,
            "expected": {
                "is_day_off": (info := day_info(data, date.fromisoformat(s))).is_day_off,
                "name": info.name,
            },
        }
        for i, s in enumerate(ds, 1)
    ]


def ids_cases() -> list[Case]:
    found: list[Case] = []

    def idc(kind: str, inp: Case, exp: uuid.UUID) -> None:
        found.append(
            {
                "name": f"{kind}_{len(found) + 1:02d}",
                "input": {"kind": kind, **inp},
                "expected": str(exp),
            }
        )

    for key in ("personal", "work", "study", "tasks", "holidays_ru"):
        idc("system_calendar", {"system_key": key}, ids.system_calendar_id(key))
    for name in ("работа", "Работа", "РАБОТА", "дом", "urgent", "Urgent", "a-b_c", "тег123"):
        idc("tag", {"name": name}, ids.tag_id(name))
    EV = "0195f2a0-7b1c-7a3e-8f10-0123456789ab"
    EV2 = "0195f2a0-7b1c-7a3e-8f10-0123456789ac"
    for ev, orig in (
        (EV, "2026-10-05T07:00:00Z"),
        (EV, "2026-10-06T07:00:00Z"),
        (EV2, "2026-10-05T07:00:00Z"),
        (EV, "2026-10-05"),
        (EV, "2027-02-28"),
    ):
        idc("event_override", {"event_id": ev, "original_start": orig}, ids.override_id(ev, orig))
    for t, d in ((EV, "2026-10-05"), (EV, "2026-10-06"), (EV2, "2026-10-05")):
        idc("task_completion", {"task_id": t, "instance_date": d}, ids.completion_id(t, d))
    tg = str(ids.tag_id("работа"))
    for t, g in ((EV, tg), (EV2, tg), (EV, str(ids.tag_id("дом")))):
        idc("task_tag", {"task_id": t, "tag_id": g}, ids.task_tag_id(t, g))
    return found


FILES: dict[str, tuple[str, Any]] = {
    "quick_input": (
        "Быстрый ввод (docs/specs/stage2_calendar_tasks.md, раздел 8). input: text (строка) и now (локальное время устройства, YYYY-MM-DDTHH:MM); expected: результат разбора.",
        quick_input,
    ),
    "rrule_expand": (
        "Развёртка повторений (docs/specs/stage2_calendar_tasks.md, раздел 5.3). input: событие (all_day, tz, start/end: UTC-момент YYYY-MM-DDTHH:MM:SSZ или дата, rrule, title, cancelled — original_start отменённых экземпляров (EXDATE), overrides — переопределения экземпляров) и window {from, to} (полуоткрытый интервал); expected: экземпляры, пересекающие окно, по возрастанию start.",
        rrule_expand,
    ),
    "rrule_validate": (
        "Допустимость RRULE (docs/specs/stage2_calendar_tasks.md, раздел 5.1). input: rrule (строка) и all_day (у событий на весь день UNTIL — дата YYYYMMDD, у остальных — момент YYYYMMDDTHHMMSSZ); expected: {valid: bool}.",
        rrule_validate,
    ),
    "week_cycle": (
        "Чередование недель (docs/specs/stage2_calendar_tasks.md, раздел 6). op=week_number: номер недели цикла (с 1) и понедельник её недели; op=first_date: ближайшая дата >= after с днём недели weekday (0=пн) в неделе цикла week. Необязательный shifts — сдвиги чётности [{from, weeks}].",
        week_cycle,
    ),
    "holidays": (
        "Праздники РФ (docs/specs/stage2_calendar_tasks.md, раздел 7; данные — shared-data/calendar/holidays_ru.json). input: дата; expected: нерабочий ли день и название из файла (null, если даты в файле нет).",
        holidays,
    ),
    "ids": (
        "Детерминированные id (docs/specs/stage2_calendar_tasks.md, раздел 2.2): uuid5(uuid5(NAMESPACE_URL, 'urn:my-tasker:<таблица>'), имя). input.kind выбирает правило; expected — id.",
        ids_cases,
    ),
}


def _escape_spaces(text: str) -> str:
    """Exotic spaces are written as escapes so that they are visible in diffs."""
    for char in ("\u00a0", "\u202f", "\u2009"):
        text = text.replace(char, f"\\u{ord(char):04x}")
    return text


def render(description: str, cases: list[Case]) -> str:
    lines = [_escape_spaces(json.dumps(case, ensure_ascii=False)) for case in cases]
    body = ",\n".join("    " + line for line in lines)
    return f'{{\n  "description": {json.dumps(description, ensure_ascii=False)},\n  "cases": [\n{body}\n  ]\n}}\n'


def generate() -> dict[str, str]:
    result: dict[str, str] = {}
    for name, (description, build) in FILES.items():
        cases = build()
        names = [case["name"] for case in cases]
        assert len(names) == len(set(names)), name
        result[name] = render(description, cases)
    return result


def main() -> None:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else VECTORS_DIR / "calendar"
    for name, text in generate().items():
        (target / f"{name}.json").write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
