import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/jpeg.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/meta.dart';

import 'sample_support.dart';

Uint8List _trailerOf(String sample) {
  final data = readSample(sample);
  return data.sublist(bodyEnd(data));
}

void main() {
  group('constants and camera names', () {
    test('fixed lengths and paths match the camera', () {
      expect(nameLength, 27);
      expect(serialLength, 14);
      expect(uidLength, 32);
      expect(blobOffsetFallback, 431);
      expect(fileInfoListPath, 'DCIM/fileinfo_list.list');
      expect(editInfoListPath, 'DCIM/.editinfo_list.list');
      expect(cameraDir, 'DCIM/Camera01');
      expect(cameraNamePattern.hasMatch('IMG_20261101_085513_004.jpg'), isTrue);
      expect(cameraNamePattern.hasMatch('IMG_20261101_085513_04.jpg'), isFalse);
      expect(
        serialPattern.firstMatch('xIBEEA26045GQ9By')!.group(0),
        'IBEEA26045GQ9B',
      );
      expect(uidPattern.hasMatch('8db42d694ccc418790edff439fe026bf'), isTrue);
      expect(uidPattern.hasMatch('8DB42D694CCC418790EDFF439FE026BF'), isFalse);
    });

    test('cameraFileName is always 27 characters', () {
      final dt = DateTime(2026, 11, 1, 8, 55, 13);
      expect(cameraFileName(dt, 4), 'IMG_20261101_085513_004.jpg');
      expect(cameraFileName(dt, 1).length, 27);
      expect(cameraNamePattern.hasMatch(cameraFileName(dt, 42)), isTrue);
      final match = cameraNamePattern.firstMatch(cameraFileName(dt, 42))!;
      expect(match.group(1), '20261101');
      expect(match.group(2), '085513');
      expect(match.group(3), '042');
      expect(() => cameraFileName(dt, 1000), throwsRangeError);
      expect(() => cameraFileName(dt, -1), throwsRangeError);
    });
  });

  group('protobuf varints', () {
    test('encodes and decodes ordinary values', () {
      for (final value in [0, 1, 127, 128, 300, 20261101085513, 3322996]) {
        final encoded = encodeVarint(value);
        final decoded = readVarint(encoded, 0);
        expect(decoded.value, value, reason: 'value $value');
        expect(decoded.next, encoded.length);
      }
      expect(encodeVarint(0), [0]);
      expect(encodeVarint(1), [1]);
      expect(encodeVarint(300), [0xAC, 0x02]);
    });

    test('pads with redundant zero groups without changing the value', () {
      expect(encodeVarint(1, padTo: 3), [0x81, 0x80, 0x00]);
      expect(encodeVarint(300, padTo: 3), [0xAC, 0x82, 0x00]);
      final encoded = encodeVarint(20261101085513, padTo: 7);
      expect(encoded.length, 7);
      expect(readVarint(encoded, 0).value, 20261101085513);
    });

    test('reads from a non-zero offset', () {
      final buf = Uint8List.fromList([0xAA, 0xAC, 0x02, 0xBB]);
      final decoded = readVarint(buf, 1);
      expect(decoded.value, 300);
      expect(decoded.next, 3);
    });

    test('throws on overflow, negatives, truncation and bad offsets', () {
      expect(() => encodeVarint(128, padTo: 1), throwsArgumentError);
      expect(() => encodeVarint(-1), throwsArgumentError);
      expect(
        () => readVarint(Uint8List.fromList([0x80]), 0),
        throwsFormatException,
      );
      expect(() => readVarint(Uint8List(0), 0), throwsFormatException);
      expect(
        () => readVarint(Uint8List.fromList([0]), -1),
        throwsFormatException,
      );
      expect(
        () => readVarint(Uint8List.fromList([0]), 5),
        throwsFormatException,
      );
    });
  });

  group('trailer metadata', () {
    test('reads serial, uid, capture time and blob fields', () {
      final trailer = _trailerOf(sample004);
      expect(trailer.length, 576170);
      expect(serialOf(trailer), 'IBEEA26045GQ9B');
      expect(uidOf(trailer), '8db42d694ccc418790edff439fe026bf');
      expect(captureTime(trailer), DateTime(2026, 11, 1, 8, 55, 13));

      final info = metaInfo(trailer);
      expect(info, isNotNull);
      expect(info!.serial, 'IBEEA26045GQ9B');
      expect(info.blobOffset, 431);
      expect(info.blobLength, 1151);
      expect(info.fileOffset, 3322996);
      expect(info.timestamp, 20261101085513);
      // The camera's field 26 is itself a nested protobuf; the Python tool
      // NUL-trims the raw bytes, which yields these three control bytes.
      expect(info.path, String.fromCharCodes([8, 3, 16]));
    }, skip: missingSamplesReason);

    test('works with an explicit serial and reports null without one', () {
      final trailer = _trailerOf(sample004);
      final bySerial = metaInfo(trailer, serial: 'IBEEA26045GQ9B');
      expect(bySerial!.blobOffset, 431);
      expect(metaInfo(trailer, serial: 'IBNOTAREALSERIAL'), isNull);
      expect(metaInfo(Uint8List(0)), isNull);
      expect(serialOf(Uint8List(0)), isNull);
      expect(uidOf(Uint8List(0)), isNull);
      expect(captureTime(Uint8List(0)), isNull);
    }, skip: missingSamplesReason);

    test('locates the raw NV21 bulk buffer', () {
      final trailer = _trailerOf(sample004);
      final bulk = bulkInfo(trailer);
      expect(bulk, isNotNull);
      expect(bulk!.offset, 1628);
      expect(bulk.width, 704);
      expect(bulk.height, 544);
      expect(bulk.length, 574504);
      expect(bulk.size, 704 * 544 * 3 ~/ 2);
      expect(bulkInfo(trailer.sublist(0, 431 + 1151 + 20)), isNull);
      expect(bulkInfo(Uint8List(0)), isNull);
    }, skip: missingSamplesReason);

    test('fields 9 and 7 patch in place with a stable length', () {
      final trailer = _trailerOf(sample004);
      final patched = patchMeta(
        trailer,
        fileOffset: 123456,
        capture: DateTime(2027, 2, 3, 4, 5, 6),
      );

      expect(patched.length, trailer.length);
      final info = metaInfo(patched)!;
      expect(info.blobOffset, 431);
      expect(info.blobLength, 1151);
      expect(info.fileOffset, 123456);
      expect(info.timestamp, 20270203040506);
      expect(captureTime(patched), DateTime(2027, 2, 3, 4, 5, 6));

      // Only the two values may move: 547 is field 7's key, 555 field 9's.
      expect(patched.sublist(0, 547), trailer.sublist(0, 547));
      expect(patched.sublist(560), trailer.sublist(560));
      expect(patched[547], trailer[547]);
      expect(patched[555], trailer[555]);

      expect(
        () => patchMeta(
          trailer,
          fileOffset: 1 << 40,
          capture: DateTime(2027, 2, 3, 4, 5, 6),
        ),
        throwsFormatException,
      );
      expect(
        () => patchMeta(
          Uint8List.fromList(const [1, 2, 3]),
          fileOffset: 0,
          capture: DateTime(2027, 2, 3, 4, 5, 6),
        ),
        throwsFormatException,
      );
    }, skip: missingSamplesReason);
  });

  group('patchPath', () {
    test('replaces exactly the 27-character name', () {
      final trailer = _trailerOf(sample004);
      expect(
        String.fromCharCodes(trailer.sublist(624, 639)),
        '/DCIM/Camera01/',
      );
      expect(
        String.fromCharCodes(trailer.sublist(639, 666)),
        'IMG_20261101_085513_004.jpg',
      );

      const filename = 'IMG_20270102_030405_006.jpg';
      final patched = patchPath(trailer, filename);
      expect(patched.length, trailer.length);
      expect(
        String.fromCharCodes(patched.sublist(624, 666)),
        '/DCIM/Camera01/$filename',
      );
      expect(patched.sublist(0, 639), trailer.sublist(0, 639));
      expect(patched.sublist(666), trailer.sublist(666));
      final text = latin1.decode(patched);
      expect(text.contains('/DCIM/Camera01/$filename'), isTrue);
    }, skip: missingSamplesReason);

    test('rejects the wrong name length and leaves unmatched data alone', () {
      final trailer = _trailerOf(sample004);
      expect(() => patchPath(trailer, 'too-short.jpg'), throwsArgumentError);

      final noPath = Uint8List.fromList(const [1, 2, 3, 4, 5]);
      expect(patchPath(noPath, 'IMG_20270102_030405_006.jpg'), same(noPath));

      const wrongName = 'not-a-camera-name-here-1234';
      expect(wrongName.length, 27);
      final notCamera = Uint8List.fromList(
        '/DCIM/Camera01/$wrongName'.codeUnits,
      );
      expect(
        patchPath(notCamera, 'IMG_20270102_030405_006.jpg'),
        same(notCamera),
      );
    }, skip: missingSamplesReason);
  });

  group('patchBulk', () {
    test('replaces only the NV21 range', () {
      final trailer = _trailerOf(sample004);
      final bulk = bulkInfo(trailer)!;
      final replacement = Uint8List(bulk.size);
      for (var i = 0; i < replacement.length; i++) {
        replacement[i] = (i * 31) & 0xFF;
      }

      final patched = patchBulk(trailer, bulk, replacement);
      expect(patched.length, trailer.length);
      expect(
        patched.sublist(bulk.offset, bulk.offset + bulk.size),
        replacement,
      );
      expect(
        checksum(patched.sublist(0, bulk.offset)),
        checksum(trailer.sublist(0, bulk.offset)),
      );
      final tailStart = bulk.offset + bulk.size;
      expect(
        checksum(patched.sublist(tailStart)),
        checksum(trailer.sublist(tailStart)),
      );
      expect(tailStart, 576092);
      expect(
        () => patchBulk(trailer, bulk, replacement.sublist(1)),
        throwsArgumentError,
      );
    }, skip: missingSamplesReason);
  });

  group('camera index records', () {
    test('parses fileinfo_list.list', () {
      final data = readSample(fileInfoList);
      final records = indexRecords(data);
      expect(records.length, 5);
      expect(records.map((record) => record.raw.length), [
        1201,
        1297,
        1201,
        1201,
        1201,
      ]);
      expect(records.first.path, '/DCIM/Camera01/IMG_20150715_191431_001.jpg');
      expect(records.first.blob.length, 1151);
      expect(joinBytes(records.map((record) => record.raw).toList()), data);
      for (final record in records) {
        expect(
          buildIndexRecord(record.path, record.blob),
          record.raw,
          reason: 'record ${record.path} should rebuild byte for byte',
        );
      }
    }, skip: missingSamplesReason);

    test('parses .editinfo_list.list', () {
      final data = readSample(editInfoList);
      final records = indexRecords(data);
      expect(records.length, 5);
      expect(records.map((record) => record.raw.length), [48, 48, 50, 50, 50]);
      expect(records.map((record) => record.blob.length), [0, 0, 2, 2, 2]);
      expect(records.first.path, '/DCIM/Camera01/IMG_20150715_191431_001.jpg');
      for (final record in records.where((record) => record.blob.isEmpty)) {
        expect(
          buildEditRecord(record.path),
          record.raw,
          reason: 'edit record ${record.path} should rebuild byte for byte',
        );
      }
    }, skip: missingSamplesReason);

    test('builds an index record from scratch', () {
      const path = '/DCIM/Camera01/IMG_20270101_010101_001.jpg';
      final blob = Uint8List.fromList(List<int>.generate(300, (i) => i & 0xFF));
      final record = buildIndexRecord(path, blob);
      final parsed = indexRecords(record);
      expect(parsed.length, 1);
      expect(parsed.single.path, path);
      expect(parsed.single.blob, blob);
      expect(parsed.single.raw, record);
      expect(record.length, 350);
    });

    test('builds an edit record from scratch', () {
      const path = '/DCIM/Camera01/IMG_20270101_010101_001.jpg';
      final record = buildEditRecord(path);
      expect(record.length, 48);
      final parsed = indexRecords(record).single;
      expect(parsed.path, path);
      expect(parsed.blob, isEmpty);
      expect(parsed.raw, record);
    });

    test('upsert replaces a path and supports prepend order', () {
      const pathA = '/DCIM/Camera01/IMG_20270101_010101_001.jpg';
      const pathB = '/DCIM/Camera01/IMG_20270101_020202_002.jpg';
      const pathC = '/DCIM/Camera01/IMG_20270101_030303_003.jpg';
      final data = joinBytes([
        buildIndexRecord(pathA, Uint8List.fromList(const [1])),
        buildIndexRecord(pathB, Uint8List.fromList(const [2])),
        buildIndexRecord(pathC, Uint8List.fromList(const [3])),
      ]);
      final replacement = buildIndexRecord(
        pathB,
        Uint8List.fromList(const [9, 9]),
      );

      final prepended = upsertRecords(data, pathB, replacement, prepend: true);
      final prependedRecords = indexRecords(prepended);
      expect(prependedRecords.map((record) => record.path), [
        pathB,
        pathA,
        pathC,
      ]);
      expect(prependedRecords.first.blob, [9, 9]);
      expect(prepended.sublist(0, replacement.length), replacement);

      final appended = upsertRecords(data, pathB, replacement);
      expect(indexRecords(appended).map((record) => record.path), [
        pathA,
        pathC,
        pathB,
      ]);

      expect(indexRecords(dropRecords(data, pathB)).map((r) => r.path), [
        pathA,
        pathC,
      ]);
    });

    test('round-trips an upsert against the real index', () {
      final data = readSample(fileInfoList);
      final records = indexRecords(data);
      final first = records.first;
      final replacement = buildIndexRecord(first.path, records.last.blob);
      final updated = upsertRecords(
        data,
        first.path,
        replacement,
        prepend: true,
      );
      final after = indexRecords(updated);
      expect(after.length, records.length);
      expect(after.first.path, first.path);
      expect(after.first.blob, records.last.blob);
      expect(
        after.skip(1).map((record) => record.raw),
        records.skip(1).map((record) => record.raw),
      );
      expect(indexRecords(dropRecords(updated, first.path)).length, 4);
    }, skip: missingSamplesReason);

    test('returns empty on malformed index data', () {
      expect(indexRecords(Uint8List(0)), isEmpty);
      expect(indexRecords(Uint8List.fromList(const [0x12, 0x00])), isEmpty);
      expect(indexRecords(Uint8List.fromList(const [0x0A])), isEmpty);
      expect(
        indexRecords(Uint8List.fromList(const [0x0A, 0x10, 1, 2])),
        isEmpty,
      );
    });
  });
}
