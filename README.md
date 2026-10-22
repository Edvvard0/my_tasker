<div align="center">

# My Tasker

**Личная система трекинга жизни: календарь, задачи, работа, финансы, учёба и ИИ-агент. Offline-first, Android + Windows.**

![Python](https://img.shields.io/badge/Python-3.13-3776AB?style=for-the-badge&logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1?style=for-the-badge&logo=postgresql&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![Docker](https://img.shields.io/badge/Docker_Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white)

[![backend](https://github.com/Edvvard0/my_tasker/actions/workflows/backend.yml/badge.svg)](https://github.com/Edvvard0/my_tasker/actions/workflows/backend.yml)
[![app](https://github.com/Edvvard0/my_tasker/actions/workflows/app.yml/badge.svg)](https://github.com/Edvvard0/my_tasker/actions/workflows/app.yml)

</div>

<!-- TODO: скриншот -->

## 📖 О проекте

My Tasker заменяет россыпь Excel-таблиц и календарей одной системой для одного пользователя: расписание и задачи, проекты и деньги, учёба, сон и чат с ИИ-агентом, который видит ваши данные и умеет создавать задачи. Клиент (Flutter) полностью работает без интернета и синхронизируется со своим сервером на VPS (FastAPI + PostgreSQL), когда появляется сеть.

> Проект в активной разработке: часть модулей уже готова, часть — заглушки (см. [Статус](#-статус)).

## ✨ Возможности

- **Календарь и задачи** — события и задачи с временем, датой или без даты; 5 статусов, приоритеты P1–P5, подзадачи, повторения (RRULE) и исключения, чередование чётных/нечётных недель, праздники РФ, виды «расписание / день / 3 дня / неделя / месяц», бэклог.
- **Быстрый ввод** — синтаксис вида `!1`…`!5` (приоритет), `#проект`, `@человек`, `+тег`, дата и время словами.
- **ИИ-чат** — прокси к [polza.ai](https://polza.ai) на сервере со стримингом (SSE), агенты по разделам с редактируемыми системными промптами, конструктор контекста, карточка задачи в чате (правка → одобрить / отклонить), учёт расхода.
- **Офлайн-ИИ на телефоне** — локальная модель за абстракцией (`flutter_gemma` / LiteRT-LM, адаптер llama.cpp), автопереключение при потере сети.
- **Синхронизация** — outbox на клиенте, push/pull с версиями, слияние по полям + LWW, журнал конфликтов с «вернуть моё», SSE-сигнал об изменениях, корзина 30 дней, «эпоха сервера» для восстановления из дампа.
- **Безопасность** — вход по паролю + TOTP, реестр устройств с отзывом, локальная БД на SQLCipher, HTTPS по IP с закреплением корневого сертификата (certificate pinning), ключ ИИ-провайдера только на сервере.
- **Работа, Финансы** — серверная часть (таблицы, расчёты, инструменты для агента) и общие тестовые векторы готовы; экраны клиента пока заглушки.

## 🚦 Статус

Этапы разработки и их состояние ведутся в [`docs/04_DECISIONS_AND_ROADMAP.md`](docs/04_DECISIONS_AND_ROADMAP.md) (журнал этапов, раздел 5):

| Этап | Состояние |
|---|---|
| 0. Фундамент (монорепо, CI, каркас бэкенда и клиента) | закрыт |
| 1. Вход, устройства, синхронизация | закрыт (кроме ежедневного дампа БД в S3) |
| 2. Календарь и задачи | закрыт |
| 3. ИИ-чат (онлайн) | код готов, ревью и проверка на живом ключе впереди |
| 4. Работа / 5. Финансы | бэкенд готов, клиент — заглушки |
| 10. ИИ офлайн | логика готова, замеры на устройстве впереди |
| 6–9 (Банки, Учёба, Сон и ритуалы, Мониторинг серверов) | запланированы |

## 🧱 Стек

| Технология | Роль |
|---|---|
| Python 3.13, FastAPI, Uvicorn | API и воркер (один образ) |
| SQLAlchemy 2 (async), asyncpg, Alembic | доступ к PostgreSQL 17, миграции |
| Pydantic / pydantic-settings, structlog | схемы, конфигурация из env, структурированные логи |
| argon2-cffi, cryptography | хеширование паролей, шифрование секрета TOTP |
| httpx | клиент к polza.ai |
| pytest, hypothesis, ruff, mypy (strict) | тесты (покрытие ≥ 90 %), property-based тесты, линтеры |
| Flutter / Dart (`^3.13.4`), Riverpod, go_router | клиент Android + Windows, состояние, навигация |
| Drift + SQLCipher | локальная зашифрованная БД |
| dio | HTTP-клиент с закреплением сертификата |
| workmanager, flutter_local_notifications | фоновая синхронизация, локальные напоминания |
| flutter_gemma (LiteRT-LM) | локальная ИИ-модель на Android |
| Docker Compose, Caddy | развёртывание, HTTPS по IP (`tls internal`) |
| GitHub Actions, gitleaks | CI: тесты, линтеры, smoke-тест compose, поиск секретов |

## 🗂 Структура проекта

```text
my_tasker/
├── app/                  # Flutter-клиент (Android + Windows)
│   └── lib/
│       ├── core/         # БД (Drift), auth, сеть, синхронизация, деньги, повторы, локальная LLM
│       └── features/     # модули: calendar, tasks, ai_chat, local_ai, sync, devices, trash, ...
├── backend/              # FastAPI api + worker
│   └── src/tasker/       # auth, sync, calendar, ai, work, finance, worker, migrations
├── deploy/               # docker-compose, Dockerfile, Caddyfile, .env.example
├── shared-test-vectors/  # общие тестовые векторы для Python и Dart
├── shared-data/          # общие данные (праздники РФ)
├── docs/                 # бриф, архитектура, дизайн-система, решения и этапы, спецификации
└── .github/workflows/    # CI: backend, app, security (gitleaks)
```

## 🚀 Быстрый старт

### Сервер целиком (Docker Compose)

```bash
cd deploy
cp .env.example .env          # заполнить значения; .env в git не попадает
docker compose up -d --build
docker compose ps             # migrate: Exited (0), остальные: healthy/Up
curl -k https://127.0.0.1/health/ready

# единственного владельца создаёт администратор (регистрации через API нет)
docker compose exec api python -m tasker.cli user create
```

Для локальной проверки в `.env` достаточно `SERVER_IP=127.0.0.1`, произвольных `POSTGRES_USER` / `POSTGRES_DB`, пароля из букв и цифр и `APP_SECRET_KEY` (`openssl rand -hex 32`). Подробности про HTTPS по IP, отпечаток корневого сертификата и восстановление из дампа — в [`deploy/README.md`](deploy/README.md).

### Бэкенд без Docker (из `backend/`)

```bash
uv sync --locked
export DATABASE_URL=postgresql://user:password@localhost:5432/tasker
export APP_SECRET_KEY=...                                     # >= 32 символов
uv run python -m tasker.db_migrations                         # миграции до head
uv run uvicorn tasker.main:create_app --factory --no-access-log   # api
uv run python -m tasker.worker                                # worker (в отдельном терминале)
```

Проверки и тесты (PostgreSQL 17 для тестов поднимается в Docker автоматически):

```bash
uv run ruff check && uv run ruff format --check && uv run mypy
uv run pytest
```

### Клиент (из `app/`)

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # генерация Drift (*.g.dart в git не хранится)
flutter analyze
flutter test --coverage && dart tool/check_coverage.dart --min=90
```

## ⚙️ Конфигурация

Секреты задаются только через переменные окружения; в репозитории лежит только `deploy/.env.example` без значений.

<details>
<summary>Переменные окружения</summary>

| Переменная | Назначение |
|---|---|
| `DATABASE_URL` | строка подключения к PostgreSQL (в compose собирается из `POSTGRES_*`) |
| `APP_SECRET_KEY` | подпись токенов и шифрование секрета TOTP, не короче 32 символов |
| `APP_ENV` | `dev` / `test` / `prod` (по умолчанию `prod`) |
| `LOG_LEVEL` | уровень логов (по умолчанию `INFO`) |
| `TRUST_FORWARDED_FOR` | доверять `X-Forwarded-For` от Caddy (в compose включено) |
| `POLZA_API_KEY` | ключ polza.ai; без него ИИ-эндпоинты отвечают `ai_not_configured` |
| `POLZA_BASE_URL` | адрес API polza.ai (по умолчанию `https://polza.ai/api/v1`) |
| `POLZA_*_TIMEOUT`, `POLZA_MAX_RETRIES`, `AI_MAX_TOOL_ITERATIONS`, `AI_BILLING_TIMEZONE` | тонкая настройка ИИ-прокси (см. `backend/src/tasker/config.py`) |
| `SERVER_IP` | IP/хост, на котором Caddy отдаёт HTTPS (только deploy) |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | учётные данные контейнера PostgreSQL (только deploy) |
| `PYTHON_IMAGE`, `POSTGRES_IMAGE`, `CADDY_IMAGE` | зеркала образов, если Docker Hub отвечает 429 (необязательно) |
| `TEST_POSTGRES_IMAGE`, `HYPOTHESIS_PROFILE` | образ PostgreSQL для тестов; `thorough` — расширенный property-based прогон |

</details>

## 🔌 API

<details>
<summary>Эндпоинты бэкенда</summary>

| Группа | Маршруты |
|---|---|
| Health | `GET /health/live`, `GET /health/ready`, `GET /version` |
| Auth | `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout`, `GET /auth/devices`, `DELETE /auth/devices/{device_id}` |
| Sync | `POST /sync/push`, `GET /sync/pull`, `GET /sync/conflicts`, `POST /sync/conflicts/{conflict_id}/revert`, `GET /events` (SSE) |
| AI | `POST /ai/bootstrap`, `GET /ai/models`, `GET /ai/usage`, `POST /ai/chat/completions`, `POST /ai/chat/{message_id}/cancel`, `POST /ai/agents/{seed_key}/reset` |

Контракт клиента и сервера: [`docs/specs/stage1_sync_and_auth.md`](docs/specs/stage1_sync_and_auth.md). Служебные команды CLI: `python -m tasker.cli user create | reset | unlock`, `python -m tasker.cli epoch show | rotate`.

</details>

## 🗺 Планы

По [`docs/04_DECISIONS_AND_ROADMAP.md`](docs/04_DECISIONS_AND_ROADMAP.md):

- клиентские экраны «Работа» и «Финансы» (серверная часть готова);
- банки: разбор push-уведомлений Т-Банка и ВТБ, импорт выписок, сверка баланса;
- учёба: расписание пар, посещаемость, долги по предметам;
- сон и ежедневные ритуалы (утренний план, вечерний чек-ин);
- мониторинг серверов с алертами в Telegram;
- сборка APK / MSIX, деплой на VPS, ежедневный дамп БД в S3.

## 👤 Автор

**Эдвард Осипчук** — [GitHub @Edvvard0](https://github.com/Edvvard0) · [Telegram @Edward0076](https://t.me/Edward0076)
