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
