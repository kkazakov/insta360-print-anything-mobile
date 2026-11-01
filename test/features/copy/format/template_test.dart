import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/exif.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/jpeg.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/meta.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/template.dart';

import 'sample_support.dart';

CameraTemplate _template({
  required int width,
  required int height,
  String fileName = 'IMG_20261101_085513_004.jpg',
  List<int> trailer = const [1, 2, 3],
  String? model = 'Insta360 GO Ultra',
  DateTime? captured,
}) {
  return CameraTemplate(
    fileName: fileName,
    width: width,
    height: height,
    segments: const [],
    app1: null,
    preview: null,
    previewWidth: null,
    previewHeight: null,
    thumbnail: null,
    thumbnailWidth: null,
    thumbnailHeight: null,
    qtables: const [],
    dqtPayload: null,
    trailer: Uint8List.fromList(trailer),
    model: model,
    serial: null,
    uid: null,
    firmware: null,
    captured: captured,
  );
}

void main() {
  group('analyseTemplate on real photos', () {
    test('decomposes sample 004 into the clone parts', () {
      final data = readSample(sample004);
      final template = analyseTemplate(data, fileName: sample004);

      expect(template.fileName, sample004);
      expect(template.width, 4096);
      expect(template.height, 3072);
      expect(template.segments.map((segment) => segment.marker), [
        0xE1,
        0xE2,
        0xE2,
        0xE2,
        0xDB,
        0xC0,
        0xC4,
      ]);

      expect(template.app1, isNotNull);
      expect(template.app1!.length, 11428);
      expect(template.app1!.sublist(0, 4), 'Exif'.codeUnits);

      expect(template.preview, isNotNull);
      expect(template.previewWidth, 704);
      expect(template.previewHeight, 544);

      expect(template.thumbnail, isNotNull);
      expect(template.thumbnailWidth, 160);
      expect(template.thumbnailHeight, 120);

      expect(template.qtables.length, 2);
      expect(template.qtables[0].take(8), [2, 1, 14, 15, 16, 16, 3, 15]);
      expect(template.qtables[1].take(8), [2, 2, 10, 10, 10, 10, 10, 10]);
      expect(template.dqtPayload, isNotNull);
      expect(template.dqtPayload!.length, 130);

      expect(template.trailer.length, 576170);
      expect(template.trailer, data.sublist(bodyEnd(data)));
      expect(template.model, 'Insta360 GO Ultra');
      expect(template.serial, 'IBEEA26045GQ9B');
      expect(template.uid, '8db42d694ccc418790edff439fe026bf');
      expect(template.firmware, 'v1.9.29_build1');
      expect(template.captured, DateTime(2026, 11, 1, 8, 55, 13));
      expect(template.isCameraPhoto, isTrue);
      expect(template.aspect, closeTo(4096 / 3072, 1e-12));
    }, skip: missingSamplesReason);

    test('decomposes the 16:9 sample 002', () {
      final template = analyseTemplate(
        readSample(sample002),
        fileName: sample002,
      );
      expect(template.width, 8192);
      expect(template.height, 4608);
      expect(template.previewWidth, 704);
      expect(template.previewHeight, 416);
      expect(template.thumbnailWidth, 160);
      expect(template.thumbnailHeight, 96);
      expect(template.captured, DateTime(2026, 11, 1, 8, 54, 40));
      expect(template.aspect, closeTo(16 / 9, 1e-12));
      expect(template.isCameraPhoto, isTrue);
      expect(
        template.segments.any((segment) => segment.marker == 0xDD),
        isTrue,
      );
    }, skip: missingSamplesReason);

    test('an assembled clone round-trips through analyseTemplate', () {
      final data = readSample(sample004);
      final layout = splitMarkers(data);
      final app1 = layout.segments
          .firstWhere((segment) => segment.marker == 0xE1)
          .payload;
      final preview = embeddedPreview(data)!;
      final originalTrailer = data.sublist(bodyEnd(data));
      final replacementThumbnail = extractExifThumbnail(
        splitMarkers(readSample(sample002)).segments
            .firstWhere((segment) => segment.marker == 0xE1)
            .payload,
      )!;

      const filename = 'IMG_20270203_040506_007.jpg';
      final dt = DateTime(2027, 2, 3, 4, 5, 6);
      final newApp1 = patchExif(
        app1,
        filename: filename,
        dateTime: dt,
        width: 4096,
        height: 3072,
        thumbnail: replacementThumbnail.jpeg,
      );
      final body = rebuildJpeg(
        encoded: data,
        app1: newApp1,
        app2Chunks: chunkApp2(preview),
      );
      var trailer = patchPath(originalTrailer, filename);
      trailer = patchMeta(
        trailer,
        serial: serialOf(trailer),
        fileOffset: body.length + blobOffsetFallback,
        capture: dt,
      );
      final output = joinBytes([body, trailer]);

      final template = analyseTemplate(output, fileName: filename);
      expect(template.width, 4096);
      expect(template.height, 3072);
      expect(template.isCameraPhoto, isTrue);
      expect(template.model, 'Insta360 GO Ultra');
      expect(template.serial, 'IBEEA26045GQ9B');
      expect(template.uid, '8db42d694ccc418790edff439fe026bf');
      expect(template.firmware, 'v1.9.29_build1');
      expect(template.captured, dt);
      expect(template.thumbnailWidth, 160);
      expect(template.thumbnailHeight, 96);
      expect(template.previewWidth, 704);
      expect(template.previewHeight, 544);

      final summary = readExifSummary(template.app1)!;
      expect(summary.imageDescription, filename);
      expect(summary.dateTimeOriginal, '2027:02:03 04:05:06');
      expect(summary.pixelXDimension, 4096);
      expect(summary.pixelYDimension, 3072);

      final info = metaInfo(template.trailer)!;
      expect(info.fileOffset, body.length + blobOffsetFallback);
      expect(info.timestamp, 20270203040506);
      expect(captureTime(template.trailer), dt);
    }, skip: missingSamplesReason);
  });

  group('analyseTemplate on synthetic input', () {
    test('handles a plain non-camera JPEG', () {
      final values = List<int>.generate(64, (i) => 1 + (i % 5));
      final data = buildJpeg(dqt: simpleDqt(0, values), width: 32, height: 24);
      final template = analyseTemplate(data, fileName: 'plain.jpg');

      expect(template.width, 32);
      expect(template.height, 24);
      expect(template.app1, isNull);
      expect(template.preview, isNull);
      expect(template.previewWidth, isNull);
      expect(template.previewHeight, isNull);
      expect(template.thumbnail, isNull);
      expect(template.thumbnailWidth, isNull);
      expect(template.thumbnailHeight, isNull);
      expect(template.qtables.single, zigzagToNatural(values));
      expect(template.dqtPayload, isNotNull);
      expect(template.trailer, isEmpty);
      expect(template.model, isNull);
      expect(template.serial, isNull);
      expect(template.uid, isNull);
      expect(template.firmware, isNull);
      expect(template.captured, isNull);
      expect(template.isCameraPhoto, isFalse);
      expect(template.aspect, closeTo(32 / 24, 1e-12));
    });

    test('ignores a non-EXIF APP1', () {
      final data = buildJpeg(
        app1: const [
          [0x4A, 0x46, 0x49, 0x46],
        ],
      );
      final template = analyseTemplate(data, fileName: 'jfif.jpg');
      expect(template.app1, isNull);
      expect(template.qtables, isEmpty);
      expect(template.dqtPayload, isNull);
    });

    test('throws on corrupt input', () {
      expect(
        () => analyseTemplate(
          Uint8List.fromList(const [0, 1, 2]),
          fileName: 'bad.jpg',
        ),
        throwsFormatException,
      );
    });
  });

  group('CameraTemplate helpers', () {
    test('isCameraPhoto needs a trailer and an Insta360 model', () {
      expect(_template(width: 4, height: 3).isCameraPhoto, isTrue);
      expect(
        _template(width: 4, height: 3, trailer: const []).isCameraPhoto,
        isFalse,
      );
      expect(
        _template(width: 4, height: 3, model: 'Some Phone').isCameraPhoto,
        isFalse,
      );
      expect(
        _template(width: 4, height: 3, model: null).isCameraPhoto,
        isFalse,
      );
    });

    test('aspect returns zero for a degenerate size', () {
      expect(_template(width: 4, height: 3).aspect, closeTo(4 / 3, 1e-12));
      expect(_template(width: 4, height: 0).aspect, 0.0);
    });
  });

  group('pickTemplate', () {
    test('prefers the smaller mode when the aspect matches', () {
      final large = _template(width: 8192, height: 4608);
      final small = _template(width: 4096, height: 3072);
      expect(
        pickTemplate([large, small], wantWidth: 4096, wantHeight: 3072),
        same(small),
      );
    });

    test('prefers the closer aspect ratio over size', () {
      final small4x3 = _template(width: 4096, height: 3072);
      final wide = _template(width: 8192, height: 4608);
      expect(
        pickTemplate([small4x3, wide], wantWidth: 1920, wantHeight: 1080),
        same(wide),
      );
      expect(
        pickTemplate([wide, small4x3], wantWidth: 1024, wantHeight: 768),
        same(small4x3),
      );
    });

    test('penalises a template without trailer metadata', () {
      final withoutTrailer = _template(
        width: 4096,
        height: 3072,
        trailer: const [],
      );
      final withTrailer = _template(width: 4096, height: 3072);
      expect(
        pickTemplate(
          [withoutTrailer, withTrailer],
          wantWidth: 4096,
          wantHeight: 3072,
        ),
        same(withTrailer),
      );
    });

    test('penalises a capture time inconsistent with the file name', () {
      final captured = DateTime(2026, 11, 1, 8, 55, 13);
      final inconsistent = _template(
        width: 4096,
        height: 3072,
        fileName: 'IMG_20200101_000000_001.jpg',
        captured: captured,
      );
      final consistent = _template(
        width: 4096,
        height: 3072,
        captured: captured,
      );
      expect(
        pickTemplate(
          [inconsistent, consistent],
          wantWidth: 4096,
          wantHeight: 3072,
        ),
        same(consistent),
      );
    });

    test('throws on an empty list and tolerates a zero-height request', () {
      expect(
        () => pickTemplate(const [], wantWidth: 100, wantHeight: 100),
        throwsArgumentError,
      );
      final only = _template(width: 4096, height: 3072);
      expect(pickTemplate([only], wantWidth: 100, wantHeight: 0), same(only));
    });
  });
}
