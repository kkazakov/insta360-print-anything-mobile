import 'package:flutter/painting.dart' show ImageProvider;

import 'gallery_access.dart';
import 'photo_asset.dart';
import 'photo_page.dart';

/// Single source of truth for the device gallery.
///
/// The gallery plugin lives behind this interface so the UI and the view model
/// stay testable and so the copy flow can ask for the selected asset's data
/// without knowing how it is stored.
abstract interface class GalleryRepository {
  /// Reads the current permission without prompting.
  Future<GalleryAccess> currentAccess();

  /// Shows the system permission prompt and returns the resulting access.
  Future<GalleryAccess> requestAccess();

  /// Opens the OS settings page for this app.
  Future<void> openSystemSettings();

  /// Re-opens the "select photos" picker for a limited grant
  /// (iOS 14+, Android 14+). A no-op elsewhere.
  Future<void> presentLimitedSelection();

  /// Newest-first page of photos. Throws [GalleryAccessException] when the
  /// permission is missing, so a revoked grant cannot be mistaken for an
  /// empty library.
  Future<PhotoPage> photos({required int offset, required int limit});

  /// Path to the original file on disk, when the platform can provide one.
  ///
  /// The copy pipeline decodes the original natively; cloud-only or
  /// unavailable assets return null.
  Future<String?> originalPath(PhotoAsset photo);

  /// Decoded-thumbnail provider for [photo], sized for roughly
  /// [cacheSize] physical pixels. Null when the asset is no longer cached.
  ImageProvider? thumbnailFor(PhotoAsset photo, {required int cacheSize});

  /// Drops the in-memory asset/thumbnail bookkeeping.
  void clearThumbnailCache();
}

/// Thrown when photos are requested without a usable permission.
class GalleryAccessException implements Exception {
  const GalleryAccessException(this.access);

  final GalleryAccess access;

  @override
  String toString() => 'GalleryAccessException(${access.name})';
}
