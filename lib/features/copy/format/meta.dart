/// The camera's proprietary metadata: the post-EOI trailer and its index.
///
/// Layout of the trailer::
///
///     [4-byte value][427-byte binary header][metadata protobuf][bulk data]
///                                           ^ offset 431 in every sample
///
/// The same 1151-byte protobuf is copied verbatim into
/// `DCIM/fileinfo_list.list`, which is why everything here is shared between
/// the JPEG and the camera index.
///
/// Two of its fields are absolute and per-file and must be rewritten for every
/// clone, or the camera will seek to the wrong place and silently hide the
/// file:
///
/// * field 9 — offset of the metadata blob inside the file (`bodyEnd + 431`)
/// * field 7 — capture time as `YYYYMMDDHHMMSS`, identical to the file name
library;

import 'dart:typed_data';

/// `IMG_YYYYMMDD_HHMMSS_NNN.jpg` is 27 characters. The slot is fixed in the
/// EXIF ImageDescription tag and inside the trailer's length-prefixed path.
const int nameLength = 27;

/// The camera serial: 14 characters, `IB` + 12 upper-case base-36 characters.
const int serialLength = 14;

/// The device UID: the last 32 bytes of the blob, lower-case hex.
const int uidLength = 32;

/// Per-file fields inside the metadata protobuf.
const int fieldTimestamp = 7;
const int fieldOffset = 9;
const int fieldPath = 26;

const String fileInfoListPath = 'DCIM/fileinfo_list.list';
const String editInfoListPath = 'DCIM/.editinfo_list.list';
const String cameraDir = 'DCIM/Camera01';

/// The fixed part of the metadata pointer (blob offset inside the trailer).
const int blobOffsetFallback = 431;

final RegExp cameraNamePattern = RegExp(r'^IMG_(\d{8})_(\d{6})_(\d{3})\.jpg$');

final RegExp serialPattern = RegExp(r'IB[A-Z0-9]{12}');

final RegExp uidPattern = RegExp(r'^[0-9a-f]{32}$');

/// `IMG_YYYYMMDD_HHMMSS_NNN.jpg` — always [nameLength] characters.
String cameraFileName(DateTime dt, int seq) {
  if (dt.year < 0 || dt.year > 9999) {
    throw ArgumentError.value(dt.year, 'dt.year', 'must be a 4-digit year');
  }
  if (seq < 0 || seq > 999) {
    throw RangeError.range(seq, 0, 999, 'seq');
  }
  String two(int value) => value.toString().padLeft(2, '0');
  final year = dt.year.toString().padLeft(4, '0');
  return 'IMG_$year${two(dt.month)}${two(dt.day)}_'
      '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}_'
      '${seq.toString().padLeft(3, '0')}.jpg';
}

// ---------------------------------------------------------------------------
// protobuf wire format
// ---------------------------------------------------------------------------

/// Read a protobuf varint starting at [offset].
///
/// Returns the value and the offset just past the varint. Throws
/// [FormatException] if the buffer ends mid-varint or the encoding is longer
/// than 64 bits.
({int value, int next}) readVarint(Uint8List buf, int offset) {
  if (offset < 0 || offset >= buf.length) {
    throw FormatException('varint offset $offset is outside the buffer');
  }
  var value = 0;
  var shift = 0;
  var i = offset;
  while (true) {
    if (i >= buf.length) {
      throw FormatException('truncated varint at offset $offset');
    }
    final byte = buf[i];
    i++;
    if (shift >= 64) {
      throw FormatException('varint at offset $offset is longer than 64 bits');
    }
    value |= (byte & 0x7F) << shift;
    if (value < 0) {
      throw FormatException(
        'varint at offset $offset exceeds the signed 64-bit range',
      );
    }
    if ((byte & 0x80) == 0) {
      return (value: value, next: i);
    }
    shift += 7;
  }
}

({int value, int next})? _tryReadVarint(Uint8List buf, int offset) {
  try {
    return readVarint(buf, offset);
  } on FormatException {
    return null;
  }
}

/// Encode a varint, optionally padded with redundant groups (same value).
///
/// Throws [ArgumentError] for negative values and when the value needs more
/// than [padTo] bytes.
Uint8List encodeVarint(int value, {int padTo = 0}) {
  if (value < 0) {
    throw ArgumentError.value(
      value,
      'value',
      'a protobuf varint cannot encode a negative number',
    );
  }
  if (padTo < 0) {
    throw ArgumentError.value(padTo, 'padTo', 'must not be negative');
  }

  final groups = <int>[];
  var remaining = value;
  while (true) {
    groups.add(remaining & 0x7F);
    remaining >>= 7;
    if (remaining == 0) {
      break;
    }
  }

  if (padTo > 0 && groups.length > padTo) {
    throw ArgumentError('value needs more than $padTo varint bytes');
  }
  while (groups.length < padTo) {
    groups.add(0);
  }

  final out = Uint8List(groups.length);
  for (var i = 0; i < groups.length - 1; i++) {
    out[i] = groups[i] | 0x80;
  }
  out[groups.length - 1] = groups[groups.length - 1];
  return out;
}

class _PbField {
  final int field;
  final int wire;

  /// Offset of the field's key byte.
  final int start;

  /// Offset just past the field's value.
  final int valueEnd;
  final int? intValue;
  final Uint8List? bytesValue;

  const _PbField(
    this.field,
    this.wire,
    this.start,
    this.valueEnd, {
    this.intValue,
    this.bytesValue,
  });
}

/// Parse a protobuf message, stopping at the first non-field byte.
({List<_PbField> fields, int end}) _readFields(
  Uint8List buf, [
  int start = 0,
  int? limit,
]) {
  final end = limit == null || limit > buf.length ? buf.length : limit;
  var i = start;
  final fields = <_PbField>[];

  while (i < end) {
    final key = _tryReadVarint(buf, i);
    if (key == null) {
      break;
    }
    final field = key.value >> 3;
    final wire = key.value & 7;
    if (field == 0 || wire == 3 || wire == 4 || wire == 6 || wire == 7) {
      break;
    }

    var j = key.next;
    switch (wire) {
      case 0:
        final value = _tryReadVarint(buf, j);
        if (value == null) {
          return (fields: fields, end: i);
        }
        fields.add(_PbField(field, wire, i, value.next, intValue: value.value));
        i = value.next;
      case 2:
        final length = _tryReadVarint(buf, j);
        if (length == null ||
            length.next > end ||
            length.value > end - length.next) {
          return (fields: fields, end: i);
        }
        final valueStart = length.next;
        final valueEnd = valueStart + length.value;
        fields.add(
          _PbField(
            field,
            wire,
            i,
            valueEnd,
            bytesValue: buf.sublist(valueStart, valueEnd),
          ),
        );
        i = valueEnd;
      case 5:
        if (j + 4 > end) {
          return (fields: fields, end: i);
        }
        fields.add(
          _PbField(field, wire, i, j + 4, bytesValue: buf.sublist(j, j + 4)),
        );
        i = j + 4;
      case 1:
        if (j + 8 > end) {
          return (fields: fields, end: i);
        }
        fields.add(
          _PbField(field, wire, i, j + 8, bytesValue: buf.sublist(j, j + 8)),
        );
        i = j + 8;
      default:
        return (fields: fields, end: i);
    }
  }
  return (fields: fields, end: i);
}

int? _fieldVarint(List<_PbField> fields, int fieldNumber) {
  int? value;
  for (final field in fields) {
    if (field.field == fieldNumber && field.wire == 0) {
      value = field.intValue;
    }
  }
  return value;
}

Uint8List? _fieldBytes(List<_PbField> fields, int fieldNumber) {
  for (final field in fields) {
    if (field.field == fieldNumber && field.wire == 2) {
      return field.bytesValue;
    }
  }
  return null;
}

bool _patchVarint(Uint8List buf, int start, int fieldNumber, int value) {
  for (final field in _readFields(buf, start).fields) {
    if (field.field != fieldNumber) {
      continue;
    }
    if (field.wire != 0) {
      return false;
    }
    final key = _tryReadVarint(buf, field.start);
    if (key == null) {
      return false;
    }
    final width = field.valueEnd - key.next;
    if (width <= 0) {
      return false;
    }
    final Uint8List encoded;
    try {
      encoded = encodeVarint(value, padTo: width);
    } on ArgumentError {
      return false;
    }
    buf.setRange(key.next, field.valueEnd, encoded);
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// trailer scanning helpers
// ---------------------------------------------------------------------------

String? _asciiOrNull(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    if (byte > 0x7F) {
      return null;
    }
    buffer.writeCharCode(byte);
  }
  return buffer.toString();
}

Uint8List _asciiBytes(String value) {
  final out = Uint8List(value.runes.length);
  var i = 0;
  for (final rune in value.runes) {
    if (rune > 0x7F) {
      throw FormatException(
        'expected ASCII, found U+${rune.toRadixString(16)}',
      );
    }
    out[i] = rune;
    i++;
  }
  return out;
}

String _asciiDecode(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.writeCharCode(byte <= 0x7F ? byte : 0xFFFD);
  }
  return buffer.toString();
}

bool _isUpperAlnum(int byte) =>
    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39);

bool _matchesAt(Uint8List data, int offset, List<int> pattern) {
  if (offset < 0 || offset + pattern.length > data.length) {
    return false;
  }
  for (var i = 0; i < pattern.length; i++) {
    if (data[offset + i] != pattern[i]) {
      return false;
    }
  }
  return true;
}

int? _locateBlob(Uint8List trailer, String? serial) {
  if (serial == null || serial.isEmpty) {
    return null;
  }
  final Uint8List serialBytes;
  try {
    serialBytes = _asciiBytes(serial);
  } on FormatException {
    return null;
  }

  final pattern = Uint8List(2 + serialBytes.length);
  pattern[0] = 0x0A;
  pattern[1] = 0x0E;
  pattern.setRange(2, pattern.length, serialBytes);

  int? found;
  for (var i = 0; i + pattern.length <= trailer.length; i++) {
    if (!_matchesAt(trailer, i, pattern)) {
      continue;
    }
    if (found != null) {
      // Python requires the pattern to be unique.
      return null;
    }
    found = i;
    i += pattern.length - 1;
  }
  return found;
}

/// First `IB…` serial that is preceded by its protobuf tag (`0a 0e`).
String? serialOf(Uint8List trailer) {
  const tag = [0x0A, 0x0E];
  for (var i = 0; i + 2 + serialLength <= trailer.length; i++) {
    if (!_matchesAt(trailer, i, tag)) {
      continue;
    }
    final start = i + 2;
    if (trailer[start] != 0x49 || trailer[start + 1] != 0x42) {
      continue;
    }
    var ok = true;
    for (var k = 2; k < serialLength; k++) {
      if (!_isUpperAlnum(trailer[start + k])) {
        ok = false;
        break;
      }
    }
    if (ok) {
      return _asciiOrNull(
        Uint8List.sublistView(trailer, start, start + serialLength),
      );
    }
  }
  return null;
}

/// The 32-hex device UID that closes the blob.
String? uidOf(Uint8List trailer) {
  if (trailer.length < uidLength) {
    return null;
  }
  final tail = Uint8List.sublistView(
    trailer,
    trailer.length - uidLength,
    trailer.length,
  );
  for (final byte in tail) {
    final isHex =
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66);
    if (!isHex) {
      return null;
    }
  }
  return _asciiOrNull(tail);
}

/// The per-file metadata read out of the trailer's protobuf.
class MetaInfo {
  final String? serial;
  final int blobOffset;
  final int blobLength;
  final int? fileOffset;
  final int? timestamp;
  final String? path;

  const MetaInfo({
    required this.serial,
    required this.blobOffset,
    required this.blobLength,
    this.fileOffset,
    this.timestamp,
    this.path,
  });
}

/// Read the per-file fields that must stay consistent with the image.
MetaInfo? metaInfo(Uint8List trailer, {String? serial}) {
  final resolved = serial == null || serial.isEmpty
      ? serialOf(trailer)
      : serial;
  final offset = _locateBlob(trailer, resolved);
  if (offset == null || resolved == null) {
    return null;
  }

  final parsed = _readFields(trailer, offset);
  final pathBytes = _fieldBytes(parsed.fields, fieldPath);
  return MetaInfo(
    serial: resolved,
    blobOffset: offset,
    blobLength: parsed.end - offset,
    fileOffset: _fieldVarint(parsed.fields, fieldOffset),
    timestamp: _fieldVarint(parsed.fields, fieldTimestamp),
    path: pathBytes == null
        ? null
        : _asciiDecode(pathBytes).split('\u0000').first,
  );
}

DateTime? _parseTimestamp(int timestamp) {
  final text = timestamp.toString();
  if (text.length != 14) {
    return null;
  }
  final year = int.parse(text.substring(0, 4));
  final month = int.parse(text.substring(4, 6));
  final day = int.parse(text.substring(6, 8));
  final hour = int.parse(text.substring(8, 10));
  final minute = int.parse(text.substring(10, 12));
  final second = int.parse(text.substring(12, 14));
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31 ||
      hour > 23 ||
      minute > 59 ||
      second > 59 ||
      year < 1) {
    return null;
  }
  final result = DateTime(year, month, day, hour, minute, second);
  if (result.year != year ||
      result.month != month ||
      result.day != day ||
      result.hour != hour ||
      result.minute != minute ||
      result.second != second) {
    return null;
  }
  return result;
}

/// Field 7 as a datetime, or null.
DateTime? captureTime(Uint8List trailer) {
  final timestamp = metaInfo(trailer)?.timestamp;
  if (timestamp == null) {
    return null;
  }
  return _parseTimestamp(timestamp);
}

int _timestampValue(DateTime dt) {
  String two(int value) => value.toString().padLeft(2, '0');
  return int.parse(
    '${dt.year.toString().padLeft(4, '0')}${two(dt.month)}${two(dt.day)}'
    '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}',
  );
}

/// Point field 9 at the real metadata location and set field 7 to [capture].
///
/// The trailer length never changes: both fields are rewritten as padded
/// varints of exactly the original width.
Uint8List patchMeta(
  Uint8List trailer, {
  String? serial,
  required int fileOffset,
  required DateTime capture,
}) {
  final resolved = serial == null || serial.isEmpty
      ? serialOf(trailer)
      : serial;
  final offset = _locateBlob(trailer, resolved);
  if (offset == null) {
    throw const FormatException(
      'cannot locate the metadata protobuf in the trailer',
    );
  }

  final buf = Uint8List.fromList(trailer);
  if (!_patchVarint(buf, offset, fieldOffset, fileOffset)) {
    throw const FormatException('cannot patch the metadata offset field');
  }
  if (!_patchVarint(buf, offset, fieldTimestamp, _timestampValue(capture))) {
    throw const FormatException('cannot patch the metadata timestamp field');
  }
  return buf;
}

// ---------------------------------------------------------------------------
// the raw NV21 thumbnail in the trailer
// ---------------------------------------------------------------------------

const int _bulkLengthAt = 10;
const int _bulkWidthAt = 22;
const int _bulkHeightAt = 26;
const int _bulkDataAt = 46;

int _u32le(Uint8List data, int offset) {
  if (offset < 0 || offset + 4 > data.length) {
    throw FormatException('little-endian u32 out of bounds at $offset');
  }
  return data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
}

/// Where the raw NV21 thumbnail lives and how big it is.
class BulkInfo {
  final int offset;
  final int width;
  final int height;
  final int length;
  final int size;

  const BulkInfo({
    required this.offset,
    required this.width,
    required this.height,
    required this.length,
    required this.size,
  });
}

/// Locate the raw NV21 buffer at the end of the metadata blob.
BulkInfo? bulkInfo(Uint8List trailer, {String? serial}) {
  final info = metaInfo(trailer, serial: serial);
  if (info == null) {
    return null;
  }
  final end = info.blobOffset + info.blobLength;
  if (end + _bulkDataAt > trailer.length) {
    return null;
  }

  final length = _u32le(trailer, end + _bulkLengthAt);
  final width = _u32le(trailer, end + _bulkWidthAt);
  final height = _u32le(trailer, end + _bulkHeightAt);
  if (width <= 0 || height <= 0) {
    return null;
  }
  // Keep the multiplication far away from overflowing a 64-bit int, and
  // reject dimensions that could not possibly fit in the trailer anyway.
  if (width > trailer.length || height > trailer.length) {
    return null;
  }
  final size = width * height * 3 ~/ 2;
  final offset = end + _bulkDataAt;
  if (size <= 0 || offset + size > trailer.length) {
    return null;
  }
  return BulkInfo(
    offset: offset,
    width: width,
    height: height,
    length: length,
    size: size,
  );
}

/// Overwrite the raw thumbnail in place; the length never changes.
Uint8List patchBulk(Uint8List trailer, BulkInfo info, Uint8List data) {
  if (data.length != info.size) {
    throw ArgumentError(
      'bulk image is ${data.length} bytes, expected ${info.size}',
    );
  }
  final end = info.offset + info.size;
  if (info.offset < 0 ||
      info.size < 0 ||
      end < info.offset ||
      end > trailer.length) {
    throw FormatException(
      'bulk image range ${info.offset}..$end is outside the '
      '${trailer.length}-byte trailer',
    );
  }
  final out = Uint8List.fromList(trailer);
  out.setRange(info.offset, end, data);
  return out;
}

// ---------------------------------------------------------------------------
// other per-file edits
// ---------------------------------------------------------------------------

bool _isDigit(int byte) => byte >= 0x30 && byte <= 0x39;

({int start, int length})? _findCameraDir(Uint8List data) {
  const prefix = [
    0x2F, 0x44, 0x43, 0x49, 0x4D, 0x2F, // "/DCIM/"
    0x43, 0x61, 0x6D, 0x65, 0x72, 0x61, // "Camera"
  ];
  for (var i = 0; i + 15 <= data.length; i++) {
    if (!_matchesAt(data, i, prefix)) {
      continue;
    }
    if (_isDigit(data[i + 12]) &&
        _isDigit(data[i + 13]) &&
        data[i + 14] == 0x2F) {
      return (start: i, length: 15);
    }
  }
  return null;
}

/// Replace the DCIM path inside the trailer, length-preserving.
///
/// Returns [trailer] unchanged when there is no `/DCIM/CameraNN/<name>` path
/// to patch. Throws [ArgumentError] if [filename] is not exactly
/// [nameLength] characters.
Uint8List patchPath(Uint8List trailer, String filename) {
  if (filename.length != nameLength) {
    throw ArgumentError.value(
      filename,
      'filename',
      'file name must be exactly $nameLength characters',
    );
  }

  final dir = _findCameraDir(trailer);
  if (dir == null) {
    return trailer;
  }
  final nameStart = dir.start + dir.length;
  if (nameStart + nameLength > trailer.length) {
    return trailer;
  }

  final oldName = Uint8List.sublistView(
    trailer,
    nameStart,
    nameStart + nameLength,
  );
  final oldText = _asciiOrNull(oldName);
  if (oldText == null || !cameraNamePattern.hasMatch(oldText)) {
    return trailer;
  }

  final nameBytes = _asciiBytes(filename);
  final out = Uint8List.fromList(trailer);
  out.setRange(nameStart, nameStart + nameLength, nameBytes);
  return out;
}

// ---------------------------------------------------------------------------
// the camera's media index
// ---------------------------------------------------------------------------
//
//   DCIM/fileinfo_list.list : 0a <len> 0a <len(path)> <path> 12 <len(blob)> <blob>
//   DCIM/.editinfo_list.list: 0a <len> 0a <len(path)> <path> 12 00

/// One record of a camera index file.
class IndexRecord {
  final String path;
  final Uint8List blob;
  final Uint8List raw;

  const IndexRecord({
    required this.path,
    required this.blob,
    required this.raw,
  });
}

/// Split an index file into its records.
List<IndexRecord> indexRecords(Uint8List data) {
  final out = <IndexRecord>[];
  var i = 0;
  while (i < data.length) {
    final start = i;
    final key = _tryReadVarint(data, i);
    if (key == null || key.value >> 3 != 1 || key.value & 7 != 2) {
      break;
    }
    final length = _tryReadVarint(data, key.next);
    if (length == null ||
        length.next > data.length ||
        length.value > data.length - length.next) {
      break;
    }
    final recordStart = length.next;
    final recordEnd = recordStart + length.value;
    final record = data.sublist(recordStart, recordEnd);
    i = recordEnd;

    final fields = _readFields(record).fields;
    final pathBytes = _fieldBytes(fields, 1);
    final blob = _fieldBytes(fields, 2);
    out.add(
      IndexRecord(
        path: pathBytes == null ? '' : _asciiDecode(pathBytes),
        blob: blob ?? Uint8List(0),
        raw: data.sublist(start, i),
      ),
    );
  }
  return out;
}

Uint8List _join(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

Uint8List _lengthDelimited(int key, Uint8List value) => _join([
  [key],
  encodeVarint(value.length),
  value,
]);

/// Build `0a <len> 0a <len(path)> <path> 12 <len(blob)> <blob>`.
Uint8List buildIndexRecord(String path, Uint8List blob) {
  final pathBytes = _asciiBytes(path);
  final inner = _join([
    _lengthDelimited(0x0A, pathBytes),
    _lengthDelimited(0x12, blob),
  ]);
  return _lengthDelimited(0x0A, inner);
}

/// Build `0a <len> 0a <len(path)> <path> 12 00`.
Uint8List buildEditRecord(String path) {
  final pathBytes = _asciiBytes(path);
  final inner = _join([
    _lengthDelimited(0x0A, pathBytes),
    const [0x12, 0x00],
  ]);
  return _lengthDelimited(0x0A, inner);
}

/// Remove every record whose path matches.
Uint8List dropRecords(Uint8List data, String path) {
  final builder = BytesBuilder(copy: false);
  for (final record in indexRecords(data)) {
    if (record.path != path) {
      builder.add(record.raw);
    }
  }
  return builder.takeBytes();
}

/// Drop the record whose path matches, then add the new one.
///
/// The camera itself puts the most recently scanned file at the *front* of the
/// list, so `install` mirrors that with [prepend].
Uint8List upsertRecords(
  Uint8List data,
  String path,
  Uint8List record, {
  bool prepend = false,
}) {
  final kept = <Uint8List>[
    for (final existing in indexRecords(data))
      if (existing.path != path) existing.raw,
  ];
  final builder = BytesBuilder(copy: false);
  if (prepend) {
    builder.add(record);
  }
  for (final raw in kept) {
    builder.add(raw);
  }
  if (!prepend) {
    builder.add(record);
  }
  return builder.takeBytes();
}
