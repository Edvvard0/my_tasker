/// Куда может смотреть проверка (spec `stage9_monitoring.md`, раздел 5).
///
/// Проверки исполняет сервер, поэтому цель, которую вводит человек, не должна
/// дотянуться до внутренней сети сервера: loopback, частные, link-local и
/// metadata-адреса, имена без точки и внутренние зоны, адреса с логином.
/// Это **порт** серверного эталона `backend/src/tasker/monitoring/targets.py`
/// «один в один»: форма клиента отвечает так же, как сервер при записи, а
/// общие векторы `shared-test-vectors/monitoring/targets.json` проходят обе
/// стороны. Чистые функции без `dart:io`: разбор IP и `urlsplit` написаны
/// здесь, чтобы поведение не зависело от платформы.
library;

import 'package:flutter/foundation.dart';

const int maxHostLength = 253;
const int maxUrlLength = 2000;

/// Имена, имеющие смысл только внутри сети (RFC 6761/6762/8375 и частные зоны).
const List<String> reservedSuffixes = [
  'localhost',
  'local',
  'localdomain',
  'internal',
  'intranet',
  'lan',
  'home',
  'corp',
  'home.arpa',
  'invalid',
  'test',
  'example',
  'onion',
];

/// Вердикт проверки адреса: [valid] и нормализованный [host] (нижний регистр,
/// без скобок и конечной точки) либо [reason] — код причины.
@immutable
class Verdict {
  const Verdict.ok(String this.host) : valid = true, reason = null;
  const Verdict.bad(String this.reason) : valid = false, host = null;

  final bool valid;
  final String? reason;
  final String? host;

  /// Форма общих векторов: `{valid, host}` или `{valid: false, reason}`.
  Map<String, Object?> toJson() => valid
      ? {'valid': true, 'host': host}
      : {'valid': false, 'reason': reason};

  @override
  String toString() => valid ? 'Verdict.ok($host)' : 'Verdict.bad($reason)';
}

final RegExp _label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
final RegExp _tld = RegExp(r'^([a-z]{2,63}|xn--[a-z0-9-]{1,59})$');

// Пробельные символы Unicode — как `\s` у Python для `str` (а не у Dart:
// там есть U+FEFF, но нет U+0085) плюс управляющие.
const String _spaces = r'\x00-\x20\x7f\x85\xa0  -     　';
final RegExp _badHostChars = RegExp('[$_spaces/\\\\@?#%]');
final RegExp _badUrlChars = RegExp('[$_spaces\\\\]');
final RegExp _asciiDigits = RegExp(r'^[0-9]+$');
final RegExp _hexDigits = RegExp(r'^[0-9a-fA-F]*$');

// ---------------------------------------------------------------- IP-адреса

/// Разобранный адрес: четыре октета IPv4 либо восемь хекстетов IPv6.
class _Ip {
  const _Ip.v4(this.parts) : v6 = false;
  const _Ip.v6(this.parts) : v6 = true;

  final bool v6;
  final List<int> parts;
}

/// `ipaddress.IPv4Address`: ровно четыре десятичных октета 0…255 из 1–3
/// ASCII-цифр, без ведущих нулей (Python 3.9.5+).
List<int>? _parseV4(String text) {
  final octets = text.split('.');
  if (octets.length != 4) return null;
  final out = <int>[];
  for (final o in octets) {
    if (o.isEmpty || !_asciiDigits.hasMatch(o) || o.length > 3) return null;
    if (o.length > 1 && o.startsWith('0')) return null;
    final n = int.parse(o);
    if (n > 255) return null;
    out.add(n);
  }
  return out;
}

int? _hextet(String text) {
  if (text.isEmpty || text.length > 4 || !_hexDigits.hasMatch(text)) {
    return null;
  }
  return int.parse(text, radix: 16);
}

/// `ipaddress.IPv6Address` (без `%зоны`: она отсекается раньше).
List<int>? _parseV6(String text) {
  final parts = text.split(':');
  if (parts.length < 3) return null;
  if (parts.last.contains('.')) {
    final v4 = _parseV4(parts.removeLast());
    if (v4 == null) return null;
    parts
      ..add(((v4[0] << 8) | v4[1]).toRadixString(16))
      ..add(((v4[2] << 8) | v4[3]).toRadixString(16));
  }
  if (parts.length > 9) return null;
  int? skip;
  for (var i = 1; i < parts.length - 1; i++) {
    if (parts[i].isEmpty) {
      if (skip != null) return null; // два «::»
      skip = i;
    }
  }
  int hi;
  int lo;
  int skipped;
  if (skip != null) {
    hi = skip;
    lo = parts.length - skip - 1;
    if (parts.first.isEmpty) {
      hi -= 1;
      if (hi != 0) return null; // «:» в начале допустимо только как «::»
    }
    if (parts.last.isEmpty) {
      lo -= 1;
      if (lo != 0) return null;
    }
    skipped = 8 - (hi + lo);
    if (skipped < 1) return null;
  } else {
    if (parts.length != 8) return null;
    if (parts.first.isEmpty || parts.last.isEmpty) return null;
    hi = parts.length;
    lo = 0;
    skipped = 0;
  }
  final out = <int>[];
  for (var i = 0; i < hi; i++) {
    final h = _hextet(parts[i]);
    if (h == null) return null;
    out.add(h);
  }
  for (var i = 0; i < skipped; i++) {
    out.add(0);
  }
  for (var i = parts.length - lo; i < parts.length; i++) {
    final h = _hextet(parts[i]);
    if (h == null) return null;
    out.add(h);
  }
  return out.length == 8 ? out : null;
}

/// `ipaddress.ip_address`: IPv4, иначе IPv6; `null` — не IP-адрес.
_Ip? _parseIp(String text) {
  final v4 = _parseV4(text);
  if (v4 != null) return _Ip.v4(v4);
  final v6 = _parseV6(text);
  return v6 == null ? null : _Ip.v6(v6);
}

/// Попадает ли адрес (октеты/хекстеты) в сеть `base/prefix`.
bool _inNet(List<int> parts, List<int> base, int prefix, {required int unit}) {
  var bits = prefix;
  for (var i = 0; i < parts.length && bits > 0; i++) {
    final take = bits >= unit ? unit : bits;
    final shift = unit - take;
    if ((parts[i] >> shift) != (base[i] >> shift)) return false;
    bits -= take;
  }
  return true;
}

bool _in4(List<int> p, List<int> base, int prefix) =>
    _inNet(p, base, prefix, unit: 8);

bool _in6(List<int> p, List<int> base, int prefix) =>
    _inNet(p, base, prefix, unit: 16);

// Не глобально достижимые блоки IPv4 (`_IPv4Constants._private_networks`).
const List<(List<int>, int)> _private4 = [
  ([0, 0, 0, 0], 8),
  ([10, 0, 0, 0], 8),
  ([127, 0, 0, 0], 8),
  ([169, 254, 0, 0], 16),
  ([172, 16, 0, 0], 12),
  ([192, 0, 0, 0], 24),
  ([192, 0, 0, 170], 31),
  ([192, 0, 2, 0], 24),
  ([192, 168, 0, 0], 16),
  ([198, 18, 0, 0], 15),
  ([198, 51, 100, 0], 24),
  ([203, 0, 113, 0], 24),
  ([240, 0, 0, 0], 4),
  ([255, 255, 255, 255], 32),
];
const List<(List<int>, int)> _private4Exceptions = [
  ([192, 0, 0, 9], 32),
  ([192, 0, 0, 10], 32),
];

// IPv6: `_IPv6Constants._private_networks` (и исключения).
const List<(List<int>, int)> _private6 = [
  ([0, 0, 0, 0, 0, 0, 0, 1], 128),
  ([0, 0, 0, 0, 0, 0, 0, 0], 128),
  ([0, 0, 0, 0, 0, 0xffff, 0, 0], 96),
  ([0x64, 0xff9b, 1, 0, 0, 0, 0, 0], 48),
  ([0x100, 0, 0, 0, 0, 0, 0, 0], 64),
  ([0x2001, 0, 0, 0, 0, 0, 0, 0], 23),
  ([0x2001, 0xdb8, 0, 0, 0, 0, 0, 0], 32),
  ([0x2002, 0, 0, 0, 0, 0, 0, 0], 16),
  ([0x3fff, 0, 0, 0, 0, 0, 0, 0], 20),
  ([0xfc00, 0, 0, 0, 0, 0, 0, 0], 7),
  ([0xfe80, 0, 0, 0, 0, 0, 0, 0], 10),
];
const List<(List<int>, int)> _private6Exceptions = [
  ([0x2001, 1, 0, 0, 0, 0, 0, 1], 128),
  ([0x2001, 1, 0, 0, 0, 0, 0, 2], 128),
  ([0x2001, 3, 0, 0, 0, 0, 0, 0], 32),
  ([0x2001, 4, 0x112, 0, 0, 0, 0, 0], 48),
  ([0x2001, 0x20, 0, 0, 0, 0, 0, 0], 28),
  ([0x2001, 0x30, 0, 0, 0, 0, 0, 0], 28),
];
const List<(List<int>, int)> _reserved6 = [
  ([0, 0, 0, 0, 0, 0, 0, 0], 8),
  ([0x100, 0, 0, 0, 0, 0, 0, 0], 8),
  ([0x200, 0, 0, 0, 0, 0, 0, 0], 7),
  ([0x400, 0, 0, 0, 0, 0, 0, 0], 6),
  ([0x800, 0, 0, 0, 0, 0, 0, 0], 5),
  ([0x1000, 0, 0, 0, 0, 0, 0, 0], 4),
  ([0x4000, 0, 0, 0, 0, 0, 0, 0], 3),
  ([0x6000, 0, 0, 0, 0, 0, 0, 0], 3),
  ([0x8000, 0, 0, 0, 0, 0, 0, 0], 3),
  ([0xa000, 0, 0, 0, 0, 0, 0, 0], 3),
  ([0xc000, 0, 0, 0, 0, 0, 0, 0], 3),
  ([0xe000, 0, 0, 0, 0, 0, 0, 0], 4),
  ([0xf000, 0, 0, 0, 0, 0, 0, 0], 5),
  ([0xf800, 0, 0, 0, 0, 0, 0, 0], 6),
  ([0xfe00, 0, 0, 0, 0, 0, 0, 0], 9),
];

bool _anyNet(
  List<int> p,
  List<(List<int>, int)> nets,
  bool Function(List<int>, List<int>, int) contains,
) {
  for (final (base, prefix) in nets) {
    if (contains(p, base, prefix)) return true;
  }
  return false;
}

bool _nonGlobal4(List<int> p) {
  final private =
      _anyNet(p, _private4, _in4) && !_anyNet(p, _private4Exceptions, _in4);
  final cgnat = _in4(p, const [100, 64, 0, 0], 10);
  final multicast = _in4(p, const [224, 0, 0, 0], 4);
  final reserved = _in4(p, const [240, 0, 0, 0], 4);
  final unspecified = p.every((o) => o == 0);
  return private || cgnat || multicast || reserved || unspecified;
}

bool _nonGlobal6(List<int> p) {
  final mapped =
      p[0] == 0 &&
      p[1] == 0 &&
      p[2] == 0 &&
      p[3] == 0 &&
      p[4] == 0 &&
      p[5] == 0xffff;
  if (mapped) {
    // IPv4 внутри IPv6 судится по IPv4.
    return _nonGlobal4([p[6] >> 8, p[6] & 255, p[7] >> 8, p[7] & 255]);
  }
  final private =
      _anyNet(p, _private6, _in6) && !_anyNet(p, _private6Exceptions, _in6);
  final multicast = _in6(p, const [0xff00, 0, 0, 0, 0, 0, 0, 0], 8);
  final reserved = _anyNet(p, _reserved6, _in6);
  final unspecified = p.every((h) => h == 0);
  return private || multicast || reserved || unspecified;
}

/// `true` для всего, что не публичный одноадресный адрес (в том числе IPv4
/// внутри IPv6 и нераспознанный текст). Зона `%…` отбрасывается.
bool nonGlobal(String address) {
  final ip = _parseIp(address.split('%').first);
  if (ip == null) return true;
  return ip.v6 ? _nonGlobal6(ip.parts) : _nonGlobal4(ip.parts);
}

// ---------------------------------------------------------------- хост

/// Чистый хост: публичный IP (v6 со скобками или без) либо публично
/// выглядящее имя. Причины: `empty`, `too_long`, `bad_chars`, `non_global_ip`,
/// `single_label`, `bad_label`, `bad_tld`, `reserved_name`.
Verdict checkHost(String host) {
  if (host.isEmpty) return const Verdict.bad('empty');
  if (host.runes.length > maxHostLength + 2) {
    return const Verdict.bad('too_long');
  }
  final plain = host
      .replaceAll(':', '')
      .replaceAll('[', '')
      .replaceAll(']', '');
  if (_badHostChars.hasMatch(plain)) return const Verdict.bad('bad_chars');
  final bracketed = host.startsWith('[') && host.endsWith(']');
  final inner = bracketed ? host.substring(1, host.length - 1) : host;
  final ip = _parseIp(inner);
  if (ip != null) {
    if (bracketed && !ip.v6) return const Verdict.bad('bad_chars');
    return nonGlobal(inner)
        ? const Verdict.bad('non_global_ip')
        : Verdict.ok(inner.toLowerCase());
  }
  var name = _lower(host);
  if (name.endsWith('.')) name = name.substring(0, name.length - 1);
  if (!_isAscii(name) ||
      name.contains(':') ||
      name.contains('[') ||
      name.contains(']')) {
    return const Verdict.bad('bad_chars');
  }
  if (name.length > maxHostLength) return const Verdict.bad('too_long');
  final labels = name.split('.');
  if (labels.length < 2) return const Verdict.bad('single_label');
  if (!labels.every(_label.hasMatch)) return const Verdict.bad('bad_label');
  if (!_tld.hasMatch(labels.last)) return const Verdict.bad('bad_tld');
  for (final s in reservedSuffixes) {
    if (name == s || name.endsWith('.$s')) {
      return const Verdict.bad('reserved_name');
    }
  }
  return Verdict.ok(name);
}

/// `str.lower()` Python для того, что может стать ASCII: латиница и знак
/// Кельвина (U+212A -> `k`). Остальные не-ASCII символы остаются как есть:
/// имя с ними всё равно отклоняется (`bad_chars`), а полная таблица Unicode
/// у Dart и Python различается (например, U+0130).
String _lower(String text) {
  final out = StringBuffer();
  for (final r in text.runes) {
    if (r >= 0x41 && r <= 0x5a) {
      out.writeCharCode(r + 32);
    } else if (r == 0x212a) {
      out.write('k');
    } else {
      out.writeCharCode(r);
    }
  }
  return out.toString();
}

bool _isAscii(String text) => text.codeUnits.every((u) => u < 128);

// ---------------------------------------------------------------- URL

/// Часть `urlsplit` из Python 3.13, нужная проверке адреса.
class _Split {
  _Split({
    required this.scheme,
    required this.netloc,
    required this.fragment,
    required this.endsWithHash,
  });

  final String scheme;
  final String netloc;
  final bool fragment;
  final bool endsWithHash;
}

bool _schemeChars(String s) =>
    RegExp(r'^[A-Za-z0-9+\-.]+$').hasMatch(s) && s.isNotEmpty;

/// `urllib.parse.urlsplit`: схема, netloc, наличие фрагмента; `null` —
/// `ValueError` (неверные скобки IPv6).
_Split? _urlSplit(String url) {
  var rest = url;
  var scheme = '';
  final colon = rest.indexOf(':');
  if (colon > 0 &&
      RegExp('^[A-Za-z]').hasMatch(rest) &&
      _schemeChars(rest.substring(0, colon))) {
    scheme = rest.substring(0, colon).toLowerCase();
    rest = rest.substring(colon + 1);
  }
  var netloc = '';
  if (rest.startsWith('//')) {
    var end = rest.length;
    for (final ch in const ['/', '?', '#']) {
      final i = rest.indexOf(ch, 2);
      if (i >= 0 && i < end) end = i;
    }
    netloc = rest.substring(2, end);
    rest = rest.substring(end);
    final open = netloc.contains('[');
    final close = netloc.contains(']');
    if (open != close) return null;
    if (open && close && !_bracketedNetlocOk(netloc)) return null;
    if (_nfkcBreaksNetloc(netloc)) return null;
  }
  var hasFragment = false;
  final hash = rest.indexOf('#');
  if (hash >= 0) {
    hasFragment = rest.substring(hash + 1).isNotEmpty;
    rest = rest.substring(0, hash);
  }
  return _Split(
    scheme: scheme,
    netloc: netloc,
    fragment: hasFragment,
    endsWithHash: url.endsWith('#'),
  );
}

/// `urllib.parse._check_bracketed_netloc` (Python 3.13): перед `[` ничего
/// быть не может, после `]` сразу конец netloc или `:порт`, а внутри скобок —
/// IPv6. Если скобки есть, проверяется и хост без скобок (`[::1]@a.com` — ошибка).
bool _bracketedNetlocOk(String netloc) {
  final at = netloc.lastIndexOf('@');
  final hostAndPort = at >= 0 ? netloc.substring(at + 1) : netloc;
  final open = hostAndPort.indexOf('[');
  String hostname;
  if (open >= 0) {
    if (open > 0) return false; // текст перед «[»
    final bracketed = hostAndPort.substring(open + 1);
    final close = bracketed.indexOf(']');
    hostname = close >= 0 ? bracketed.substring(0, close) : bracketed;
    final after = close >= 0 ? bracketed.substring(close + 1) : '';
    if (after.isNotEmpty && !after.startsWith(':')) return false;
  } else {
    final c = hostAndPort.indexOf(':');
    hostname = c >= 0 ? hostAndPort.substring(0, c) : hostAndPort;
  }
  return _bracketedHostOk(hostname);
}

/// Символы, которые после NFKC превращаются в `/ ? # @ :` (U+2047, U+2100,
/// U+FF03, U+FF0F…): Python `_checknetloc` отвергает такой netloc как
/// `ValueError`. Список получен перебором Unicode 15 в Python 3.13.
const Set<int> _nfkcSeparators = {
  0x2047, 0x2048, 0x2049, 0x2100, 0x2101, 0x2105, 0x2106, 0x2a74, 0xfe13, //
  0xfe16, 0xfe55, 0xfe56, 0xfe5f, 0xfe6b, 0xff03, 0xff0f, 0xff1a, 0xff1f,
  0xff20,
};

bool _nfkcBreaksNetloc(String netloc) =>
    netloc.runes.any(_nfkcSeparators.contains);

/// `urllib.parse._check_bracketed_host`: содержимое скобок — IPv6 (с зоной)
/// или IPvFuture; IPv4 в скобках — ошибка.
bool _bracketedHostOk(String host) {
  if (host.startsWith('v')) {
    return RegExp(r'^v[a-fA-F0-9]+\..+$').hasMatch(host);
  }
  final ip = _parseIp(host.split('%').first);
  if (ip == null || !ip.v6) return false;
  // Зона допустима только у IPv6 и не должна быть пустой/с «%».
  final pct = host.indexOf('%');
  if (pct >= 0) {
    final zone = host.substring(pct + 1);
    if (zone.isEmpty || zone.contains('%')) return false;
  }
  return true;
}

/// Хост, порт (текст) и признак логина из netloc, как `SplitResult`.
({String? hostname, String? port, bool userinfo}) _hostInfo(String netloc) {
  final at = netloc.lastIndexOf('@');
  final hostinfo = at >= 0 ? netloc.substring(at + 1) : netloc;
  String host;
  String port;
  final open = hostinfo.indexOf('[');
  if (open >= 0) {
    final bracketed = hostinfo.substring(open + 1);
    final close = bracketed.indexOf(']');
    host = close >= 0 ? bracketed.substring(0, close) : bracketed;
    final after = close >= 0 ? bracketed.substring(close + 1) : '';
    final c = after.indexOf(':');
    port = c >= 0 ? after.substring(c + 1) : '';
  } else {
    final c = hostinfo.indexOf(':');
    host = c >= 0 ? hostinfo.substring(0, c) : hostinfo;
    port = c >= 0 ? hostinfo.substring(c + 1) : '';
  }
  return (
    hostname: host.isEmpty ? null : host,
    port: port.isEmpty ? null : port,
    userinfo: at >= 0,
  );
}

/// `http(s)`-адрес с публичным хостом, без логина и фрагмента. Причины — как у
/// [checkHost] плюс `scheme`, `userinfo`, `fragment`, `bad_port`, `bad_url`,
/// `no_host`.
Verdict checkUrl(String url) {
  if (url.isEmpty) return const Verdict.bad('empty');
  if (url.runes.length > maxUrlLength) return const Verdict.bad('too_long');
  if (_badUrlChars.hasMatch(url)) return const Verdict.bad('bad_chars');
  final split = _urlSplit(url);
  if (split == null) return const Verdict.bad('bad_url');
  final info = _hostInfo(split.netloc);
  int? port;
  final portText = info.port;
  if (portText != null) {
    if (!_asciiDigits.hasMatch(portText)) return const Verdict.bad('bad_port');
    port = int.tryParse(portText);
    if (port == null || port > 65535) return const Verdict.bad('bad_port');
  }
  if (split.scheme != 'http' && split.scheme != 'https') {
    return const Verdict.bad('scheme');
  }
  if (split.netloc.contains('@')) return const Verdict.bad('userinfo');
  if (split.fragment || split.endsWithHash) {
    return const Verdict.bad('fragment');
  }
  if (port != null && (port < 1 || port > 65535)) {
    return const Verdict.bad('bad_port');
  }
  final hostname = info.hostname;
  if (hostname == null) return const Verdict.bad('no_host');
  // `hostname` у Python: нижний регистр, зона `%…` не меняется.
  final pct = hostname.indexOf('%');
  final normalised = pct >= 0
      ? _lower(hostname.substring(0, pct)) + hostname.substring(pct)
      : _lower(hostname);
  final verdict = checkHost(normalised);
  return verdict.valid ? verdict : Verdict.bad(verdict.reason ?? 'bad_host');
}

/// Что получилось после разрешения имени: `null` — есть хотя бы один адрес и
/// все публичные; иначе `no_address` / `resolves_to_non_global`.
String? checkAddresses(Iterable<String> addresses) {
  final found = addresses.toList();
  if (found.isEmpty) return 'no_address';
  return found.any(nonGlobal) ? 'resolves_to_non_global' : null;
}
