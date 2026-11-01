import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'features/cameras/domain/camera_repository.dart';
import 'features/cameras/domain/camera_storage.dart';
import 'features/copy/domain/copy_engine.dart';
import 'features/gallery/domain/gallery_repository.dart';
import 'features/gallery/presentation/gallery_page.dart';

/// App shell: theme + the gallery route.
class Insta360PrintApp extends StatelessWidget {
  const Insta360PrintApp({
    super.key,
    required this.galleryRepository,
    required this.cameraRepository,
    required this.storageRepository,
    required this.copyEngine,
  });

  final GalleryRepository galleryRepository;
  final CameraRepository cameraRepository;
  final CameraStorageRepository storageRepository;
  final CopyEngine copyEngine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Insta360 Print',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: GalleryPage(
        galleryRepository: galleryRepository,
        cameraRepository: cameraRepository,
        storageRepository: storageRepository,
        copyEngine: copyEngine,
      ),
    );
  }
}
