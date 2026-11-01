import 'dart:typed_data';

import 'package:flutter/painting.dart' show ImageProvider;
import 'package:insta360_print_anything_mobile/features/cameras/domain/camera_repository.dart';
import 'package:insta360_print_anything_mobile/features/cameras/domain/camera_storage.dart';
import 'package:insta360_print_anything_mobile/features/cameras/domain/usb_camera.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/copy_engine.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/copy_request.dart';
import 'package:insta360_print_anything_mobile/features/gallery/domain/gallery_access.dart';
import 'package:insta360_print_anything_mobile/features/gallery/domain/gallery_repository.dart';
import 'package:insta360_print_anything_mobile/features/gallery/domain/photo_asset.dart';
import 'package:insta360_print_anything_mobile/features/gallery/domain/photo_page.dart';

/// In-memory gallery repository: no plugins, no platform channels.
class FakeGalleryRepository implements GalleryRepository {
  FakeGalleryRepository({
    this.access = GalleryAccess.granted,
    this.onRequest,
    List<PhotoAsset>? photos,
    this.totalCount,
    this.error,
    this.pageDelay,
  }) : assets = photos ?? <PhotoAsset>[];

  GalleryAccess access;

  /// What [requestAccess] resolves to; unchanged when null.
  GalleryAccess? onRequest;

  List<PhotoAsset> assets;
  int? totalCount;
  Object? error;
  Duration? pageDelay;

  /// Returned by [originalPath]; null unless a test sets a real file.
  String? sourcePath;

  /// Simulates the user revoking photo access while the page is being read.
  bool loseAccessOnPage = false;

  int requestCount = 0;
  int settingsCount = 0;
  int limitedSelectionCount = 0;
  int pageCount = 0;

  @override
  Future<GalleryAccess> currentAccess() async => access;

  @override
  Future<GalleryAccess> requestAccess() async {
    requestCount++;
    final next = onRequest ?? access;
    access = next;
    return next;
  }

  @override
  Future<void> openSystemSettings() async => settingsCount++;

  @override
  Future<void> presentLimitedSelection() async => limitedSelectionCount++;

  @override
  Future<PhotoPage> photos({required int offset, required int limit}) async {
    pageCount++;
    final delay = pageDelay;
    if (delay != null) await Future<void>.delayed(delay);
    final failure = error;
    if (failure != null) throw failure;
    if (loseAccessOnPage) {
      access = GalleryAccess.denied;
      throw GalleryAccessException(access);
    }
    if (!access.canBrowse) throw GalleryAccessException(access);

    final total = totalCount ?? assets.length;
    final end = (offset + limit) > assets.length
        ? assets.length
        : offset + limit;
    if (offset >= assets.length) {
      return PhotoPage(photos: const <PhotoAsset>[], totalCount: total);
    }
    return PhotoPage(photos: assets.sublist(offset, end), totalCount: total);
  }

  @override
  Future<String?> originalPath(PhotoAsset photo) async => sourcePath;

  @override
  ImageProvider? thumbnailFor(PhotoAsset photo, {required int cacheSize}) =>
      null;

  @override
  void clearThumbnailCache() {}
}

/// In-memory USB camera repository.
class FakeCameraRepository implements CameraRepository {
  FakeCameraRepository({
    this.supported = true,
    List<UsbCamera>? cameras,
    this.permissionResult = true,
    this.error,
  }) : cameras = cameras ?? <UsbCamera>[];

  bool supported;
  List<UsbCamera> cameras;
  bool permissionResult;
  Object? error;

  int permissionRequests = 0;
  int scanCount = 0;

  @override
  Future<bool> supportsUsbHost() async => supported;

  @override
  Future<List<UsbCamera>> connectedCameras() async {
    scanCount++;
    final failure = error;
    if (failure != null) throw failure;
    return List<UsbCamera>.of(cameras);
  }

  @override
  Future<bool> requestPermission(UsbCamera camera) async {
    permissionRequests++;
    return permissionResult;
  }
}

/// Copy engine double that records the request and returns a canned result.
class FakeCopyEngine implements CopyEngine {
  FakeCopyEngine({
    this.unavailableReason,
    this.result = const CopyResult.success(message: 'Copied'),
  });

  @override
  String? unavailableReason;

  CopyResult result;

  int copyCount = 0;
  CopyRequest? lastRequest;

  @override
  Future<CopyResult> copy(
    CopyRequest request, {
    void Function(CopyProgress progress)? onProgress,
  }) async {
    copyCount++;
    lastRequest = request;
    return result;
  }
}

/// In-memory camera storage with the camera index already present.
class FakeCameraStorage implements CameraStorage {
  FakeCameraStorage({
    this.treeUri =
        'content://com.android.externalstorage.documents/tree/4A21-0000%3A',
    this.label = 'disk',
    Map<String, Uint8List>? files,
  }) : files =
           files ??
           <String, Uint8List>{
             CameraStoragePaths.index: Uint8List.fromList(<int>[1, 2, 3]),
             'DCIM/Camera01/IMG_20261101_085513_004.jpg': Uint8List(16),
           };

  @override
  final String treeUri;

  @override
  final String label;

  final Map<String, Uint8List> files;
  final Set<String> failingWrites = <String>{};
  int writeCount = 0;

  @override
  Future<List<RemoteFile>> list(String relativeDir) async {
    final prefix = relativeDir.isEmpty ? '' : '${relativeDir.trim()}/';
    return files.entries
        .where((entry) {
          if (!entry.key.startsWith(prefix)) return false;
          return !entry.key.substring(prefix.length).contains('/');
        })
        .map((entry) {
          final name = entry.key.substring(prefix.length);
          return RemoteFile(
            name: name,
            path: entry.key,
            isDirectory: false,
            size: entry.value.length,
          );
        })
        .toList();
  }

  @override
  Future<Uint8List?> read(String relativePath) async => files[relativePath];

  @override
  Future<void> write(String relativePath, Uint8List bytes) async {
    writeCount++;
    if (failingWrites.contains(relativePath)) {
      throw CameraStorageException(
        'simulated write failure: $relativePath',
        code: 'storage_error',
      );
    }
    files[relativePath] = bytes;
  }

  @override
  Future<void> delete(String relativePath) async {
    files.remove(relativePath);
  }

  @override
  Future<bool> exists(String relativePath) async =>
      files.containsKey(relativePath);
}

/// In-memory storage repository; [storage] is granted by default.
class FakeCameraStorageRepository implements CameraStorageRepository {
  FakeCameraStorageRepository({
    FakeCameraStorage? storage,
    bool grant = true,
    this.grantOnRequest = true,
    this.requestError,
  }) : storage = storage ?? (grant ? FakeCameraStorage() : null);

  FakeCameraStorage? storage;
  bool grantOnRequest;
  CameraStorageException? requestError;

  int requestCount = 0;

  @override
  Future<CameraStorage?> grantedStorageFor(camera) async => storage;

  @override
  Future<CameraStorage?> requestStorageFor(camera) async {
    requestCount++;
    final failure = requestError;
    if (failure != null) throw failure;
    if (!grantOnRequest) return null;
    storage ??= FakeCameraStorage();
    return storage;
  }
}

/// Builds [count] distinct fake photos, newest first.
List<PhotoAsset> makePhotos(int count) {
  final newest = DateTime(2026, 11, 1, 12);
  return List<PhotoAsset>.generate(count, (index) {
    return PhotoAsset(
      id: 'photo-$index',
      width: index.isEven ? 4032 : 3024,
      height: index.isEven ? 3024 : 4032,
      createdAt: newest.subtract(Duration(hours: index)),
    );
  });
}

/// A camera as the Android channel reports an Insta360 GO Ultra.
UsbCamera makeCamera({
  String deviceId = '/dev/bus/usb/001/004',
  bool permissionGranted = false,
}) {
  return UsbCamera(
    deviceId: deviceId,
    vendorId: 0x1234,
    productId: 0x5678,
    name: 'Insta360 GO Ultra',
    manufacturer: 'Arashi Vision',
    product: 'Insta360 GO Ultra',
    serialNumber: 'IBEXAMPLE00001',
    massStorage: true,
    permissionGranted: permissionGranted,
    isInsta360: true,
  );
}
