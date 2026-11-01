import 'package:flutter/services.dart';

import '../domain/camera_image_pipeline.dart';

/// [CameraImagePipeline] over `CameraImageChannel.kt`.
class CameraImageService implements CameraImagePipeline {
  const CameraImageService([
    MethodChannel channel = const MethodChannel(channelName),
  ]) : _channel = channel;

  static const String channelName =
      'insta360_print_anything_mobile/camera_images';

  final MethodChannel _channel;

  @override
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
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'prepare',
        <String, Object?>{
          'sourcePath': sourcePath,
          'width': width,
          'height': height,
          'previewWidth': previewWidth,
          'previewHeight': previewHeight,
          'thumbWidth': thumbWidth,
          'thumbHeight': thumbHeight,
          'lumaZigzag': lumaZigzag,
          'chromaZigzag': chromaZigzag,
          'fit': fit.nativeValue,
        },
      );
      if (raw == null) {
        throw const CameraImageException(
          'The image pipeline returned nothing.',
        );
      }
      final main = raw['mainJpeg'];
      final preview = raw['previewJpeg'];
      final thumb = raw['thumbnailJpeg'];
      final nv21 = raw['nv21'];
      if (main is! Uint8List ||
          preview is! Uint8List ||
          thumb is! Uint8List ||
          nv21 is! Uint8List) {
        throw const CameraImageException(
          'The image pipeline returned malformed data.',
        );
      }
      return PreparedCameraImages(
        mainJpeg: main,
        previewJpeg: preview,
        thumbnailJpeg: thumb,
        nv21: nv21,
        width: raw['width'] as int? ?? width,
        height: raw['height'] as int? ?? height,
      );
    } on PlatformException catch (error) {
      throw CameraImageException(
        error.message ?? 'The photo could not be processed.',
      );
    } on MissingPluginException {
      throw const CameraImageException(
        'Photo processing is only available on Android.',
      );
    }
  }

  @override
  Future<({int width, int height})> jpegInfo(Uint8List bytes) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'jpegInfo',
        <String, Object?>{'bytes': bytes},
      );
      return (
        width: raw?['width'] as int? ?? 0,
        height: raw?['height'] as int? ?? 0,
      );
    } on PlatformException {
      return (width: 0, height: 0);
    } on MissingPluginException {
      return (width: 0, height: 0);
    }
  }
}
