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

## Запуск

```bash
export DATABASE_URL=postgresql://user:password@localhost:5432/tasker   # значения ваши
uv run python -m tasker.db_migrations                                   # миграции до head
uv run uvicorn tasker.main:create_app --factory --no-access-log         # api
uv run python -m tasker.worker                                          # worker
```

Миграции: `uv run alembic revision -m "..."` / `uv run alembic upgrade head`. Общие константы версий: `src/tasker/version.py`. Общие тестовые векторы: `../shared-test-vectors/README.md`.
