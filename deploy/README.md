# Развёртывание (docker compose)

Состав: `caddy` (HTTPS по IP), `api`, `worker` (один образ), `migrate` (одноразово, до api и worker), `postgres` (том `pgdata`). Наружу открыты только 80 и 443; PostgreSQL виден только во внутренней сети compose. Контейнеры приложения работают не от root, с `read_only` и без capabilities.

## Запуск локально

```bash
cd deploy
cp .env.example .env          # заполните значения (файл .env в git не попадает)
docker compose up -d --build
docker compose ps             # migrate: Exited (0), остальные: healthy/Up
curl -k https://127.0.0.1/health/ready    # {"status":"ok"}
```

В `.env` обязателен `APP_SECRET_KEY` (`openssl rand -hex 32`). Владельца создаёт команда `docker compose exec api python -m tasker.cli user create` (пароль вводится интерактивно, секрет TOTP печатается один раз). Для локальной проверки в `.env` достаточно `SERVER_IP=127.0.0.1`, произвольных `POSTGRES_USER`, `POSTGRES_DB` и пароля из букв и цифр (`openssl rand -hex 24`). Пароль попадает в `DATABASE_URL` как есть, поэтому спецсимволы в нём недопустимы.

Если Docker Hub отвечает 429, задайте зеркала в `.env`:

```
PYTHON_IMAGE=mirror.gcr.io/library/python:3.13-slim
POSTGRES_IMAGE=mirror.gcr.io/library/postgres:17-alpine
CADDY_IMAGE=mirror.gcr.io/library/caddy:2
```

Остановка: `docker compose down` (данные сохраняются), `docker compose down -v` (данные и сертификаты удаляются).

Порядок старта обеспечен зависимостями: `postgres` (healthy) → `migrate` (успешно завершился) → `api` и `worker` → `caddy`. `GET /health/ready` возвращает 503, пока БД недоступна или миграции не на последней ревизии.

## Как работает HTTPS по IP и pinning

Домена нет, поэтому Let's Encrypt недоступен. Caddy (`tls internal`) поднимает **собственный корневой центр сертификации** и выпускает от него сертификат на IP-адрес. Решение из `docs/04_DECISIONS_AND_ROADMAP.md`, п. 1.5:

1. Клиент **не доверяет системным центрам** для адреса сервера. Он доверяет только одному корневому сертификату (root CA) этого Caddy.
2. При настройке адреса сервера пользователь вводит SHA-256 отпечаток корня (получение ниже) либо клиент скачивает корень с `https://<IP>/ca/root.crt` и показывает его отпечаток, а пользователь сверяет его с отпечатком, полученным по SSH. Совпало: корень сохраняется в локальной БД приложения, зашифрованной SQLCipher (ключ БД лежит в Android Keystore / Windows DPAPI через secure storage).
3. Все дальнейшие соединения проверяются по цепочке до сохранённого корня. Листовой и промежуточный сертификаты Caddy обновляет сам, на клиенте это ничего не меняет. Caddy отдаёт в рукопожатии листовой и промежуточный, но не корневой, поэтому корень клиент хранит у себя.
4. Корень живёт 10 лет и лежит в томе `caddy_data`. Если том удалить, Caddy создаст **новый** корень, и клиенты придётся перенастроить. Том нужно включить в бэкап сервера.
5. Когда появится домен: заменить `tls internal` на автоматический Let's Encrypt (в Caddyfile адрес сайта станет доменом), а в клиенте сменить адрес и выключить pinning.

Эндпоинт `/ca/root.crt` отдаёт только публичный корневой сертификат (закрытый ключ не отдаётся: путь жёстко переписан на `root.crt`).

## Отпечаток корневого сертификата

На сервере:

```bash
cd deploy
docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt \
  | openssl x509 -noout -fingerprint -sha256
# sha256 Fingerprint=AA:BB:...   (32 байта, через двоеточие)
```

Сохранить сам сертификат, например для импорта в клиент или проверки `curl`:

```bash
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
curl --cacert ./caddy-root.crt https://<IP>/health/ready     # без -k
```

Проверка с любой машины (первый контакт, до pinning) и сверка с отпечатком, полученным по SSH:

```bash
curl -ks https://<IP>/ca/root.crt | openssl x509 -noout -fingerprint -sha256
```

## Владелец и блокировки входа

Публичной регистрации нет, единственного владельца создаёт администратор на сервере (спецификация `docs/specs/stage1_sync_and_auth.md`, раздел 1):

```bash
docker compose exec api python -m tasker.cli user create             # пароль 12-256 символов, спрашивается дважды
printf '%s\n' "$PASSWORD" | docker compose exec -T api python -m tasker.cli user create --password-stdin --json
docker compose exec api python -m tasker.cli user reset              # новый пароль и TOTP, все устройства отзываются
docker compose exec api python -m tasker.cli user unlock             # снять блокировки входа (после серии неудач)
```

`--json` печатает `{"otpauth_uri", "totp_secret"}` одной строкой (для скриптов и CI). Если после смены `APP_SECRET_KEY` вход отвечает `owner_secret_unreadable`, выполните `user reset`: ключ шифрует секрет TOTP, войти прежним секретом уже нельзя (устройства, которые уже вошли, продолжают работать).

## Восстановление из дампа и эпоха сервера

Клиенты запоминают `server_epoch` (случайный id базы). После восстановления из дампа сервер должен сообщить им «история изменилась», иначе устройства с более новыми данными будут ждать от сервера версий, которых там нет. Порядок:

```bash
docker compose stop api worker
# восстановить базу из дампа (pg_restore / psql), том pgdata не трогать вручную
docker compose run --rm migrate                                      # миграции; если база переехала в другой кластер, эпоха сменится сама
docker compose run --rm api python -m tasker.cli epoch rotate        # ВСЕГДА выполнять: покрывает и восстановление в ту же базу
docker compose up -d api worker
```

После этого каждое устройство при следующей синхронизации получает новую эпоху и делает полную пересинхронизацию, сохраняя неотправленные правки (спецификация 3.10). Данные, которые сервер подтвердил после снятия дампа, потеряны. `docker compose exec api python -m tasker.cli epoch show` печатает текущую эпоху.

## Переменные окружения

Имена без значений перечислены в `.env.example`. Секреты (`POSTGRES_PASSWORD` и другие) живут только в `deploy/.env` на сервере с правами 600 и никогда не коммитятся. Сервисы `api`, `worker` и `migrate` получают `DATABASE_URL`, собранный из `POSTGRES_*`; `APP_ENV` (по умолчанию `prod`) и `LOG_LEVEL` (по умолчанию `INFO`) необязательны.

## Вложения и общие данные

- Файлы вложений (этап 7) лежат в томе `files` (`FILES_DIR=/data/files` у `api` и `worker`), отдельно от базы. **Бэкап базы в S3 файлы не покрывает**: том `files` нужно сохранять отдельно (вместе с `caddy_data`). Воркер удаляет файл вместе с очисткой корзины. Лимиты: файл 25 МБ (`FILES_MAX_BYTES`), выписка банка 10 МБ (`BANKS_STATEMENT_MAX_BYTES`, файл не хранится); Caddy пропускает тело до 27 МБ (SI) на `/files/*` и до 10 МБ (SI) на остальных путях.
- Каталог `shared-data/` репозитория монтируется в контейнеры только на чтение (`SHARED_DATA_DIR=/shared-data`): правила банков, праздники РФ. Образ его не содержит.

## Образ

`deploy/Dockerfile` собирается из каталога `backend/` (двухэтапная сборка, зависимости строго по `uv.lock`, пользователь `app` с uid 10001):

```bash
docker build -f deploy/Dockerfile backend
```
