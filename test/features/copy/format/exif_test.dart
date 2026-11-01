import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/exif.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/jpeg.dart';

import 'sample_support.dart';

const List<int> _exifPrefix = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

Uint8List _app1Of(String sample) {
  final layout = splitMarkers(readSample(sample));
  return layout.segments
      .firstWhere((segment) => segment.marker == 0xE1)
      .payload;
}

int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return i;
    }
  }
  return -1;
}

/// A minimal big-endian TIFF with IFD0, an Exif sub-IFD and local strings.
///
/// Layout: header (8), IFD0 (54), Exif IFD (54), 5 value blocks (108) = 224.
Uint8List _bigEndianTiff() {
  final data = Uint8List(224);

  void u16(int offset, int value) {
    data[offset] = (value >> 8) & 0xFF;
    data[offset + 1] = value & 0xFF;
  }

  void u32(int offset, int value) {
    data[offset] = (value >> 24) & 0xFF;
    data[offset + 1] = (value >> 16) & 0xFF;
    data[offset + 2] = (value >> 8) & 0xFF;
    data[offset + 3] = value & 0xFF;
  }

  void entry(int slot, int tag, int type, int count, int value) {
    u16(slot, tag);
    u16(slot + 2, type);
    u32(slot + 4, count);
    u32(slot + 8, value);
  }

  void text(int offset, String value, int count) {
    final bytes = [...value.codeUnits, 0];
    if (bytes.length > count) {
      throw ArgumentError('string does not fit');
    }
    data.setRange(offset, offset + count, [
      ...bytes,
      ...List<int>.filled(count - bytes.length, 0),
    ]);
  }

  data[0] = 0x4D; // "MM"
  data[1] = 0x4D;
  u16(2, 0x002A);
  u32(4, 8);

  // IFD0 at 8: description, model, DateTime and Exif IFD pointer.
  u16(8, 4);
  entry(10, tagImageDescription, 2, 28, 116);
  entry(22, tagModel, 2, 20, 144);
  entry(34, tagDateTime, 2, 20, 164);
  entry(46, tagExifIfd, 4, 1, 62);
  u32(58, 0);

  // Exif IFD at 62: DateTimeOriginal/Digitized and inline pixel dimensions.
  u16(62, 4);
  entry(64, tagDateTimeOriginal, 2, 20, 184);
  entry(76, tagDateTimeDigitized, 2, 20, 204);
  entry(88, tagPixelX, 4, 1, 3000);
  entry(100, tagPixelY, 4, 1, 2000);
  u32(112, 0);

  text(116, 'IMG_20250101_010101_001.jpg', 28);
  text(144, 'Insta360 GO Ultra', 20);
  text(164, '2026:11:01 08:55:14', 20);
  text(184, '2025:12:31 23:59:58', 20);
  text(204, '2025:12:31 23:59:59', 20);
  return data;
}

void main() {
  group('readExifSummary', () {
    test('reads the reportable tags of sample 004', () {
      final summary = readExifSummary(_app1Of(sample004));
      expect(summary, isNotNull);
      expect(summary!.imageDescription, 'IMG_20261101_085513_004.jpg');
      expect(summary.make, 'Arashi Vision');
      expect(summary.model, 'Insta360 GO Ultra');
      expect(summary.software, 'v1.9.29_build1');
      expect(summary.dateTime, '2026:11:01 08:55:14');
      expect(summary.dateTimeOriginal, '2026:11:01 08:55:14');
      expect(summary.pixelXDimension, 4096);
      expect(summary.pixelYDimension, 3072);
    }, skip: missingSamplesReason);

    test('returns null for absent, non-EXIF and malformed blocks', () {
      expect(readExifSummary(null), isNull);
      expect(
        readExifSummary(
          Uint8List.fromList(const [0x4A, 0x46, 0x49, 0x46, 0, 1, 2]),
        ),
        isNull,
      );
      expect(
        readExifSummary(
          Uint8List.fromList([
            ..._exifPrefix,
            0x49,
            0x49, // truncated TIFF header
          ]),
        ),
        isNull,
      );
    });

    test('reads a big-endian TIFF with correct pixel dimensions', () {
      final summary = readExifSummary(
        Uint8List.fromList([..._exifPrefix, ..._bigEndianTiff()]),
      );
      expect(summary, isNotNull);
      expect(summary!.imageDescription, 'IMG_20250101_010101_001.jpg');
      expect(summary.make, isNull);
      expect(summary.model, 'Insta360 GO Ultra');
      expect(summary.dateTime, '2026:11:01 08:55:14');
      expect(summary.dateTimeOriginal, '2025:12:31 23:59:58');
      // Python always reads pixel dimensions little-endian; a correct parser
      // must honour the TIFF byte order.
      expect(summary.pixelXDimension, 3000);
      expect(summary.pixelYDimension, 2000);
    });
  });

  group('extractExifThumbnail', () {
    test('finds the embedded JPEG and its SOF dimensions', () {
      final app1 = _app1Of(sample004);
      final thumbnail = extractExifThumbnail(app1);
      expect(thumbnail, isNotNull);
      expect(thumbnail!.width, 160);
      expect(thumbnail.height, 120);
      expect(thumbnail.offset, 2036);
      expect(thumbnail.length, 9386);
      expect(thumbnail.jpeg.sublist(0, 2), [0xFF, 0xD8]);
      expect(thumbnail.offset + thumbnail.length, app1.length - 6);

      final size = jpegDimensions(thumbnail.jpeg);
      expect(size.width, 160);
      expect(size.height, 120);
    }, skip: missingSamplesReason);

    test('reads a 16:9 camera thumbnail', () {
      final thumbnail = extractExifThumbnail(_app1Of(sample002));
      expect(thumbnail, isNotNull);
      expect(thumbnail!.width, 160);
      expect(thumbnail.height, 96);
      expect(thumbnail.length, 6365);
    }, skip: missingSamplesReason);

    test('returns null without IFD1 or EXIF', () {
      // Header + empty IFD0 + next-IFD offset 0.
      final emptyTiff = Uint8List.fromList(const [
        0x49, 0x49, 0x2A, 0x00, // "II", 42
        0x08, 0x00, 0x00, 0x00, // IFD0 at 8
        0x00, 0x00, // zero entries
        0x00, 0x00, 0x00, 0x00, // no IFD1
      ]);
      expect(
        extractExifThumbnail(
          Uint8List.fromList([..._exifPrefix, ...emptyTiff]),
        ),
        isNull,
      );
      expect(extractExifThumbnail(Uint8List.fromList(const [1, 2, 3])), isNull);
    });
  });

  group('patchExif', () {
    test('rewrites the photo fields and replaces a trailing thumbnail', () {
      final app1 = _app1Of(sample004);
      final original = extractExifThumbnail(app1)!;
      final replacement = extractExifThumbnail(_app1Of(sample002))!;
      expect(replacement.jpeg.length, isNot(original.jpeg.length));

      const filename = 'IMG_20270203_040506_007.jpg';
      final patched = patchExif(
        app1,
        filename: filename,
        dateTime: DateTime(2027, 2, 3, 4, 5, 6),
        width: 3072,
        height: 4096,
        thumbnail: replacement.jpeg,
      );

      expect(patched.sublist(0, 6), _exifPrefix);
      final summary = readExifSummary(patched)!;
      expect(summary.imageDescription, filename);
      expect(summary.make, 'Arashi Vision');
      expect(summary.model, 'Insta360 GO Ultra');
      expect(summary.software, 'v1.9.29_build1');
      expect(summary.dateTime, '2027:02:03 04:05:06');
      expect(summary.dateTimeOriginal, '2027:02:03 04:05:06');
      expect(summary.pixelXDimension, 3072);
      expect(summary.pixelYDimension, 4096);

      // The MakerNote is opaque payload and must survive byte for byte.
      final makerNote = _indexOf(patched, 'ABMA'.codeUnits);
      expect(makerNote, greaterThan(0));
      expect(
        patched.sublist(makerNote, makerNote + 320),
        app1.sublist(makerNote, makerNote + 320),
      );

      final tiff = Tiff(Uint8List.sublistView(patched, 6));
      final ifd0 = tiff.readIfd(tiff.u32(4));
      final ifd1 = tiff.readIfd(ifd0.nextOffset).entries;
      expect(tiff.getLong(ifd1, tagThumbLength), replacement.jpeg.length);
      expect(tiff.data.length, original.offset + replacement.jpeg.length);

      final extracted = extractExifThumbnail(patched)!;
      expect(extracted.jpeg, replacement.jpeg);
      expect(extracted.width, 160);
      expect(extracted.height, 96);
    }, skip: missingSamplesReason);

    test('keeps the original thumbnail when none is supplied', () {
      final app1 = _app1Of(sample004);
      final original = extractExifThumbnail(app1)!;

      final patched = patchExif(
        app1,
        filename: 'IMG_20270203_040506_007.jpg',
        dateTime: DateTime(2027, 2, 3, 4, 5, 6),
        width: 1234,
        height: 5678,
      );
      final extracted = extractExifThumbnail(patched)!;
      expect(extracted.jpeg, original.jpeg);
      expect(extracted.length, original.length);
      expect(readExifSummary(patched)!.pixelXDimension, 1234);
      expect(readExifSummary(patched)!.pixelYDimension, 5678);
    }, skip: missingSamplesReason);

    test('keeps a non-trailing thumbnail rather than corrupting offsets', () {
      final app1 = _app1Of(sample004);
      final original = extractExifThumbnail(app1)!;
      final replacement = extractExifThumbnail(_app1Of(sample002))!;
      final withTrailingByte = Uint8List.fromList([...app1, 0xAA, 0xBB]);

      final patched = patchExif(
        withTrailingByte,
        filename: 'IMG_20270203_040506_007.jpg',
        dateTime: DateTime(2027, 2, 3, 4, 5, 6),
        width: 3072,
        height: 4096,
        thumbnail: replacement.jpeg,
      );
      final extracted = extractExifThumbnail(patched)!;
      expect(extracted.jpeg, original.jpeg);
      expect(extracted.length, original.length);
      expect(
        readExifSummary(patched)!.imageDescription,
        'IMG_20270203_040506_007.jpg',
      );
    }, skip: missingSamplesReason);

    test('returns non-EXIF input unchanged', () {
      final notExif = Uint8List.fromList(const [1, 2, 3, 4, 5]);
      final result = patchExif(
        notExif,
        filename: 'IMG_20270203_040506_007.jpg',
        dateTime: DateTime(2027, 2, 3, 4, 5, 6),
        width: 1,
        height: 2,
      );
      expect(result, same(notExif));
    });

    test('patches a big-endian TIFF and writes big-endian LONGs', () {
      final app1 = Uint8List.fromList([..._exifPrefix, ..._bigEndianTiff()]);
      final patched = patchExif(
        app1,
        filename: 'IMG_20270102_030405_006.jpg',
        dateTime: DateTime(2027, 1, 2, 3, 4, 5),
        width: 640,
        height: 480,
      );

      final summary = readExifSummary(patched)!;
      expect(summary.imageDescription, 'IMG_20270102_030405_006.jpg');
      expect(summary.dateTime, '2027:01:02 03:04:05');
      expect(summary.dateTimeOriginal, '2027:01:02 03:04:05');
      expect(summary.pixelXDimension, 640);
      expect(summary.pixelYDimension, 480);

      final tiff = Tiff(Uint8List.sublistView(patched, 6));
      final exif = tiff.exifIfd();
      expect(tiff.getLong(exif, tagPixelX), 640);
      expect(tiff.raw(exif[tagPixelX]!), [0x00, 0x00, 0x02, 0x80]);
      expect(tiff.raw(exif[tagPixelY]!), [0x00, 0x00, 0x01, 0xE0]);
    });

    test('throws on a truncated EXIF block', () {
      final truncated = Uint8List.fromList([
        ..._exifPrefix,
        0x49,
        0x49,
        0x2A,
        0x00,
        0x08,
        0x00,
        0x00,
        0x00,
      ]);
      expect(
        () => patchExif(
          truncated,
          filename: 'IMG_20270203_040506_007.jpg',
          dateTime: DateTime(2027, 2, 3, 4, 5, 6),
          width: 1,
          height: 2,
        ),
        throwsFormatException,
      );
    });
  });
}
