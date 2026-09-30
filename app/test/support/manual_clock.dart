/// Управляемые часы устройства в миллисекундах Unix.
class ManualClock {
  ManualClock([this.ms = 1790000000000]);

  int ms;

  int call() => ms;

  DateTime get now => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  void advance(Duration d) => ms += d.inMilliseconds;
}
