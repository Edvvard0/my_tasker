# Общие тестовые векторы

Один набор входов и ожидаемых результатов для Python (`backend/`) и Dart (`app/`). Логика, у которой есть вектор, обязана давать **одинаковый результат на обеих сторонах**; расхождение считается багом той стороны, которая не совпала с файлом.

## Формат

Файл `shared-test-vectors/<домен>/<имя>.json`:

```json
{
  "description": "что проверяет файл",
  "cases": [
    {"name": "уникальное в файле имя случая", "input": "...", "expected": "..."}
  ]
}
```

- `input` и `expected` — любой JSON-тип; их смысл описан для каждого файла ниже.
- Ошибка (входные данные некорректны) кодируется как `"expected": {"error": true}`.
- Кодировка UTF-8. Неразрывные пробелы записаны escape-последовательностями (` `, ` `, ` `), чтобы их было видно в диффах. JSON-парсеры возвращают из них настоящие символы.
- Тест **обязан** загружать все `*.json` домена с диска (не копировать значения в код), проходить **каждый** случай и падать, если файл не найден или в нём нет случаев.
- Новый домен = новая папка. Правило меняется только вместе с файлами векторов и обеими реализациями в одном коммите.

Где лежат тесты: Python — `backend/tests/test_money.py`; Dart — `app/test/` (путь к векторам относительно корня репозитория: `../shared-test-vectors`).

## Домен `money`

Деньги — целые копейки (`int`), валюта RUB. Никаких `float`/`double`/`Decimal` в реализации.

### `parse_amount.json`: `parse_amount(text) -> int` (копейки)

`input` — строка, `expected` — целое число копеек или `{"error": true}`. Алгоритм, шаг за шагом:

1. **Пробельные символы** — ровно четыре: U+0020 SPACE, U+00A0 NO-BREAK SPACE, U+202F NARROW NO-BREAK SPACE, U+2009 THIN SPACE. Другие (табуляция, перевод строки `\n`/`\r`, U+000B, U+000C, U+3000 и т. д.) пробелами не считаются и приводят к ошибке (`12\t`, `12\n` — ошибки). Реализация не должна использовать «умный» `trim()`/`\s`, которые срезают такие символы: только эти четыре.
2. Отрезать пробельные символы с обоих концов строки.
3. Если строка (без учёта регистра, `toLowerCase`) **оканчивается** одним из суффиксов валюты, отрезать **один** суффикс. Проверяются в порядке: `₽` (U+20BD), `руб.`, `руб`, `р.`, `р`; первый совпавший побеждает. Валюта в начале строки не допускается. Сравнение регистронезависимое, поэтому `12 РУБ.` и `12 Р` допустимы (`12 РУБ.` → 1200). Второй суффикс (`12 ₽₽`) остаётся в строке и даёт ошибку на шаге 5.
4. Удалить **все** пробельные символы из оставшейся строки (в том числе между знаком и цифрами, вокруг разделителя и **между цифрами**: `1 2 3` → `123` → 12300, `1 , 5` → `1,5` → 150). Пробел внутри числа сам по себе не считается ошибкой: он трактуется как разделитель групп разрядов без проверки размера групп.
5. Строка целиком должна совпасть с шаблоном `(\+|-|−)?[0-9]+([.,][0-9]{1,2})?`, где знак — `+`, `-` (U+002D) или `−` (U+2212), цифры только ASCII `0`–`9`, разделитель дробной части `.` или `,`. Иначе — ошибка. Следствия: пустая строка, `,5`, `5,`, `1,234` (3 знака после запятой), `1,234.56` (два разделителя), `1e3`, `₽` — ошибки.
6. Целая часть — не более **12 цифр** (с учётом ведущих нулей), иначе ошибка. Максимум — `999999999999,99` = 99 999 999 999 999 копеек.
7. Результат = `целая * 100 + дробная`, где дробная дополняется нулями справа до двух цифр (`,5` → 50). Знак `-`/`−` меняет знак; `-0` даёт `0`.

### `format_amount.json`: `format_amount(kopecks) -> String`

`input` — целое число копеек, `expected` — строка или `{"error": true}`. **Допустимый диапазон: `|kopecks| ≤ 99 999 999 999 999`** (то же, что максимум `parse_amount`). Значение вне диапазона — ошибка (исключение); реализация не должна возвращать строку. В Python дополнительно `TypeError` для не-`int` (`float`, `str`, `None`, `bool`); в Dart аргумент типизирован как `int`, и проверка типа не нужна (в векторы она не входит). Алгоритм для значений из диапазона:

1. Целые рубли = `|kopecks| ~/ 100`, копейки = `|kopecks| % 100`.
2. Рубли записываются десятичными цифрами без ведущих нулей, группы по три цифры справа налево разделяются **U+00A0 NO-BREAK SPACE**.
3. Если копейки не равны нулю — добавляется `,` (запятая) и ровно две цифры копеек (`5` → `,05`, `50` → `,50`). Если равны нулю — дробная часть **не** пишется.
4. Затем U+00A0 и `₽` (U+20BD).
5. У отрицательных чисел впереди ASCII `-` (U+002D), не U+2212. Ноль — без знака: `0 ₽`.

Примеры (`␣` = U+00A0): `123456` → `1␣234,56␣₽`, `100000` → `1␣000␣₽`, `-1` → `-0,01␣₽`.

Для любого допустимого `n` должно выполняться `parse_amount(format_amount(n)) == n`; это проверяют оба набора тестов отдельно от векторов.

## Домен `sync`

Правила синхронизации (спецификация: `docs/specs/stage1_sync_and_auth.md`). Формат файлов отличается от общего: у случая `input.op` (или `input.kind`) выбирает проверяемую функцию. Python: `backend/tests/test_sync_vectors.py`; Dart: `app/test/`.

| Файл | Что проверяет |
|---|---|
| `hlc.json` | `compare` (обычное сравнение строк, `-1/0/1`), `format`, `parse` (ошибка — `{"error": true}`), `send(state, device, now)` и `receive(state, remote, now)` с состоянием `{l, c}` |
| `merge.json` | решение сервера по одному полю (`field`: `noop/touch/apply/apply_conflict/keep_conflict`), по удалению (`delete`) и по правке/восстановлению удалённой строки (`tombstone_edit`); `entry` — `{v, h}` записи поля |
| `outbox.json` | `collapse` — схлопывание новой операции в outbox (`state` по умолчанию `pending`); `rebase` — накладывание неподтверждённых операций на строку из pull |
| `settings_id.json` | `user_settings.id = uuid5(NS, key)` |
| `epoch.json` | что клиент делает с `server_epoch` ответа: `store` / `none` / `full_resync` (`{stored, received}` → действие), спецификация 3.10 |
| `validation.json` | допустимые значения колонок: `datetime` (диапазон 1970..2200 UTC, нормализация в UTC), `text` и `json` (без NUL и непарных суррогатов, глубина ≤ 64), `nested_lists`; спецификация, раздел 0 |

## Домен `calendar`

Календарь и задачи (спецификация: `docs/specs/stage2_calendar_tasks.md`). Формат файлов — как в `sync`: у случая `input` описан для каждого файла отдельно. Исходные входы лежат в `backend/tests/calendar_vectors_gen.py`, ожидаемые значения получены эталонными реализациями (`backend/src/tasker/calendar/reference_*.py`); пересборка — `cd backend && uv run python -m tests.calendar_vectors_gen` (результат нужно просмотреть глазами). Python: `backend/tests/test_calendar_vectors.py`; Dart: `app/test/`.

| Файл | Что проверяет |
|---|---|
| `quick_input.json` | разбор строки быстрого ввода: `input {text, now}` → `{title, priority, project, people, tags, date, time, duration_minutes}` |
| `rrule_expand.json` | развёртка повторений с исключениями и переопределениями (переход на летнее время, конец месяца, `-1FR`, «весь день», чередование недель): `input {all_day, tz, start, end, rrule, title, cancelled, overrides, window}` → список экземпляров |
| `rrule_validate.json` | допустимость правила из подмножества RRULE: `input {rrule, all_day}` → `{valid}` |
| `week_cycle.json` | номер недели цикла (`op: week_number`) и первая подходящая дата (`op: first_date`), в том числе сдвиги чётности |
| `holidays.json` | нерабочий ли день по `shared-data/calendar/holidays_ru.json` |
| `ids.json` | детерминированные id (`uuid5`) календарей, тегов, переопределений, связей и отметок |

## Домен `work`

Работа: проекты, оплаты, часы (спецификация: `docs/specs/stage4_work.md`, раздел 4). Деньги — целые копейки, **без округления**; три деления округляют вниз. Строки — «JSON-строки» таблиц (`id`, `project_id`, `amount`, `status`, `paid_at`, …), моменты `YYYY-MM-DDTHH:MM:SSZ`, даты `YYYY-MM-DD`; необязательные значения — по умолчанию из спецификации (`status = null` ≡ `active`, `base_amount = null` ≡ 0). Московская дата = дата момента + 3 часа. Исходные входы — `backend/tests/work_vectors_gen.py`, ожидаемое — эталон `backend/src/tasker/work/reference.py`; пересборка `cd backend && uv run python -m tests.work_vectors_gen`. Python: `backend/tests/test_work_vectors.py`; Dart: `app/test/`.

| Файл | Что проверяет |
|---|---|
| `scalars.json` | `input.op` выбирает функцию: `paid_bp {received,total}`, `per_hour {amount,seconds}` (`null` при нуле секунд), `hourly_billable {rate,seconds}`, `seconds {entry}` (`null` у идущей записи; доли секунды отбрасываются у каждого момента до вычитания), `moscow_date {at}`, `moscow_month {at}` |
| `project_summary.json` | `input {project, change_requests, allocations}` → `{total, received, remaining (со знаком), overpaid, paid_bp, base_received, base_remaining, change_requests: [{id, amount, received, remaining}]}` |
| `receivables.json` | `input {projects, change_requests, allocations}` → `{total, clients: [{client_id, remaining, projects: [{id, remaining}]}]}`; порядок элементов — часть ожидаемого результата |
| `income.json` | `input {projects, change_requests, payments, allocations, time_entries, period, project_id}` → `{seconds, received, accrued, per_hour_fact, per_hour_accrued, projects: [{id, seconds, received, accrued, per_hour_fact, per_hour_accrued}]}`; порядок проектов — как во входе |
| `monthly.json` | `input {payments, allocations, project_id}` → список `{month, received, unallocated}` |
| `integrity.json` | `input {change_requests, payments, allocations}` → список `{code, id, excess}` |

## Домен `finance`

Финансы: счета, операции, переводы, сверки, долги, цели, аналитика (спецификация: `docs/specs/stage5_finance.md`). Деньги — целые копейки, **без округления**; деление одно (`progress_bp`, вниз). Строки — «JSON-строки» таблиц (`id` — строки; `kind`, `account_id`, `to_account_id`, `amount`, `occurred_at`, `status`, `category_id`, `merchant`, `external_id`, `dedup_hash`, `work_payment_id`, `debt_id`, …), моменты `YYYY-MM-DDTHH:MM:SSZ` (доли секунды отбрасываются), даты `YYYY-MM-DD`; московская дата = дата момента + 3 часа. Исходные входы — `backend/tests/finance_vectors_gen.py`, ожидаемое — эталон `backend/src/tasker/finance/reference.py`; пересборка `cd backend && uv run python -m tests.finance_vectors_gen`. Python: `backend/tests/test_finance_vectors.py`; Dart: `app/test/`.

| Файл | Что проверяет |
|---|---|
| `scalars.json` | `input.op` выбирает функцию: `progress_bp {have,target}`, `opening_instant {date}` и `end_of_day {date}` → момент `…Z`, `month_end {month}` → дата, `moscow_month {at}`, `fold_merchant {text}`, `dedup_key {transaction}` (`null` без ключа), `effect {transaction, account_id}` |
| `balances.json` | `input {accounts, transactions, checkpoints, at}` (`at` — момент или `null`) → `{accounts: [{id, balance, in_total}], total}`; порядок счетов — как во входе |
| `adjustments.json` | `input {account, transactions, checkpoints}` → список `{checkpoint_id, checked_at, actual, expected, adjustment}` |
| `monthly.json` | `input {transactions, account_ids, period}` → список `{month, income, expense, net}` |
| `categories.json` | `input {transactions, categories, kind, period}` → `{total, groups: [{category_id, total, own, count, children: [{category_id, total, count}]}]}`; порядок — часть ожидаемого результата |
| `merchants.json` | `input {transactions, kind, period, limit}` → список `{merchant, total, count}` |
| `dynamics.json` | `input {accounts, transactions, checkpoints, dates}` → список `{date, total}` (баланс на конец московской даты) |
| `debts.json` | `input {debts, repayments, today}` → `{owed_to_me, i_owe, debts: [{id, direction, amount, repaid, remaining, overpaid, status, overdue}]}` |
| `goals.json` | `input {goal, accounts, transactions, checkpoints, debts, repayments, projects, change_requests, allocations}` → `{have, target, missing (со знаком), reached, surplus, progress_bp, terms: [{kind, value}]}`; включает **случай Excel** (`excel_*`: 329 600 / 454 600 / «не хватает −54 600») |
| `work_links.json` | `input {payments, transactions}` → список `{payment_id, amount, linked, unlinked}` |
| `integrity.json` | `input {categories, transactions, debts, repayments, payments}` → список `{code, id, excess}` |
| `category_ids.json` | `input {system_key}` → `uuid5(uuid5(NAMESPACE_URL, "urn:my-tasker:categories"), system_key)` строкой; id предустановленных категорий |

## Домен `banks`

Банки: нормализация мерчанта, хеш дедупликации, сопоставление, переводы между своими счетами, правила уведомлений, автокатегории (спецификация: `docs/specs/stage6_banks.md`). Деньги — целые копейки, моменты `YYYY-MM-DDTHH:MM:SSZ` (доли секунды отбрасываются), строки операций — «JSON-строки» таблиц; в сопоставлении строка выписки без времени помечена `date_only: true`, а её момент — 12:00 по Москве (`09:00:00Z`). Все данные правил лежат в `shared-data/banks/` (`notification_rules.json`, `merchant_normalization.json`, `category_dictionary.json`): Dart читает **те же файлы** (копии в `app/assets/`), в векторы они не встраиваются. Строки сравниваются по кодовым точкам, без `toLowerCase`/`\s`/`\d` (алфавит нормализации — спецификация, раздел 3; пробелы очистки текста — раздел 2.3). Исходные входы — `backend/tests/banks_vectors_gen.py`, ожидаемое — эталон `backend/src/tasker/banks/`; пересборка `cd backend && uv run python -m tests.banks_vectors_gen`. Python: `backend/tests/test_banks_vectors.py`; Dart: `app/test/`.

| Файл | Что проверяет |
|---|---|
| `merchants.json` | `normalize_merchant`: `input {text}` → строка (юридические формы, кавычки, номера терминалов, города, коды стран, идемпотентность, пустые случаи) |
| `similarity.json` | `similarity`: `input {a, b}` (уже нормализованные имена) → целое 0…100 (равные 100, начало по словам 90, иначе Дайс по биграммам вниз, пустое 0) |
| `dedup_hash.json` | `input {account_id, kind, amount, occurred_at, merchant, ordinal}` → `{tail, hash}`; `tail = kind\|amount\|минута UTC\|merchant_norm` (+ `\|ordinal` при `ordinal ≥ 1`), `hash` = первые 32 hex SHA-256 от `account_id\|tail` |
| `matching.json` | `classify_candidates`: `input {account_id, candidates, existing}` → список по кандидатам `{index, action (new/duplicate/merge), existing_id, reason, similarity, dedup_hash, needs_review, review_reason[, refine]}`; совпадение, близкие суммы, две одинаковые покупки, возврат, граница 48 часов, чужая валюта, повторный импорт |
| `transfers.json` | `match_transfers`: `input {transactions, window_seconds}` → список `{expense_id, income_id, delta_seconds}` (окно, один счёт, чужая валюта, «только дата»); порядок — часть результата |
| `notification_parse.json` | `parse_notification`: `input {package, title, text}` → `{status: parsed/ignored/unrecognized, …}` по `shared-data/banks/notification_rules.json` (все образцы правил + крайние случаи) |
| `category_suggest.json` | `suggest_category`: `input {merchant, mcc, kind, user_rules}` → `{source, category_id, system_key}`; правила пользователя, словарь, MCC, вид операции |

Выписки (CSV/XLSX/PDF) разбирает только сервер; Dart-клиент их не разбирает и общих векторов для них нет — образцы лежат в `backend/tests/data/banks/`.

## Домен `study`

Учёба: развёртка расписания на дату, посещаемость, разбор аудитории, генератор сетки звонков, неделя цикла (спецификация: `docs/specs/stage7_study.md`, разделы 3–6). Строки — «JSON-строки» таблиц (`id` — строки; даты `YYYY-MM-DD`, время занятий `HH:MM`, день недели 1…7, понедельник = 1). Расписание **вычисляется** из `semesters, subjects, bells, slots, day_rules, overrides, holidays` (праздники — словарь «дата → название», уже отфильтрованный; в векторах он задан явно). Строки сравниваются по кодовым точкам (порядок занятий — по `start`, `number`, `key`). Исходные входы — `backend/tests/study_vectors_gen.py`, ожидаемое — эталон `backend/src/tasker/study/reference.py`; пересборка `cd backend && uv run python -m tests.study_vectors_gen`. Python: `backend/tests/test_study_vectors.py`; Dart: `app/test/`.

| Файл | Что проверяет |
|---|---|
| `expand.json` | `input {semesters, subjects, bells, slots, day_rules, overrides, holidays, dates}` → список по `dates` — `expand_day`: `{date, weekday, semester_id, cycle_week, day: {kind (no_semester/regular/holiday/special), name, rule_id}, lessons: [{key, source, slot_id, rule_id, scheduled_date, date, number, start, end, title, subject_id, kind, building, room, room_text, cancelled, changed, moved_from, moved_to, override_id, trackable}]}`; четверг-олимпиада, отмена, перенос, изменение, звонки для всех и на дату, чёт/нечёт, цикл 1 и 3 недели, сдвиг чётности, праздник, правило на дату, несколько семестров; **перенос, который не вступает в силу** (пары нет в исходный день: не тот день недели / не та неделя цикла / вне семестра; новая дата вне семестра пары или в другом семестре) — занятие не «призрак», остаётся на своём месте |
| `attendance.json` | `input {through, semesters, subjects, bells, slots, day_rules, overrides, holidays, attendance}` → список по предметам `{subject_id, present, absent, cancelled, unmarked, limit, left, state}`; отменённые и особые дни — не пропуски, границы лимита (`ok/near/reached/over/no_limit`); пересекающиеся семестры — день считается только в семестре-победителе |
| `rooms.json` | `op: parse` `{text}` → `{building, room}` или `null` (пусто, длиннее 20 символов); `op: format` `{building, room}` → строка («к1 28»); «к1 28», «К2 101», «1-28», «корп. 2 каб. 101», голые кабинеты, произвольный текст |
| `bells.json` | `generate_bells {first_start, duration, breaks (число или список), count}` → список `{number, start_time, end_time}` или `{"error": true}` |
| `cycle.json` | `week_number {semester, dates}` → список номеров недели цикла (опора `week1_start`, `cycle_length`, `week_shifts`) |

## Домен `sleep`

Сон и ритуалы: длительность и дата сна, средний сон, связь сна с задачами, серии ритуалов, перенос задач из чек-ина (спецификация: `docs/specs/stage8_sleep_rituals.md`, разделы 3–6). Строки — «JSON-строки» таблиц (`id` — строки; моменты `YYYY-MM-DDTHH:MM:SSZ`, даты `YYYY-MM-DD`, пояса IANA). Всё целочисленное: минуты и средние — вниз, доли — в базисных пунктах вниз; `null` там, где делить не на что. **Нужна база часовых поясов** (Dart: пакет `timezone`); расчёт «настенного» времени и переноса задач с временем при переходе на летнее время обязан совпасть с PEP 495 `fold = 0` (спецификация, 6). Исходные входы — `backend/tests/sleep_vectors_gen.py`, ожидаемое — эталон `backend/src/tasker/sleep/reference.py`; пересборка `cd backend && uv run python -m tests.sleep_vectors_gen`. Python: `backend/tests/test_sleep_vectors.py`; Dart: `app/test/`.

| Файл | Что проверяет |
|---|---|
| `duration.json` | `entry_view`: `input {bed_at, wake_at, bed_tz, wake_tz}` → `{date, minutes, bed_local, wake_local}` или `{"error": true}` (длина ≤ 0 или > 24 ч, битый момент) |
| `averages.json` | `average_sleep`: `input {entries, through, days}` → `{from, to, days, days_with_data, total_minutes, average_minutes}` (пропущенные дни не нули) |
| `link.json` | `sleep_task_link`: `input {entries, tasks, through}` → `{from, to, threshold_minutes, short, normal, difference_bp, days_without_sleep, enough_data}`; группа — `{days, tasks, done, share_bp}`; задача — `{id, status, due_date, due_at, due_tz, rrule}` |
| `streaks.json` | `ritual_streaks`: `input {morning, evening, through}` → `{morning, evening, both}`, каждая — `{current, best, last}` |
| `carry_over.json` | `plan_carry_over`: `input {date, decisions, tasks}` → список по решениям: `{task_id, action: set_due_date/set_due_at/skip, due_date / due_at+due_tz, status, reason}` |

## Домен `monitoring`

Серверы: мониторинг и алерты Telegram (спецификация: `docs/specs/stage9_monitoring.md`, разделы 5, 6, 9). Время в `alerts` и `quiet` — целые Unix-секунды; доступность — базисные пункты вниз. Исходные входы — `backend/tests/monitoring_vectors_gen.py`, ожидаемое — эталон `backend/src/tasker/monitoring/` (`targets.py`, `alerts.py`, `stats.py`); пересборка `cd backend && uv run python -m tests.monitoring_vectors_gen`. Python: `backend/tests/test_monitoring_vectors.py`; Dart обязан пройти `targets.json` и `availability.json` (форма клиента проверяет адреса теми же правилами; доступность считает сервер, но расчёт общий); `alerts.json` и `quiet.json` — серверные правила, Dart их не реализует.

| Файл | Что проверяет |
|---|---|
| `targets.json` | `input.op`: `host {value}` → `{valid, host}` или `{valid: false, reason}` (причины: `empty`, `too_long`, `bad_chars`, `non_global_ip`, `single_label`, `bad_label`, `bad_tld`, `reserved_name`); `url {value}` — те же плюс `scheme`, `userinfo`, `fragment`, `bad_port`, `bad_url`, `no_host`; `addresses {values}` → `{reason}` (`null`, `no_address`, `resolves_to_non_global`) |
| `alerts.json` | `run_cycle` по сценарию: `input {policy, services {id: {critical, checks?}}, cycles [{now, quiet, observations [{service, check, at, ok, reason}], drop?, drop_checks?}]}` → `{cycles [{now, messages}], incidents [{service, n, started_at, ended_at}], final {service: {status, flapping}}}`; сообщение — `{kind, services, refs, …}`; `drop` убирает сервисы перед циклом; `checks` (необязательно) — id живых проверок сервиса, подаётся в `run_cycle` как `services[id].checks`: проверка, которой в списке нет, забывается состоянием сервиса, статус пересчитывается (падение, которое держала только она, закрывается; без `checks` ничего не забывается); `drop_checks` `{service: [check…]}` убирает проверки из `checks` перед циклом. `refs` напоминания — `<сервис>#<n>@<now>` (у одного инцидента много напоминаний), у остальных — как раньше |
| `quiet.json` | `is_quiet`: `input {now, tz, start, end}` → `{quiet}` |
| `availability.json` | `availability_bp`: `input {buckets [{hour, total, ok}], now, hours}` → `{bp}` (`null` без проверок) |
