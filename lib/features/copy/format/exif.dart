/// Byte-level TIFF/EXIF editing.
///
/// The camera's EXIF block is copied verbatim and poked in place: a
/// `getexif()` round-trip would reorder rationals and drop the MakerNote,
/// which is part of what makes the file look like a camera original.
library;

import 'dart:typed_data';

import 'jpeg.dart';

/// TIFF field type -> size in bytes.
const Map<int, int> tiffTypeSizes = {
  1: 1, // BYTE
  2: 1, // ASCII
  3: 2, // SHORT
  4: 4, // LONG
  5: 8, // RATIONAL
  6: 1, // SBYTE
  7: 1, // UNDEFINED
  8: 2, // SSHORT
  9: 4, // SLONG
  10: 8, // SRATIONAL
  11: 4, // FLOAT
  12: 8, // DOUBLE
};

const int tagImageDescription = 0x010E;
const int tagMake = 0x010F;
const int tagModel = 0x0110;
const int tagSoftware = 0x0131;
const int tagDateTime = 0x0132;
const int tagExifIfd = 0x8769;
const int tagDateTimeOriginal = 0x9003;
const int tagDateTimeDigitized = 0x9004;
const int tagPixelX = 0xA002;
const int tagPixelY = 0xA003;
const int tagThumbOffset = 0x0201;
const int tagThumbLength = 0x0202;

const List<int> _exifHeader = [
  0x45,
  0x78,
  0x69,
  0x66,
  0x00,
  0x00,
]; // "Exif\0\0"

class TiffEntry {
  final int tag;
  final int type;
  final int count;

  /// Offset of the 12-byte IFD entry itself.
  final int slot;

  const TiffEntry(this.tag, this.type, this.count, this.slot);
}

/// Just enough TIFF to read tags and poke new values into the template.
///
/// Supports both little-endian (`II`) and big-endian (`MM`) blocks, inline
/// values (four bytes or fewer) and offset values. All offsets are validated;
/// malformed blocks throw [FormatException].
class Tiff {
  /// Mutable TIFF bytes (without the `Exif\0\0` APP1 prefix).
  Uint8List data;
  final bool littleEndian;

  factory Tiff(Uint8List source) {
    if (source.length < 2) {
      throw const FormatException('not a TIFF block');
    }
    final bool little;
    if (source[0] == 0x49 && source[1] == 0x49) {
      little = true;
    } else if (source[0] == 0x4D && source[1] == 0x4D) {
      little = false;
    } else {
      throw const FormatException('not a TIFF block');
    }
    return Tiff._(Uint8List.fromList(source), little);
  }

  Tiff._(this.data, this.littleEndian);

  void _checkRange(int offset, int length, String what) {
    if (offset < 0 || length < 0 || offset + length > data.length) {
      throw FormatException(
        '$what out of bounds (offset $offset, length $length, '
        'block ${data.length} bytes)',
      );
    }
  }

  int u16(int offset) {
    _checkRange(offset, 2, 'TIFF u16');
    final a = data[offset];
    final b = data[offset + 1];
    return littleEndian ? a | (b << 8) : (a << 8) | b;
  }

  int u32(int offset) {
    _checkRange(offset, 4, 'TIFF u32');
    final a = data[offset];
    final b = data[offset + 1];
    final c = data[offset + 2];
    final d = data[offset + 3];
    return littleEndian
        ? a | (b << 8) | (c << 16) | (d << 24)
        : (a << 24) | (b << 16) | (c << 8) | d;
  }

  /// Parse an IFD into `tag -> entry` plus the next IFD's offset.
  ({Map<int, TiffEntry> entries, int nextOffset}) readIfd(int offset) {
    final count = u16(offset);
    final entries = <int, TiffEntry>{};
    for (var k = 0; k < count; k++) {
      final slot = offset + 2 + 12 * k;
      _checkRange(slot, 12, 'TIFF IFD entry');
      final tag = u16(slot);
      final type = u16(slot + 2);
      final valueCount = u32(slot + 4);
      entries[tag] = TiffEntry(tag, type, valueCount, slot);
    }
    final nextOffset = u32(offset + 2 + 12 * count);
    return (entries: entries, nextOffset: nextOffset);
  }

  /// The raw value bytes of an entry, following the value offset if needed.
  Uint8List raw(TiffEntry entry) {
    final size = (tiffTypeSizes[entry.type] ?? 1) * entry.count;
    if (size <= 0) {
      return Uint8List(0);
    }
    if (size <= 4) {
      final start = entry.slot + 8;
      _checkRange(start, size, 'TIFF inline value');
      return data.sublist(start, start + size);
    }
    final offset = u32(entry.slot + 8);
    _checkRange(offset, size, 'TIFF value');
    return data.sublist(offset, offset + size);
  }

  /// Write [value], padded with NULs to the entry's fixed size.
  void setBytes(TiffEntry entry, List<int> value) {
    final size = (tiffTypeSizes[entry.type] ?? 1) * entry.count;
    if (value.length > size) {
      throw ArgumentError(
        'tag 0x${entry.tag.toRadixString(16).toUpperCase().padLeft(4, '0')}: '
        'value does not fit (${value.length} > $size)',
      );
    }
    final int start;
    if (size <= 4) {
      start = entry.slot + 8;
      _checkRange(start, size, 'TIFF inline value');
    } else {
      start = u32(entry.slot + 8);
      _checkRange(start, size, 'TIFF value');
    }
    final padded = Uint8List(size)..setRange(0, value.length, value);
    data.setRange(start, start + size, padded);
  }

  /// Set an ASCII tag in place, if it exists in [entries].
  void setAscii(Map<int, TiffEntry> entries, int tag, String text) {
    final entry = entries[tag];
    if (entry == null) {
      return;
    }
    // Python's encode("ascii", "replace"): every non-ASCII scalar becomes '?'.
    final bytes = [for (final rune in text.runes) rune < 0x80 ? rune : 0x3F];
    setBytes(entry, bytes);
  }

  /// Set a LONG tag in place, if it exists in [entries].
  void setLong(Map<int, TiffEntry> entries, int tag, int value) {
    final entry = entries[tag];
    if (entry == null) {
      return;
    }
    if (value < 0 || value > 0xFFFFFFFF) {
      throw ArgumentError.value(value, 'value', 'does not fit in a TIFF LONG');
    }
    final bytes = Uint8List(4);
    if (littleEndian) {
      bytes[0] = value & 0xFF;
      bytes[1] = (value >> 8) & 0xFF;
      bytes[2] = (value >> 16) & 0xFF;
      bytes[3] = (value >> 24) & 0xFF;
    } else {
      bytes[0] = (value >> 24) & 0xFF;
      bytes[1] = (value >> 16) & 0xFF;
      bytes[2] = (value >> 8) & 0xFF;
      bytes[3] = value & 0xFF;
    }
    setBytes(entry, bytes);
  }

  /// Read a LONG tag (up to four raw bytes), or [fallback] if absent.
  int? getLong(Map<int, TiffEntry> entries, int tag, [int? fallback]) {
    final entry = entries[tag];
    if (entry == null) {
      return fallback;
    }
    final bytes = raw(entry);
    final n = bytes.length < 4 ? bytes.length : 4;
    var value = 0;
    if (littleEndian) {
      for (var i = n - 1; i >= 0; i--) {
        value = (value << 8) | bytes[i];
      }
    } else {
      for (var i = 0; i < n; i++) {
        value = (value << 8) | bytes[i];
      }
    }
    return value;
  }

  /// The Exif sub-IFD, or an empty map when IFD0 has no pointer.
  Map<int, TiffEntry> exifIfd() {
    final ifd0 = readIfd(u32(4)).entries;
    final offset = getLong(ifd0, tagExifIfd);
    if (offset == null || offset == 0) {
      return <int, TiffEntry>{};
    }
    return readIfd(offset).entries;
  }
}

Tiff? _parseApp1(Uint8List? app1) {
  if (app1 == null || app1.length < _exifHeader.length) {
    return null;
  }
  for (var i = 0; i < _exifHeader.length; i++) {
    if (app1[i] != _exifHeader[i]) {
      return null;
    }
  }
  try {
    return Tiff(app1.sublist(_exifHeader.length));
  } on FormatException {
    return null;
  }
}

String _asciiValue(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    if (byte == 0x00) {
      break;
    }
    buffer.writeCharCode(byte < 0x80 ? byte : 0xFFFD);
  }
  return buffer.toString();
}

int? _inlineLong(Tiff tiff, TiffEntry? entry) {
  if (entry == null) {
    return null;
  }
  final bytes = tiff.raw(entry);
  final n = bytes.length < 4 ? bytes.length : 4;
  var value = 0;
  if (tiff.littleEndian) {
    for (var i = n - 1; i >= 0; i--) {
      value = (value << 8) | bytes[i];
    }
  } else {
    for (var i = 0; i < n; i++) {
      value = (value << 8) | bytes[i];
    }
  }
  return value;
}

/// The handful of tags the tool prints and cross-checks.
class ExifSummary {
  final String? imageDescription;
  final String? make;
  final String? model;
  final String? software;
  final String? dateTime;
  final String? dateTimeOriginal;
  final int? pixelXDimension;
  final int? pixelYDimension;

  const ExifSummary({
    this.imageDescription,
    this.make,
    this.model,
    this.software,
    this.dateTime,
    this.dateTimeOriginal,
    this.pixelXDimension,
    this.pixelYDimension,
  });
}

/// Read the reportable tags from an APP1 payload; null if it is not EXIF or
/// the TIFF block is malformed.
ExifSummary? readExifSummary(Uint8List? app1) {
  final tiff = _parseApp1(app1);
  if (tiff == null) {
    return null;
  }
  try {
    final ifd0 = tiff.readIfd(tiff.u32(4)).entries;
    final exif = tiff.exifIfd();

    String? ascii(Map<int, TiffEntry> entries, int tag) {
      final entry = entries[tag];
      return entry == null ? null : _asciiValue(tiff.raw(entry));
    }

    return ExifSummary(
      imageDescription: ascii(ifd0, tagImageDescription),
      make: ascii(ifd0, tagMake),
      model: ascii(ifd0, tagModel),
      software: ascii(ifd0, tagSoftware),
      dateTime: ascii(ifd0, tagDateTime),
      dateTimeOriginal: ascii(exif, tagDateTimeOriginal),
      pixelXDimension: _inlineLong(tiff, exif[tagPixelX]),
      pixelYDimension: _inlineLong(tiff, exif[tagPixelY]),
    );
  } on FormatException {
    return null;
  }
}

/// An EXIF thumbnail: the embedded JPEG, its SOF dimensions and its exact
/// byte range inside the TIFF block.
class ExifThumbnail {
  final Uint8List jpeg;
  final int width;
  final int height;
  final int offset;
  final int length;

  const ExifThumbnail({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.offset,
    required this.length,
  });
}

/// Extract IFD1's embedded thumbnail. Dimensions come from the embedded
/// JPEG's SOF header — no image decoding.
ExifThumbnail? extractExifThumbnail(Uint8List app1) {
  final tiff = _parseApp1(app1);
  if (tiff == null) {
    return null;
  }
  try {
    final ifd0 = tiff.readIfd(tiff.u32(4));
    if (ifd0.nextOffset == 0) {
      return null;
    }
    final ifd1 = tiff.readIfd(ifd0.nextOffset).entries;
    final offset = tiff.getLong(ifd1, tagThumbOffset);
    final length = tiff.getLong(ifd1, tagThumbLength);
    if (offset == null ||
        length == null ||
        offset == 0 ||
        length == 0 ||
        offset + length > tiff.data.length) {
      return null;
    }

    final blob = tiff.data.sublist(offset, offset + length);
    final size = jpegDimensions(blob);
    return ExifThumbnail(
      jpeg: blob,
      width: size.width,
      height: size.height,
      offset: offset,
      length: length,
    );
  } on FormatException {
    return null;
  }
}

String _formatExifDateTime(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}:${two(value.month)}:'
      '${two(value.day)} ${two(value.hour)}:${two(value.minute)}:'
      '${two(value.second)}';
}

/// Take the template's APP1 and replace the photo-specific fields in place.
///
/// The byte layout — including the MakerNote — is preserved. When [thumbnail]
/// is given and the old thumbnail is the very last bytes of the TIFF block, it
/// is replaced and `JPEGInterchangeFormatLength` is patched; otherwise the
/// original thumbnail is kept rather than corrupting the offsets.
Uint8List patchExif(
  Uint8List app1, {
  required String filename,
  required DateTime dateTime,
  required int width,
  required int height,
  Uint8List? thumbnail,
}) {
  final tiff = _parseApp1(app1);
  if (tiff == null) {
    return app1;
  }

  final ifd0 = tiff.readIfd(tiff.u32(4));
  final exif = tiff.exifIfd();
  final dateText = _formatExifDateTime(dateTime);

  tiff.setAscii(ifd0.entries, tagImageDescription, filename);
  tiff.setAscii(ifd0.entries, tagDateTime, dateText);
  tiff.setAscii(exif, tagDateTimeOriginal, dateText);
  tiff.setAscii(exif, tagDateTimeDigitized, dateText);
  tiff.setLong(exif, tagPixelX, width);
  tiff.setLong(exif, tagPixelY, height);

  if (thumbnail != null && thumbnail.isNotEmpty && ifd0.nextOffset != 0) {
    final ifd1 = tiff.readIfd(ifd0.nextOffset).entries;
    final offset = tiff.getLong(ifd1, tagThumbOffset);
    final length = tiff.getLong(ifd1, tagThumbLength);
    if (offset != null &&
        length != null &&
        offset > 0 &&
        length > 0 &&
        offset + length == tiff.data.length) {
      // The camera stores the thumbnail as the very last bytes of the block,
      // so a different-sized one can simply replace it.
      tiff.setLong(ifd1, tagThumbLength, thumbnail.length);
      tiff.data = Uint8List.fromList([
        ...tiff.data.sublist(0, offset),
        ...thumbnail,
      ]);
    }
    // else: keep the original thumbnail rather than corrupt the offsets
  }

  final out = Uint8List(_exifHeader.length + tiff.data.length);
  out.setRange(0, _exifHeader.length, _exifHeader);
  out.setRange(_exifHeader.length, out.length, tiff.data);
  return out;
}
