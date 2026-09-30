# My Tasker — клиент (Flutter)

Android + Windows. Правила проекта — в `../CLAUDE.md`, решения и этапы — в
`../docs/04_DECISIONS_AND_ROADMAP.md`.

Раскладка: `lib/core/` (тема, БД, сеть, деньги, раскладка), `lib/features/<модуль>/`,
`lib/app.dart`. Локальная БД — Drift поверх SQLCipher (сборка подтягивается
build hook-ом пакета `sqlite3`, см. `hooks` в `pubspec.yaml`). Шрифты и их
лицензии — `assets/fonts/`. Golden-тесты — `test/goldens/README.md`.
