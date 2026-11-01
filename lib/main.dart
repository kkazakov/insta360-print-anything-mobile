import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'app.dart';
import 'features/cameras/data/saf_camera_storage_repository.dart';
import 'features/cameras/data/usb_camera_repository.dart';
import 'features/copy/data/camera_copy_engine.dart';
import 'features/copy/data/camera_image_service.dart';
import 'features/gallery/data/photo_manager_gallery_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // The gallery plugin caches originals/thumbnails under the app cache dir;
  // drop stale files from previous sessions so they cannot grow unbounded.
  unawaited(PhotoManager.clearFileCache());

  final gallery = PhotoManagerGalleryRepository();
  final images = const CameraImageService();

  runApp(
    Insta360PrintApp(
      galleryRepository: gallery,
      cameraRepository: UsbCameraRepository(),
      storageRepository: SafCameraStorageRepository(),
      copyEngine: CameraCopyEngine(gallery, images),
    ),
  );
}
