import 'package:flutter/foundation.dart';

import 'crop_window.dart';

/// The three JPEG renditions plus the raw gallery buffer produced natively.
@immutable
class PreparedCameraImages {
  const PreparedCameraImages({
    required this.mainJpeg,
    required this.previewJpeg,
    required this.thumbnailJpeg,
    required this.nv21,
    required this.width,
    required this.height,
  });

  final Uint8List mainJpeg;
  final Uint8List previewJpeg;
  final Uint8List thumbnailJpeg;

  /// Raw gallery thumbnail in the camera's buffer layout.
  final Uint8List nv21;

  final int width;
  final int height;
}

/// How the selected photo is mapped onto the camera's frame.
enum CopyFit {
  /// Cover the frame and crop the overflow (the reference tool's default).
  crop,

  /// Fit the whole photo and letterbox with black bars.
  pad;

  String get nativeValue => name;
}

/// Native pixel pipeline: decode, fit, encode with the camera's DQT.
abstract interface class CameraImagePipeline {
  Future<PreparedCameraImages> prepare({
    required String sourcePath,
    required int width,
    required int height,
    required int previewWidth,
    required int previewHeight,
    required int thumbWidth,
    required int thumbHeight,
    required List<int> lumaZigzag,
    required List<int> chromaZigzag,
    required CopyFit fit,
    CropWindow? crop,
  });

  /// Bounds-only decode check for produced JPEG bytes.
  Future<({int width, int height})> jpegInfo(Uint8List bytes);
}

/// The pixel pipeline failed (unsupported source, decoder error, …).
class CameraImageException implements Exception {
  const CameraImageException(this.message);

  final String message;

  @override
  String toString() => 'CameraImageException: $message';
}
