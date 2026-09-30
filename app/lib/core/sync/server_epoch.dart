/// Что клиент делает с `server_epoch` из ответа сервера (login, refresh,
/// pull, push, `/version`; spec 3.10 и 5.3,
/// `shared-test-vectors/sync/epoch.json`).
enum EpochAction {
  /// Ничего: эпоха та же (или сервер её не прислал).
  none,

  /// Запомнить: первый контакт с сервером.
  store,

  /// Сервер восстановили из копии: полная пересинхронизация с сохранением
  /// outbox, затем запомнить новую эпоху.
  fullResync,
}

/// Решение по паре «запомненная» / «полученная» эпоха. Сравнение точное
/// (регистр важен); пустая запомненная строка — обычное значение, а не
/// «ещё не было».
EpochAction epochAction({required String? stored, required String? received}) {
  if (received == null) return EpochAction.none;
  if (stored == null) return EpochAction.store;
  return stored == received ? EpochAction.none : EpochAction.fullResync;
}
