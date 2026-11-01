import 'package:flutter/foundation.dart';

/// One image in the device photo library.
///
/// A deliberately small projection of the platform asset: the grid and the
/// copy flow need the identity, the pixel size and the capture date, nothing
/// else. Thumbnails are resolved through the repository.
@immutable
class PhotoAsset {
  const PhotoAsset({
    required this.id,
    required this.width,
    required this.height,
    this.createdAt,
  });

  /// Stable platform identifier (MediaStore `_id` on Android).
  final String id;

  final int width;
  final int height;

  /// Capture time when the platform reports one.
  final DateTime? createdAt;

  bool get isLandscape => width >= height;

  /// Width divided by height, clamped so a broken 0x0 asset cannot produce an
  /// invalid aspect ratio.
  double get aspectRatio {
    if (width <= 0 || height <= 0) return 1;
    return width / height;
  }

  double get megapixels => (width * height) / 1000000;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is PhotoAsset && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PhotoAsset($id, ${width}x$height)';
}
