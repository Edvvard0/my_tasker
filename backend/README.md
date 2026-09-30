# My Tasker backend

FastAPI (api) и worker на одном образе. Python 3.13, менеджер `uv`.

## Проверки

```bash
cd backend
uv sync --locked
uv run ruff check && uv run ruff format --check && uv run mypy
uv run pytest          # покрытие >= 90 % проверяется автоматически
```

## Тесты и PostgreSQL

Тесты идут на настоящем PostgreSQL 17, каждый тест получает чистую базу.

- `DATABASE_URL` задан: используется этот сервер (роли нужно право CREATEDB), тестовые базы создаются и удаляются.
- Не задан: фикстура сама запускает временный контейнер через docker CLI. Образ по умолчанию `mirror.gcr.io/library/postgres:17-alpine`, переопределяется `TEST_POSTGRES_IMAGE`.

## Аккаунт и синхронизация

- Единственного владельца создаёт CLI (регистрации через API нет): `uv run python -m tasker.cli user create` (или `user reset`: новый пароль и TOTP, все устройства отзываются). Нужны `DATABASE_URL` и `APP_SECRET_KEY` (≥ 32 символов). Секрет TOTP печатается один раз.
- Контракт клиента и сервера: `../docs/specs/stage1_sync_and_auth.md`. Синхронизируемые таблицы объявляются в реестре (`src/tasker/sync/registry.py`, регистрация — `src/tasker/sync/modules.py`).
- Воркер раз в час очищает корзину (надгробия старше 30 дней, уже полученные всеми активными устройствами) и журналы.
- Property-based тесты синхронизации: по умолчанию 40 примеров; `HYPOTHESIS_PROFILE=thorough` — 400.

## Запуск

```bash
export DATABASE_URL=postgresql://user:password@localhost:5432/tasker   # значения ваши
export APP_SECRET_KEY=...                                               # >= 32 символов, `openssl rand -hex 32`
uv run python -m tasker.db_migrations                                   # миграции до head
uv run uvicorn tasker.main:create_app --factory --no-access-log         # api
uv run python -m tasker.worker                                          # worker
```

Миграции: `uv run alembic revision -m "..."` / `uv run alembic upgrade head`. Общие константы версий: `src/tasker/version.py`. Общие тестовые векторы: `../shared-test-vectors/README.md`.
