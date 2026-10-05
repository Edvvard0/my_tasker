import 'dart:typed_data';

/// Сколько первых байтов файла нужно для проверки типа.
const int fileHeadBytes = 1024;

const List<int> _ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
const List<int> _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const List<int> _pdf = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-

bool _startsWith(Uint8List head, List<int> prefix, [int offset = 0]) {
  if (head.length < offset + prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (head[offset + i] != prefix[i]) return false;
  }
  return true;
}

bool _contains(Uint8List head, List<int> needle) {
  for (var i = 0; i + needle.length <= head.length; i++) {
    if (_startsWith(head, needle, i)) return true;
  }
  return false;
}

/// Дешёвая проверка, что первые байты файла подходят к заявленному типу
/// [mime] (не антивирус). Порт `backend/src/tasker/files/magic.py`:
/// сервер отвергает неподходящее содержимое (`415`), поэтому клиент
/// отказывает сразу, не доводя файл до бесконечной перезаливки. В [bytes]
/// достаточно первых [fileHeadBytes] байтов (лишнее отбрасывается).
bool looksLikeMime(String mime, Uint8List bytes) {
  final head = bytes.length > fileHeadBytes
      ? Uint8List.sublistView(bytes, 0, fileHeadBytes)
      : bytes;
  switch (mime) {
    case 'image/jpeg':
      return _startsWith(head, const [0xFF, 0xD8, 0xFF]);
    case 'image/png':
      return _startsWith(head, _png);
    case 'image/webp':
      // RIFF....WEBP
      return _startsWith(head, const [0x52, 0x49, 0x46, 0x46]) &&
          _startsWith(head, const [0x57, 0x45, 0x42, 0x50], 8);
    case 'image/heic' || 'image/heif':
      // ....ftyp
      return _startsWith(head, const [0x66, 0x74, 0x79, 0x70], 4);
    case 'application/pdf':
      return _contains(head, _pdf);
    case 'application/msword' ||
        'application/vnd.ms-excel' ||
        'application/vnd.ms-powerpoint':
      return _startsWith(head, _ole);
    case 'text/plain':
      return !head.contains(0);
    default:
      // docx, xlsx, pptx, zip
      return _startsWith(head, const [0x50, 0x4B, 0x03, 0x04]) ||
          _startsWith(head, const [0x50, 0x4B, 0x05, 0x06]);
  }
}
