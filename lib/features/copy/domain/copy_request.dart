import 'package:flutter/foundation.dart';

import '../../cameras/domain/camera_storage.dart';
import '../../cameras/domain/usb_camera.dart';
import '../../gallery/domain/photo_asset.dart';
import 'camera_image_pipeline.dart';
import 'crop_window.dart';

/// A request to place [photo] on [camera] so it shows up in the camera's own
/// gallery, exactly like a photo the camera took itself.
@immutable
class CopyRequest {
  const CopyRequest({
    required this.photo,
    required this.camera,
    this.storage,
    this.fit = CopyFit.crop,
    this.crop,
  });

  final PhotoAsset photo;
  final UsbCamera camera;

  /// SAF access to the camera's mounted storage; null when not granted yet.
  final CameraStorage? storage;

  /// How the photo is mapped onto the camera's frame.
  final CopyFit fit;

  /// The part of the photo to keep when [fit] is [CopyFit.crop].
  ///
  /// Null means the native pipeline's centered default crop. When [fit] is
  /// [CopyFit.pad] this is ignored.
  final CropWindow? crop;
}
