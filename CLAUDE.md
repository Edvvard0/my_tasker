# My Tasker — правила проекта

Личная система трекинга жизни: Android + Windows (Flutter) и бэкенд на VPS (FastAPI + PostgreSQL). Один пользователь, offline-first.

## Главные документы

- `docs/04_DECISIONS_AND_ROADMAP.md` — **источник истины**: решения, этапы, стандарт тестов. При расхождении с 01/02/03 действует 04.
- `docs/01_ARCHITECTURE_PLAN.md` — архитектура, модель данных, синхронизация.
- `docs/02_DESIGN_SYSTEM.md` — дизайн-система и экраны.
- `docs/00_BRIEF.md` — исходные требования.

## Роли (обязательно)

- **Весь код пишут субагенты на модели Sonnet**: код приложения, бэкенда, тесты, CI, исправления по ревью.
- **Главный агент — только оркестратор**: ставит задачи субагентам с полным контекстом, принимает архитектурные решения, проверяет результат (читает диф, сам запускает тесты и линтеры), назначает отдельного субагента-ревьюера и возвращает работу на доработку. Код сам не пишет.
- Субагент не считается закончившим, пока не показал зелёные тесты и линтеры командой из раздела «Команды».

## Процесс

- Работа идёт по этапам из `04`. Этап = модуль. Следующий этап не начинается, пока текущий не соответствует Definition of Done (раздел 2.4 в `04`) и не прошёл ревью.
- **Экономия контекста:** субагент читает выжимку этапа `docs/briefs/stage-N.md` и контракт `docs/specs/`, а большие документы 01/02 — только по ссылкам из выжимки. Читать только нужные файлы кода.
- **Одно общее ревью на этап** (бэкенд + клиент), один исправитель. Не больше двух параллельных потоков разработки.
- **Тяжёлые тесты по риску:** property-based и golden — только где ошибка дорогая (деньги, синхронизация, календарь, парсеры, безопасность, ключевые экраны).
- Субагенты не трогают индекс git (никаких `git add/rm/mv/commit`) — коммитит оркестратор, перечисляя файлы явно.
- Сейчас идёт **фаза кода**: деплой и сборка APK/MSIX — позже, в фазе сборки.
- Каждый закрытый этап отмечается в журнале этапов (раздел 5 в `04`).
- Язык общения с пользователем, документации и UI — русский. Идентификаторы в коде и сообщения коммитов — английский.

## Секреты

- Никогда не записывать в репозиторий токены, ключи, пароли, chat id, IP-адреса и логины серверов пользователя.
- Секреты — только через переменные окружения (`POLZA_API_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `S3_*`, `DATABASE_URL`, …). В репозитории допускается только `*.env.example` без значений.
- Ключ polza.ai существует только на сервере; клиент его никогда не получает.

## Ключевые технические правила

- Деньги — целые числа в копейках + код валюты. Никаких float для денег.
- Время — UTC + IANA-таймзона; «весь день» — дата без времени; повторения — RRULE.
- Идентификаторы — UUIDv7, генерирует клиент.
- Каждая синхронизируемая таблица имеет служебные поля: `id`, `created_at`, `updated_at` (HLC), `deleted_at`, `server_version`, `origin_device_id`.
- Удаление — мягкое; корзина 30 дней.
- Конфликты синхронизации — только автоматически (слияние по полям + LWW + журнал).

## Структура репозитория

- `app/` — Flutter-клиент (фича-модули в `lib/features/<модуль>/`).
- `backend/` — FastAPI api и worker.
- `deploy/` — docker compose, Caddy, примеры env.
- `shared-test-vectors/` — общие тестовые векторы для Python и Dart.
- `docs/` — документация.

## Команды

### Бэкенд (из `backend/`)

```bash
uv sync --locked
uv run ruff check && uv run ruff format --check && uv run mypy
uv run pytest            # покрытие >= 90 % проверяется автоматически; PostgreSQL 17 поднимается в Docker сам
# Docker Hub отдаёт 429: export TEST_POSTGRES_IMAGE=mirror.gcr.io/library/postgres:17-alpine
# свой сервер БД: DATABASE_URL=postgresql://user:pw@host:5432/postgres uv run pytest
uv run python -m tasker.db_migrations                                  # миграции
uv run uvicorn tasker.main:create_app --factory --no-access-log         # api
uv run python -m tasker.worker                                          # worker
```

### Локальный стек (из `deploy/`)

```bash
cp .env.example .env     # заполнить; .env никогда не коммитить
docker compose config -q && docker compose up -d --build
curl -k https://127.0.0.1/health/ready
```

### Клиент (из `app/`)

```bash
export PATH=/opt/flutter/bin:$PATH          # Flutter 3.47.5
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # Drift *.g.dart, в git не хранится
dart format --output=none --set-exit-if-changed $(git ls-files 'lib/**.dart' 'test/**.dart' 'tool/**.dart')
flutter analyze                                            # 0 замечаний
flutter test --coverage && dart tool/check_coverage.dart --min=90
flutter test --update-goldens test/goldens                 # эталоны: только Linux, смотреть PNG глазами
```

### Windows (локальная разработка)

- Flutter 3.47.5 нужен отдельной копией (стандартный `C:\flutter` старее): `git clone --depth 1 -b 3.47.5 https://github.com/flutter/flutter.git C:\fl347` (`git config core.longpaths true`), затем `export PATH=/c/fl347/bin:$PATH`.
- Проверка форматирования (длинный `$(git ls-files ...)` на Windows не работает): `git ls-files 'lib/**.dart' 'test/**.dart' 'tool/**.dart' | xargs -n 80 dart format --output=none --set-exit-if-changed`; новые (неотслеживаемые) файлы форматировать явно.
- `flutter pub get` на Windows меняет только концы строк в `app/windows/flutter/generated_plugin_registrant.*` и `generated_plugins.cmake` — откатывать `git checkout --`, не коммитить.
- Полный `flutter test` ≈ 15 минут: запускать в фоне, вывод в файл. Известные падения только на Windows: два теста в `test/app_test.dart` (жёсткий `/` в пути; блокировка файла SQLCipher).
- Бэкенд: `uv` нет в PATH — `python -m pip install --user uv`, дальше `python -m uv run ...`. Полный `pytest` ≈ 10 минут; на Windows не проходят `tests/test_worker.py` (3 теста посылают SIGTERM самому pytest) и `tests/ai/test_chat_upstream.py::test_a_cut_stream_is_never_retried` — запускать с `--deselect` этих тестов, на Linux-CI они зелёные.
