import 'dart:async';

import 'package:flutter/painting.dart' show ImageProvider;
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../domain/gallery_access.dart';
import '../domain/gallery_repository.dart';
import '../domain/photo_asset.dart';
import '../domain/photo_page.dart';
import 'device_media_service.dart';

/// [GalleryRepository] backed by the device MediaStore / PhotoKit library.
class PhotoManagerGalleryRepository implements GalleryRepository {
  PhotoManagerGalleryRepository({DeviceMediaService? service})
    : _service = service ?? const DeviceMediaService();

  final DeviceMediaService _service;

  /// Assets are needed again to resolve thumbnails, which happens in the
  /// widget tree and cannot be async. Pages are small, so this stays bounded.
  final Map<String, AssetEntity> _assetsById = <String, AssetEntity>{};
  AssetPathEntity? _recentPath;

  @override
  Future<GalleryAccess> currentAccess() async =>
      _mapAccess(await _service.permissionState());

  @override
  Future<GalleryAccess> requestAccess() async =>
      _mapAccess(await _service.requestPermission());

  @override
  Future<void> openSystemSettings() => _service.openSettings();

  @override
  Future<void> presentLimitedSelection() => _service.presentLimitedSelection();

  @override
  Future<PhotoPage> photos({required int offset, required int limit}) async {
    final access = await currentAccess();
    if (!access.canBrowse) throw GalleryAccessException(access);

    final path = _recentPath ??= await _service.recentPhotosPath();
    if (path == null) {
      return const PhotoPage(photos: <PhotoAsset>[], totalCount: 0);
    }

    final total = await _service.assetCount(path);
    if (offset >= total || limit <= 0) {
      return PhotoPage(photos: const <PhotoAsset>[], totalCount: total);
    }

    final entities = await _service.assets(path, offset: offset, limit: limit);

    final photos = <PhotoAsset>[];
    for (final entity in entities) {
      final photo = _toPhoto(entity);
      if (photo == null) continue;
      _assetsById[photo.id] = entity;
      photos.add(photo);
    }
    return PhotoPage(photos: photos, totalCount: total);
  }

  @override
  Future<String?> originalPath(PhotoAsset photo) async {
    final entity = _assetsById[photo.id];
    if (entity == null) return null;
    try {
      final file = await entity.file;
      return file?.path;
    } catch (_) {
      return null;
    }
  }

  @override
  ImageProvider? thumbnailFor(PhotoAsset photo, {required int cacheSize}) {
    final entity = _assetsById[photo.id];
    if (entity == null) return null;
    final size = cacheSize.clamp(32, 2048).toInt();
    return AssetEntityImageProvider(
      entity,
      isOriginal: false,
      thumbnailSize: ThumbnailSize.square(size),
    );
  }

  @override
  void clearThumbnailCache() {
    _assetsById.clear();
    _recentPath = null;
    unawaited(PhotoManager.clearFileCache());
  }

  PhotoAsset? _toPhoto(AssetEntity entity) {
    if (entity.width <= 0 || entity.height <= 0) return null;
    return PhotoAsset(
      id: entity.id,
      width: entity.width,
      height: entity.height,
      createdAt: entity.createDateTime,
    );
  }

  GalleryAccess _mapAccess(PermissionState state) {
    return switch (state) {
      PermissionState.authorized => GalleryAccess.granted,
      PermissionState.limited => GalleryAccess.limited,
      PermissionState.denied => GalleryAccess.denied,
      PermissionState.restricted => GalleryAccess.restricted,
      PermissionState.notDetermined => GalleryAccess.unknown,
    };
  }
}
