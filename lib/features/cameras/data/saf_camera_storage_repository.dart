import 'dart:typed_data';

import '../domain/camera_storage.dart';
import '../domain/usb_camera.dart';
import 'camera_storage_service.dart';

/// [CameraStorage] over one SAF tree grant.
class SafCameraStorage implements CameraStorage {
  SafCameraStorage(this._service, {required this.treeUri, required this.label});

  final CameraStorageService _service;

  @override
  final String treeUri;

  @override
  final String label;

  @override
  Future<List<RemoteFile>> list(String relativeDir) async {
    final raw = await _service.list(treeUri, relativeDir);
    return raw.map(RemoteFile.fromPlatformMap).toList(growable: false);
  }

  @override
  Future<Uint8List?> read(String relativePath) =>
      _service.read(treeUri, relativePath);

  @override
  Future<void> write(String relativePath, Uint8List bytes) =>
      _service.write(treeUri, relativePath, bytes);

  @override
  Future<void> delete(String relativePath) =>
      _service.delete(treeUri, relativePath);

  @override
  Future<bool> exists(String relativePath) =>
      _service.exists(treeUri, relativePath);
}

/// SAF-backed [CameraStorageRepository].
///
/// The grant is remembered per camera model (VID:PID), so selecting the camera
/// again does not re-open the folder picker. A grant that no longer covers the
/// camera's `DCIM/fileinfo_list.list` is rejected and forgotten, so swapping
/// camera bodies or reformatting the card cannot silently write into the wrong
/// volume.
class SafCameraStorageRepository implements CameraStorageRepository {
  SafCameraStorageRepository({CameraStorageService? service})
    : _service = service ?? const CameraStorageService();

  final CameraStorageService _service;

  static const String indexRelativePath = CameraStoragePaths.index;

  @override
  Future<CameraStorage?> grantedStorageFor(UsbCamera camera) async {
    try {
      final uri = await _service.rememberedTree(_cameraKey(camera));
      if (uri == null) return null;
      final info = await _service.treeInfo(uri);
      if (info['writable'] == false) return null;
      final storage = SafCameraStorage(
        _service,
        treeUri: uri,
        label: (info['label'] as String?) ?? 'camera storage',
      );
      // A remembered grant can outlive the volume it pointed at.
      if (!await storage.exists(indexRelativePath)) return null;
      return storage;
    } on CameraStorageException {
      return null;
    }
  }

  @override
  Future<CameraStorage?> requestStorageFor(UsbCamera camera) async {
    final key = _cameraKey(camera);
    final previous = await _service.rememberedTree(key);
    final uri = await _service.pickTree(initialUri: previous);
    if (uri == null) return null;

    await _service.rememberTree(key, uri);
    final info = await _service.treeInfo(uri);
    if (info['writable'] == false) {
      await _service.forgetTree(key);
      throw const CameraStorageException(
        'That folder is read-only. Pick the camera drive itself.',
        code: 'read_only',
      );
    }

    final storage = SafCameraStorage(
      _service,
      treeUri: uri,
      label: (info['label'] as String?) ?? 'camera storage',
    );

    if (!await storage.exists(indexRelativePath)) {
      await _service.forgetTree(key);
      throw const CameraStorageException(
        'That folder does not look like the camera storage. Pick the drive '
        'itself, the one containing DCIM.',
        code: 'not_camera',
      );
    }
    return storage;
  }

  String _cameraKey(UsbCamera camera) =>
      '${camera.vendorId}:${camera.productId}';
}
