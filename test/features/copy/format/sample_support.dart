import 'dart:io';
import 'dart:typed_data';

/// The real camera samples, gitignored but present on the development machine.
const String sampleDir = '.dev-samples';

const String sample001 = 'IMG_20150715_191431_001.jpg';
const String sample002 = 'IMG_20261101_085440_002.jpg';
const String sample003 = 'IMG_20261101_085454_003.jpg';
const String sample004 = 'IMG_20261101_085513_004.jpg';
const String fileInfoList = 'fileinfo_list.list';
const String editInfoList = '.editinfo_list.list';

bool get samplesAvailable => Directory(sampleDir).existsSync();

String? get missingSamplesReason =>
    samplesAvailable ? null : '$sampleDir is absent';

final Map<String, Uint8List> _cache = {};

File sampleFile(String name) => File('$sampleDir/$name');

/// Read a sample once per test file and cache the bytes.
Uint8List readSample(String name) =>
    _cache.putIfAbsent(name, () => sampleFile(name).readAsBytesSync());

/// Build one JPEG marker segment: `FF <marker> <length> <payload>`.
Uint8List markerSegment(int marker, List<int> payload) {
  final out = Uint8List(4 + payload.length);
  final length = payload.length + 2;
  out[0] = 0xFF;
  out[1] = marker;
  out[2] = (length >> 8) & 0xFF;
  out[3] = length & 0xFF;
  out.setRange(4, out.length, payload);
  return out;
}

Uint8List joinBytes(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

/// A small but structurally valid baseline JPEG, for tests that do not need
/// real image data.
Uint8List buildJpeg({
  List<List<int>> app1 = const [],
  List<List<int>> app2 = const [],
  List<int>? dqt,
  List<int>? dht,
  int width = 16,
  int height = 12,
  bool includeDri = false,
}) {
  final parts = <List<int>>[
    const [0xFF, 0xD8],
  ];
  for (final payload in app1) {
    parts.add(markerSegment(0xE1, payload));
  }
  for (final payload in app2) {
    parts.add(markerSegment(0xE2, payload));
  }
  if (dqt != null) {
    parts.add(markerSegment(0xDB, dqt));
  }

  final sof = Uint8List(6);
  sof[0] = 8;
  sof[1] = (height >> 8) & 0xFF;
  sof[2] = height & 0xFF;
  sof[3] = (width >> 8) & 0xFF;
  sof[4] = width & 0xFF;
  sof[5] = 3;
  parts.add(markerSegment(0xC0, sof));

  if (dht != null) {
    parts.add(markerSegment(0xC4, dht));
  }
  if (includeDri) {
    parts.add(markerSegment(0xDD, const [0xFF, 0xFF]));
  }

  parts.add(markerSegment(0xDA, const [1, 0, 0, 0]));
  parts.add(const [0x12, 0x34, 0x56, 0xFF, 0xD9]);
  return joinBytes(parts);
}

/// One 8-bit DQT payload for a single table.
Uint8List simpleDqt(int tableId, List<int> values) {
  if (values.length != 64) {
    throw ArgumentError('a DQT table needs 64 values');
  }
  return Uint8List.fromList([tableId & 0x0F, ...values]);
}

int checksum(List<int> bytes) {
  var value = 0;
  for (final byte in bytes) {
    value = (value + byte) & 0x7FFFFFFF;
  }
  return value;
}
