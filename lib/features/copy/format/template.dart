/// Reading a camera photo as a template.
///
/// A [CameraTemplate] is everything the clone needs from a real GO Ultra
/// photo: the EXIF block, the hidden preview, the quantisation tables and the
/// proprietary trailer. It can come from an on-device sample or — preferably —
/// from a photo already on the connected camera, which carries that camera's
/// own serial and calibration.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'exif.dart';
import 'jpeg.dart';
import 'meta.dart';

/// A real camera photo, decomposed into the parts the clone reuses.
class CameraTemplate {
  final String fileName;
  final int width;
  final int height;
  final List<JpegSegment> segments;
  final Uint8List? app1;
  final Uint8List? preview;
  final int? previewWidth;
  final int? previewHeight;
  final Uint8List? thumbnail;
  final int? thumbnailWidth;
  final int? thumbnailHeight;

  /// Quantisation tables in Pillow's natural order.
  final List<List<int>> qtables;
  final Uint8List? dqtPayload;
  final Uint8List trailer;
  final String? model;
  final String? serial;
  final String? uid;
  final String? firmware;
  final DateTime? captured;

  CameraTemplate({
    required this.fileName,
    required this.width,
    required this.height,
    required this.segments,
    this.app1,
    this.preview,
    this.previewWidth,
    this.previewHeight,
    this.thumbnail,
    this.thumbnailWidth,
    this.thumbnailHeight,
    List<List<int>>? qtables,
    this.dqtPayload,
    Uint8List? trailer,
    this.model,
    this.serial,
    this.uid,
    this.firmware,
    this.captured,
  }) : qtables = qtables ?? const [],
       trailer = trailer ?? _emptyTrailer;

  static final Uint8List _emptyTrailer = Uint8List(0);

  /// A real camera original: it has a trailer and names an Insta360 body.
  bool get isCameraPhoto =>
      trailer.isNotEmpty && (model?.contains('Insta360') ?? false);

  double get aspect => height != 0 ? width / height : 0.0;
}

bool _startsWith(Uint8List data, List<int> prefix) {
  if (data.length < prefix.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

/// Read a JPEG and extract everything the clone needs.
CameraTemplate analyseTemplate(Uint8List data, {required String fileName}) {
  final layout = splitMarkers(data);
  final trailer = data.sublist(bodyEnd(data));
  final dimensions = jpegDimensions(data);

  Uint8List? app1;
  Uint8List? dqtPayload;
  for (final segment in layout.segments) {
    if (segment.marker == 0xE1 &&
        _startsWith(segment.payload, const [0x45, 0x78, 0x69, 0x66])) {
      app1 ??= segment.payload;
    } else if (segment.marker == 0xDB) {
      dqtPayload ??= segment.payload;
    }
  }

  final preview = embeddedPreview(data);
  int? previewWidth;
  int? previewHeight;
  if (preview != null) {
    try {
      final size = jpegDimensions(preview);
      previewWidth = size.width;
      previewHeight = size.height;
    } on FormatException {
      // A broken hidden preview does not make the rest unusable.
    }
  }

  Uint8List? thumbnail;
  int? thumbnailWidth;
  int? thumbnailHeight;
  if (app1 != null) {
    final extracted = extractExifThumbnail(app1);
    if (extracted != null) {
      thumbnail = extracted.jpeg;
      thumbnailWidth = extracted.width;
      thumbnailHeight = extracted.height;
    }
  }

  String? model;
  String? serial;
  String? uid;
  String? firmware;
  DateTime? captured;
  if (trailer.isNotEmpty) {
    final text = latin1.decode(trailer);
    final modelMatch = RegExp(r'Insta360 [A-Za-z0-9 ]{1,20}').firstMatch(text);
    model = modelMatch?.group(0)?.trim();
    final firmwareMatch = RegExp(r'v\d+\.\d+\.\d+_build\d+').firstMatch(text);
    firmware = firmwareMatch?.group(0);
    serial = serialOf(trailer);
    uid = uidOf(trailer);
    captured = captureTime(trailer);
  }

  return CameraTemplate(
    fileName: fileName,
    width: dimensions.width,
    height: dimensions.height,
    segments: layout.segments,
    app1: app1,
    preview: preview,
    previewWidth: previewWidth,
    previewHeight: previewHeight,
    thumbnail: thumbnail,
    thumbnailWidth: thumbnailWidth,
    thumbnailHeight: thumbnailHeight,
    qtables: dqtPayload == null ? const [] : jpegQTables(data),
    dqtPayload: dqtPayload,
    trailer: trailer,
    model: model,
    serial: serial,
    uid: uid,
    firmware: firmware,
    captured: captured,
  );
}

String _compactTimestamp(DateTime dt) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}${two(dt.month)}${two(dt.day)}'
      '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
}

/// Choose the template whose aspect ratio is closest to the source image.
///
/// The score mirrors the Python tool: aspect distance, a small area tie-break
/// (prefer the smaller mode), a large penalty for a template without trailer
/// metadata and a small penalty when the capture time disagrees with the file
/// name (probably not a camera original).
CameraTemplate pickTemplate(
  List<CameraTemplate> templates, {
  required int wantWidth,
  required int wantHeight,
}) {
  if (templates.isEmpty) {
    throw ArgumentError('no templates to choose from');
  }
  final wantAspect = wantHeight != 0 ? wantWidth / wantHeight : 0.0;

  double score(CameraTemplate template) {
    var result = (template.aspect - wantAspect).abs();
    result += (template.width * template.height) / 1e12;
    if (template.trailer.isEmpty) {
      result += 10.0;
    }
    final captured = template.captured;
    if (captured != null) {
      final digits = template.fileName.replaceAll(RegExp(r'\D'), '');
      final nameTime = digits.length > 14 ? digits.substring(0, 14) : digits;
      if (_compactTimestamp(captured) != nameTime) {
        result += 0.5;
      }
    }
    return result;
  }

  var best = templates.first;
  var bestScore = score(best);
  for (var i = 1; i < templates.length; i++) {
    final candidate = templates[i];
    final candidateScore = score(candidate);
    if (candidateScore < bestScore) {
      best = candidate;
      bestScore = candidateScore;
    }
  }
  return best;
}
