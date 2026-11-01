/// JPEG container plumbing: markers, quantisation tables, re-assembly.
///
/// Nothing camera-specific lives here — the GO Ultra conventions are in
/// `template.dart`. This is a pure-Dart port of the Python tool's `jpeg.py`
/// (minus the Pillow-based image encoding, which belongs to the image layer).
library;

import 'dart:typed_data';

/// A single JPEG marker segment before the scan.
class JpegSegment {
  final int marker;
  final Uint8List payload;

  const JpegSegment(this.marker, this.payload);
}

/// The marker layout of a JPEG: every segment before SOS and the offset of the
/// SOS marker itself. The scan (SOS payload through EOI) is not split.
class JpegLayout {
  final List<JpegSegment> segments;
  final int scanStart;

  const JpegLayout(this.segments, this.scanStart);
}

/// Marker byte -> printable name, for reports.
const Map<int, String> markerNames = {
  0xC0: 'SOF0',
  0xC1: 'SOF1',
  0xC2: 'SOF2',
  0xC3: 'SOF3',
  0xC4: 'DHT',
  0xC8: 'JPG',
  0xC9: 'SOF9',
  0xCA: 'SOF10',
  0xCC: 'DAC',
  0xDB: 'DQT',
  0xDD: 'DRI',
  0xDA: 'SOS',
  0xE0: 'APP0',
  0xE1: 'APP1',
  0xE2: 'APP2',
  0xE3: 'APP3',
  0xE4: 'APP4',
  0xE5: 'APP5',
  0xE6: 'APP6',
  0xE7: 'APP7',
  0xE8: 'APP8',
  0xE9: 'APP9',
  0xEA: 'APP10',
  0xEB: 'APP11',
  0xEC: 'APP12',
  0xED: 'APP13',
  0xEE: 'APP14',
  0xEF: 'APP15',
  0xFE: 'COM',
};

/// Zigzag index -> natural (Pillow) index, JPEG Annex K.
const List<int> zigzagOrder = [
  0, 1, 8, 16, 9, 2, 3, 10, //
  17, 24, 32, 25, 18, 11, 4, 5,
  12, 19, 26, 33, 40, 48, 41, 34,
  27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36,
  29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46,
  53, 60, 61, 54, 47, 55, 62, 63,
];

/// Reorder 64 zigzag-ordered quantisation values into natural raster order.
List<int> zigzagToNatural(List<int> zigzag) {
  if (zigzag.length != 64) {
    throw FormatException(
      'a quantisation table has 64 values, got ${zigzag.length}',
    );
  }
  final natural = List<int>.filled(64, 0);
  for (var i = 0; i < 64; i++) {
    natural[zigzagOrder[i]] = zigzag[i];
  }
  return natural;
}

/// Compact printable description of a marker list.
String markerDescription(List<JpegSegment> segments) => segments
    .map(
      (s) =>
          '${markerNames[s.marker] ?? 'FF${s.marker.toRadixString(16).toUpperCase().padLeft(2, '0')}'}'
          '(${s.payload.length})',
    )
    .join(' ');

/// Split a JPEG up to its SOS marker.
///
/// Returns the marker segments before SOS and the offset of the SOS marker.
/// Stray SOI markers, 0x00 fill bytes and RSTn markers are skipped, exactly like
/// the Python tool. Throws [FormatException] on corrupt input.
JpegLayout splitMarkers(Uint8List data) {
  if (data.length < 2 || data[0] != 0xFF || data[1] != 0xD8) {
    throw const FormatException('not a JPEG (missing SOI)');
  }

  var i = 2;
  final segments = <JpegSegment>[];
  while (true) {
    if (i + 4 > data.length) {
      throw FormatException('corrupt JPEG marker at offset $i');
    }
    if (data[i] != 0xFF) {
      throw FormatException('corrupt JPEG marker at offset $i');
    }

    final marker = data[i + 1];
    if (marker == 0xD8) {
      // stray SOI
      i += 2;
      continue;
    }
    if (marker == 0x00 || (marker >= 0xD0 && marker <= 0xD7)) {
      // fill byte or restart marker
      i += 2;
      continue;
    }

    final length = (data[i + 2] << 8) | data[i + 3];
    if (length < 2) {
      throw FormatException('invalid JPEG segment length $length at offset $i');
    }
    final end = i + 2 + length;
    if (end > data.length) {
      throw FormatException('truncated JPEG segment at offset $i');
    }
    if (marker == 0xDA) {
      return JpegLayout(segments, i);
    }

    segments.add(JpegSegment(marker, data.sublist(i + 4, end)));
    i = end;
  }
}

/// Offset just past the last EOI (i.e. the size of the JPEG itself).
int bodyEnd(Uint8List data) {
  for (var i = data.length - 2; i >= 0; i--) {
    if (data[i] == 0xFF && data[i + 1] == 0xD9) {
      return i + 2;
    }
  }
  throw const FormatException('no EOI found');
}

/// Width and height from the SOF0/SOF1/SOF2 header.
({int width, int height}) jpegDimensions(Uint8List data) {
  final layout = splitMarkers(data);
  for (final segment in layout.segments) {
    final marker = segment.marker;
    if ((marker == 0xC0 || marker == 0xC1 || marker == 0xC2) &&
        segment.payload.length >= 6) {
      final payload = segment.payload;
      return (
        width: (payload[3] << 8) | payload[4],
        height: (payload[1] << 8) | payload[2],
      );
    }
  }
  throw const FormatException('no SOF marker');
}

/// Parse a DQT payload into `{tableId: [64 values in zigzag order]}`.
Map<int, List<int>> parseDqtPayload(Uint8List payload) {
  final tables = <int, List<int>>{};
  var i = 0;
  while (i < payload.length) {
    final header = payload[i];
    i++;
    final precision = header >> 4;
    final tableId = header & 0x0F;
    final values = List<int>.filled(64, 0);

    if (precision == 0) {
      if (i + 64 > payload.length) {
        throw const FormatException('truncated 8-bit DQT table');
      }
      for (var k = 0; k < 64; k++) {
        values[k] = payload[i + k];
      }
      i += 64;
    } else {
      // 16-bit tables are never used by the camera, but keep them correct.
      if (i + 128 > payload.length) {
        throw const FormatException('truncated 16-bit DQT table');
      }
      for (var k = 0; k < 64; k++) {
        values[k] = (payload[i + 2 * k] << 8) | payload[i + 2 * k + 1];
      }
      i += 128;
    }
    tables[tableId] = values;
  }
  return tables;
}

/// All quantisation tables of a JPEG, in Pillow's natural order, sorted by id.
List<List<int>> jpegQTables(Uint8List data) {
  final layout = splitMarkers(data);
  final joined = BytesBuilder(copy: false);
  for (final segment in layout.segments) {
    if (segment.marker == 0xDB) {
      joined.add(segment.payload);
    }
  }
  final tables = parseDqtPayload(joined.takeBytes());
  final ids = tables.keys.toList()..sort();
  return [for (final id in ids) zigzagToNatural(tables[id]!)];
}

/// Concatenate APP2 payloads — the camera hides a whole JPEG in them.
Uint8List? embeddedPreview(Uint8List data) {
  final layout = splitMarkers(data);
  final builder = BytesBuilder(copy: false);
  var found = false;
  for (final segment in layout.segments) {
    if (segment.marker == 0xE2) {
      found = true;
      builder.add(segment.payload);
    }
  }
  if (!found) {
    return null;
  }
  final blob = builder.takeBytes();
  if (blob.length >= 2 && blob[0] == 0xFF && blob[1] == 0xD8) {
    return blob;
  }
  return null;
}

/// Split the hidden preview into APP2-sized chunks.
List<Uint8List> chunkApp2(Uint8List preview, {int chunkSize = 65533}) {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
  }
  return [
    for (var i = 0; i < preview.length; i += chunkSize)
      preview.sublist(
        i,
        i + chunkSize < preview.length ? i + chunkSize : preview.length,
      ),
  ];
}

void _appendSegment(BytesBuilder out, int marker, List<int> payload) {
  if (payload.length > 0xFFFF - 2) {
    throw FormatException(
      'segment FF${marker.toRadixString(16).toUpperCase()} is too large '
      '(${payload.length} payload bytes)',
    );
  }
  final length = payload.length + 2;
  out
    ..addByte(0xFF)
    ..addByte(marker)
    ..addByte((length >> 8) & 0xFF)
    ..addByte(length & 0xFF)
    ..add(payload);
}

/// Reassemble an encoder-produced JPEG into the camera's marker layout.
///
/// The camera puts a DRI marker (restart interval 65535) in the 8192-wide
/// modes, but it is deliberately not reproduced: a DRI without the matching
/// RSTn markers makes libjpeg — and therefore most printer firmware — stop at
/// the first expected restart and fill the rest of the frame with grey.
///
/// Takes the DQT payloads (joined), the SOF0 payload, the DHT payloads
/// (joined) and the whole scan (SOS marker through EOI) from [encoded], then
/// emits SOI, APP1 (if any), every APP2 chunk, one DQT, SOF0, one DHT and the
/// scan. Throws [FormatException] if [encoded] has no SOF0.
Uint8List rebuildJpeg({
  required Uint8List encoded,
  Uint8List? app1,
  required List<Uint8List> app2Chunks,
}) {
  final layout = splitMarkers(encoded);
  final end = bodyEnd(encoded);
  if (layout.scanStart >= end) {
    throw FormatException(
      'JPEG scan at ${layout.scanStart} does not precede EOI at $end',
    );
  }
  final scan = encoded.sublist(layout.scanStart, end);

  final dqt = BytesBuilder(copy: false);
  final dht = BytesBuilder(copy: false);
  Uint8List? sof;
  for (final segment in layout.segments) {
    switch (segment.marker) {
      case 0xDB:
        dqt.add(segment.payload);
      case 0xC0:
        sof ??= segment.payload;
      case 0xC4:
        dht.add(segment.payload);
    }
  }
  final sofPayload = sof;
  if (sofPayload == null) {
    throw const FormatException('encoder produced no SOF0');
  }

  final out = BytesBuilder(copy: false);
  out.add(const [0xFF, 0xD8]);
  if (app1 != null && app1.isNotEmpty) {
    _appendSegment(out, 0xE1, app1);
  }
  for (final chunk in app2Chunks) {
    _appendSegment(out, 0xE2, chunk);
  }
  // one segment, both tables
  _appendSegment(out, 0xDB, dqt.takeBytes());
  _appendSegment(out, 0xC0, sofPayload);
  // one segment, all four tables
  _appendSegment(out, 0xC4, dht.takeBytes());
  out.add(scan);
  return out.takeBytes();
}
