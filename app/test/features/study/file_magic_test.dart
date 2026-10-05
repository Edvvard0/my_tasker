import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/study/domain/file_magic.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

/// Те же случаи, что у сервера (`backend/src/tasker/files/magic.py`).
void main() {
  group('первые байты файла подходят к типу (порт magic.py)', () {
    test('JPEG и PNG', () {
      expect(looksLikeMime('image/jpeg', _b([0xFF, 0xD8, 0xFF, 0xE0])), isTrue);
      expect(looksLikeMime('image/jpeg', _b([0xFF, 0xD8])), isFalse);
      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0];
      expect(looksLikeMime('image/png', _b(png)), isTrue);
      expect(looksLikeMime('image/png', _b(png.sublist(0, 7))), isFalse);
      expect(looksLikeMime('image/png', _b([1, 2, 3])), isFalse);
    });

    test('WebP: RIFF....WEBP', () {
      final webp = [...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WEBP'.codeUnits, 0];
      expect(looksLikeMime('image/webp', _b(webp)), isTrue);
      final other = [...webp]..replaceRange(8, 12, 'WAVE'.codeUnits);
      expect(looksLikeMime('image/webp', _b(other)), isFalse);
      expect(looksLikeMime('image/webp', _b(webp.sublist(0, 11))), isFalse);
    });

    test('HEIC и HEIF: ftyp на смещении 4', () {
      final heic = [0, 0, 0, 24, ...'ftypheic'.codeUnits];
      expect(looksLikeMime('image/heic', _b(heic)), isTrue);
      expect(looksLikeMime('image/heif', _b(heic)), isTrue);
      expect(
        looksLikeMime('image/heic', _b([0, 0, 0, 24, 1, 2, 3, 4])),
        isFalse,
      );
    });

    test('PDF: %PDF- где-то в первом килобайте', () {
      expect(
        looksLikeMime('application/pdf', _b('%PDF-1.7'.codeUnits)),
        isTrue,
      );
      final late = Uint8List(1024)..setRange(100, 105, '%PDF-'.codeUnits);
      expect(looksLikeMime('application/pdf', late), isTrue);
      final tooLate = Uint8List(2048)..setRange(1500, 1505, '%PDF-'.codeUnits);
      expect(looksLikeMime('application/pdf', tooLate), isFalse);
      expect(looksLikeMime('application/pdf', _b('%PDF'.codeUnits)), isFalse);
    });

    test('doc, xls, ppt: сигнатура OLE', () {
      final ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0];
      for (final mime in [
        'application/msword',
        'application/vnd.ms-excel',
        'application/vnd.ms-powerpoint',
      ]) {
        expect(looksLikeMime(mime, _b(ole)), isTrue, reason: mime);
        expect(looksLikeMime(mime, _b('PK\x03\x04'.codeUnits)), isFalse);
      }
    });

    test('txt: нет нулевых байтов', () {
      expect(looksLikeMime('text/plain', _b('привет'.codeUnits)), isTrue);
      expect(looksLikeMime('text/plain', _b([65, 0, 66])), isFalse);
      expect(looksLikeMime('text/plain', _b(const [])), isTrue);
      // Нулевой байт после первого килобайта клиентом не проверяется.
      final big = Uint8List(2000)..fillRange(0, 2000, 65);
      big[1500] = 0;
      expect(looksLikeMime('text/plain', big), isTrue);
    });

    test('docx, xlsx, pptx, zip: PK-заголовок', () {
      for (final mime in [
        'application/zip',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      ]) {
        expect(looksLikeMime(mime, _b([0x50, 0x4B, 0x03, 0x04, 1])), isTrue);
        expect(looksLikeMime(mime, _b([0x50, 0x4B, 0x05, 0x06])), isTrue);
        expect(looksLikeMime(mime, _b([0x50, 0x4B, 0x01, 0x02])), isFalse);
        expect(looksLikeMime(mime, _b('%PDF-1'.codeUnits)), isFalse);
      }
    });
  });
}
