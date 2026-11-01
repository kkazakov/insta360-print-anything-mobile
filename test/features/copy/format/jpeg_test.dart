import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/jpeg.dart';

import 'sample_support.dart';

void main() {
  group('splitMarkers', () {
    test('splits segments up to SOS and reports the scan offset', () {
      final data = joinBytes([
        const [0xFF, 0xD8],
        markerSegment(0xE1, const [1, 2, 3]),
        markerSegment(0xE0, const [9, 8]),
        markerSegment(0xDA, const [1, 0, 1, 0]),
        const [0x12, 0x34, 0xFF, 0xD9],
      ]);

      final layout = splitMarkers(data);
      expect(layout.segments.map((s) => s.marker), [0xE1, 0xE0]);
      expect(layout.segments[0].payload, [1, 2, 3]);
      expect(layout.segments[1].payload, [9, 8]);
      // SOI + APP1 (4+3) + APP0 (4+2)
      expect(layout.scanStart, 2 + 7 + 6);
    });

    test('skips stray SOI, fill bytes and restart markers', () {
      final data = joinBytes([
        const [0xFF, 0xD8],
        const [0xFF, 0xD8],
        const [0xFF, 0x00],
        const [0xFF, 0xD0],
        markerSegment(0xE2, const [7]),
        markerSegment(0xDA, const [0, 0]),
      ]);

      final layout = splitMarkers(data);
      expect(layout.segments.single.marker, 0xE2);
      expect(layout.segments.single.payload, [7]);
    });

    test('rejects a non-JPEG and corrupt or truncated markers', () {
      expect(() => splitMarkers(Uint8List(0)), throwsFormatException);
      expect(
        () => splitMarkers(Uint8List.fromList(const [0, 0, 0, 0])),
        throwsFormatException,
      );
      expect(
        () => splitMarkers(
          Uint8List.fromList(const [0xFF, 0xD8, 0x00, 0x00, 0x00, 0x00]),
        ),
        throwsFormatException,
      );
      expect(
        () => splitMarkers(
          Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x01]),
        ),
        throwsFormatException,
      );
      expect(
        () => splitMarkers(
          Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x10]),
        ),
        throwsFormatException,
      );
    });
  });

  group('bodyEnd', () {
    test('returns the offset just past the last EOI', () {
      final data = Uint8List.fromList(const [
        0xFF, 0xD8, // SOI
        0xFF, 0xD9, // first EOI
        0x01,
        0xFF, 0xD9, // last EOI
        0x07,
      ]);
      expect(bodyEnd(data), 7);
    });

    test('throws without an EOI', () {
      expect(
        () => bodyEnd(Uint8List.fromList(const [0xFF, 0xD8, 0x00])),
        throwsFormatException,
      );
    });
  });

  group('jpegDimensions', () {
    test('reads width and height from SOF0', () {
      final size = jpegDimensions(buildJpeg(width: 640, height: 480));
      expect(size.width, 640);
      expect(size.height, 480);
    });

    test('throws when there is no SOF marker', () {
      final data = joinBytes([
        const [0xFF, 0xD8],
        markerSegment(0xDB, simpleDqt(0, List<int>.filled(64, 1))),
        markerSegment(0xDA, const [0, 0]),
        const [0xFF, 0xD9],
      ]);
      expect(() => jpegDimensions(data), throwsFormatException);
    });
  });

  group('quantisation tables', () {
    test('zigzagToNatural maps the first entries to Pillow order', () {
      final natural = zigzagToNatural(List<int>.generate(64, (i) => i + 1));
      expect(natural[0], 1);
      expect(natural[1], 2);
      expect(natural[8], 3);
      expect(natural[16], 4);
      expect(natural[9], 5);
      expect(natural[2], 6);
      expect(natural[zigzagOrder[63]], 64);
    });

    test('zigzagToNatural rejects the wrong number of values', () {
      expect(
        () => zigzagToNatural(List<int>.filled(63, 0)),
        throwsFormatException,
      );
    });

    test('parses 16-bit DQT tables', () {
      final builder = BytesBuilder();
      builder.addByte(0x10); // precision 1, table 0
      for (var i = 0; i < 64; i++) {
        final value = 0x0100 + i;
        builder
          ..addByte((value >> 8) & 0xFF)
          ..addByte(value & 0xFF);
      }
      final tables = parseDqtPayload(builder.takeBytes());
      expect(tables[0]![0], 0x0100);
      expect(tables[0]![63], 0x013F);
    });

    test('returns natural-order tables sorted by table id', () {
      final table0 = List<int>.generate(64, (i) => 100 + i);
      final table1 = List<int>.generate(64, (i) => i + 1);
      final jpeg = buildJpeg(
        dqt: joinBytes([simpleDqt(1, table1), simpleDqt(0, table0)]),
      );

      final tables = jpegQTables(jpeg);
      expect(tables.length, 2);
      expect(tables[0], zigzagToNatural(table0));
      expect(tables[1], zigzagToNatural(table1));
    });

    test('throws on a truncated DQT table', () {
      expect(
        () => parseDqtPayload(Uint8List.fromList(const [0, 1, 2, 3])),
        throwsFormatException,
      );
    });
  });

  group('embedded previews', () {
    test('concatenates APP2 payloads when they start with SOI', () {
      final jpeg = buildJpeg(
        app2: const [
          [0xFF, 0xD8, 0x01],
          [0x02, 0x03],
        ],
      );
      expect(embeddedPreview(jpeg), [0xFF, 0xD8, 0x01, 0x02, 0x03]);
    });

    test('returns null without APP2 or when it is not a JPEG', () {
      expect(embeddedPreview(buildJpeg()), isNull);
      expect(
        embeddedPreview(
          buildJpeg(
            app2: const [
              [0x01, 0x02],
            ],
          ),
        ),
        isNull,
      );
    });

    test('chunkApp2 splits exactly and rejoins', () {
      final preview = Uint8List.fromList(
        List<int>.generate(200, (i) => i & 0xFF),
      );
      final chunks = chunkApp2(preview, chunkSize: 64);
      expect(chunks.map((c) => c.length), [64, 64, 64, 8]);
      expect(joinBytes(chunks), preview);
      expect(chunkApp2(Uint8List(0)), isEmpty);
      expect(() => chunkApp2(preview, chunkSize: 0), throwsArgumentError);
    });
  });

  group('rebuildJpeg', () {
    test('re-emits the marker order and keeps DQT bytes', () {
      final encoded = buildJpeg(
        dqt: simpleDqt(0, List<int>.generate(64, (i) => i + 1)),
        dht: Uint8List.fromList(const [0x00, 1, 2, 3]),
      );
      final app1 = Uint8List.fromList(const [0x45, 0x78, 0x69, 0x66]);
      final app2 = Uint8List.fromList(const [0xFF, 0xD8, 9, 9]);

      final out = rebuildJpeg(encoded: encoded, app1: app1, app2Chunks: [app2]);
      final layout = splitMarkers(out);
      expect(layout.segments.map((s) => s.marker), [
        0xE1,
        0xE2,
        0xDB,
        0xC0,
        0xC4,
      ]);
      expect(jpegDimensions(out).width, 16);
      expect(
        joinBytes([layout.segments[2].payload]),
        simpleDqt(0, List<int>.generate(64, (i) => i + 1)),
      );
      expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
    });

    test('throws when the encoder produced no SOF0', () {
      final encoded = joinBytes([
        const [0xFF, 0xD8],
        markerSegment(0xDB, simpleDqt(0, List<int>.filled(64, 1))),
        markerSegment(0xDA, const [0, 0]),
        const [0xFF, 0xD9],
      ]);
      expect(
        () => rebuildJpeg(encoded: encoded, app2Chunks: const []),
        throwsFormatException,
      );
    });

    test('rejects an oversized APP2 chunk', () {
      expect(
        () => rebuildJpeg(encoded: buildJpeg(), app2Chunks: [Uint8List(65534)]),
        throwsFormatException,
      );
    });
  });

  group('real camera JPEGs', () {
    test('sample 004 has the documented marker layout', () {
      final data = readSample(sample004);
      final layout = splitMarkers(data);

      expect(
        markerDescription(layout.segments),
        'APP1(11428) APP2(65533) APP2(65533) APP2(38741) '
        'DQT(130) SOF0(15) DHT(416)',
      );
      expect(layout.scanStart, 181826);
      expect(bodyEnd(data), 3322565);
      expect(data.length - bodyEnd(data), 576170);

      final size = jpegDimensions(data);
      expect(size.width, 4096);
      expect(size.height, 3072);
    }, skip: missingSamplesReason);

    test('sample 002 is 8192x4608 and keeps its DRI marker', () {
      final data = readSample(sample002);
      final layout = splitMarkers(data);
      expect(layout.segments.map((s) => s.marker), [
        0xE1,
        0xE2,
        0xE2,
        0xDB,
        0xC0,
        0xC4,
        0xDD,
      ]);
      final size = jpegDimensions(data);
      expect(size.width, 8192);
      expect(size.height, 4608);
    }, skip: missingSamplesReason);

    test('sample 004 preview and quantisation tables', () {
      final data = readSample(sample004);
      final preview = embeddedPreview(data);
      expect(preview, isNotNull);
      expect(preview!.length, 169807);
      final previewSize = jpegDimensions(preview);
      expect(previewSize.width, 704);
      expect(previewSize.height, 544);

      final qtables = jpegQTables(data);
      expect(qtables.length, 2);
      expect(qtables[0].take(8), [2, 1, 14, 15, 16, 16, 3, 15]);
      expect(qtables[1].take(8), [2, 2, 10, 10, 10, 10, 10, 10]);
    }, skip: missingSamplesReason);

    test('sample 004 chunks back to the original APP2 payloads', () {
      final data = readSample(sample004);
      final preview = embeddedPreview(data)!;
      final chunks = chunkApp2(preview);
      expect(chunks.map((c) => c.length), [65533, 65533, 38741]);
      expect(joinBytes(chunks), preview);
    }, skip: missingSamplesReason);

    test('rebuilding sample 004 reproduces the camera body byte for byte', () {
      final data = readSample(sample004);
      final layout = splitMarkers(data);
      final app1 = layout.segments
          .firstWhere((segment) => segment.marker == 0xE1)
          .payload;
      final preview = embeddedPreview(data)!;

      final out = rebuildJpeg(
        encoded: data,
        app1: app1,
        app2Chunks: chunkApp2(preview),
      );
      expect(out.length, bodyEnd(data));
      expect(out, data.sublist(0, bodyEnd(data)));

      final outLayout = splitMarkers(out);
      expect(outLayout.segments.map((s) => s.marker), [
        0xE1,
        0xE2,
        0xE2,
        0xE2,
        0xDB,
        0xC0,
        0xC4,
      ]);
      expect(jpegDimensions(out).width, 4096);
      expect(jpegDimensions(out).height, 3072);

      Uint8List dqtOf(Uint8List file) => joinBytes([
        for (final segment in splitMarkers(file).segments)
          if (segment.marker == 0xDB) segment.payload,
      ]);
      expect(dqtOf(out), dqtOf(data));
    }, skip: missingSamplesReason);

    test('rebuilding sample 002 drops DRI but keeps the scan and DQT', () {
      final data = readSample(sample002);
      final layout = splitMarkers(data);
      final app1 = layout.segments
          .firstWhere((segment) => segment.marker == 0xE1)
          .payload;
      final preview = embeddedPreview(data)!;

      final out = rebuildJpeg(
        encoded: data,
        app1: app1,
        app2Chunks: chunkApp2(preview),
      );
      final outLayout = splitMarkers(out);
      expect(outLayout.segments.map((s) => s.marker), [
        0xE1,
        0xE2,
        0xE2,
        0xDB,
        0xC0,
        0xC4,
      ]);
      expect(
        outLayout.segments.any((segment) => segment.marker == 0xDD),
        isFalse,
      );
      expect(jpegDimensions(out).width, 8192);
      expect(jpegDimensions(out).height, 4608);
      expect(
        out.sublist(outLayout.scanStart),
        data.sublist(layout.scanStart, bodyEnd(data)),
      );

      Uint8List dqtOf(Uint8List file) => joinBytes([
        for (final segment in splitMarkers(file).segments)
          if (segment.marker == 0xDB) segment.payload,
      ]);
      expect(dqtOf(out), dqtOf(data));
    }, skip: missingSamplesReason);
  });
}
