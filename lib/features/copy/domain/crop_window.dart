import 'package:flutter/foundation.dart';

/// The output frame the copy engine builds: the camera's 12.6 MP 4:3 mode
/// (4096 × 3072 on the tested GO Ultra).
///
/// The copy engine currently always picks the smallest camera mode, which is
/// this 4:3 mode. If mode selection starts matching the source aspect, the
/// editor and the engine must agree on the new frame ratio.
const double cameraFrameAspect = 4 / 3;

/// The part of the source photo that is kept, in oriented source coordinates.
///
/// All values are fractions of the image's width/height (0…1), with the origin
/// at the top-left. The rect's *pixel* aspect is [cameraFrameAspect]; its
/// normalized width/height are only equal for a 4:3 source.
@immutable
class CropWindow {
  const CropWindow({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// The whole photo.
  static const CropWindow full = CropWindow(
    left: 0,
    top: 0,
    width: 1,
    height: 1,
  );

  final double left;
  final double top;
  final double width;
  final double height;

  static const double _epsilon = 1e-6;

  bool get isValid =>
      left.isFinite &&
      top.isFinite &&
      width.isFinite &&
      height.isFinite &&
      left >= -_epsilon &&
      top >= -_epsilon &&
      width > 0 &&
      height > 0 &&
      left + width <= 1 + _epsilon &&
      top + height <= 1 + _epsilon;

  /// The largest [targetAspect] crop centered in an image of [imageAspect].
  ///
  /// This is what the review screen starts with, and what a native "crop"
  /// operation used to do unconditionally.
  factory CropWindow.centered({
    required double imageAspect,
    double targetAspect = cameraFrameAspect,
  }) {
    if (!imageAspect.isFinite ||
        imageAspect <= 0 ||
        !targetAspect.isFinite ||
        targetAspect <= 0) {
      return full;
    }
    if (imageAspect > targetAspect) {
      final w = targetAspect / imageAspect;
      return CropWindow(left: (1 - w) / 2, top: 0, width: w, height: 1);
    }
    final h = imageAspect / targetAspect;
    return CropWindow(left: 0, top: (1 - h) / 2, width: 1, height: h);
  }

  /// Clamps the rect into the image without changing valid input.
  CropWindow clamp() {
    if (!left.isFinite ||
        !top.isFinite ||
        !width.isFinite ||
        !height.isFinite) {
      return full;
    }
    final l = left.clamp(0.0, 1.0);
    final t = top.clamp(0.0, 1.0);
    final r = (left + width).clamp(l, 1.0);
    final b = (top + height).clamp(t, 1.0);
    return CropWindow(left: l, top: t, width: r - l, height: b - t);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CropWindow &&
          other.left == left &&
          other.top == top &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() =>
      'CropWindow(left: $left, top: $top, width: $width, height: $height)';
}
