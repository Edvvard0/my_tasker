# Golden-тесты

Эталоны лежат в `files/`. Снимаются и проверяются **на Linux** (CI —
`ubuntu-24.04`, Flutter 3.47.5).

## Почему картинки стабильны

- Шрифты не берутся из системы: `test/flutter_test_config.dart` загружает
  из ассетов приложения Inter и Lucide (`test/support/fonts.dart`).
  Без этого Flutter рисует весь текст шрифтом Ahem.
- Размер окна и `devicePixelRatio = 1` задаются в тесте явно
  (телефон 390×844, окно 800×600, десктоп 1440×900).
- Допуск сравнения — 0,1 % пикселей (`test/support/golden_comparator.dart`):
  гасит микроразличия антиалиасинга, но реальное изменение вёрстки
  (цвет, сдвиг, пропавший элемент) его превышает.
- Подписи времени («сегодня в 14:02») в golden-тестах Этапа 1 считаются в
  UTC через `debugUtcOffset` (`lib/core/format/ru_format.dart`), а не в поясе
  машины: эталоны одинаковы при любом `TZ`.
- Версия Flutter в CI закреплена (`FLUTTER_VERSION` в `.github/workflows/app.yml`).

## Обновить эталоны

```bash
cd app
flutter test --update-goldens test/goldens
```

Смотрите изменённые PNG глазами перед коммитом. Не снимайте эталоны на
Windows/macOS: рендеринг текста отличается.
