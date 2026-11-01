import 'package:flutter/foundation.dart';

import 'usb_camera.dart';

/// One entry in the camera's mounted storage.
@immutable
class RemoteFile {
  const RemoteFile({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.lastModified,
  });

  /// Display name, e.g. `IMG_20261101_085513_004.jpg`.
  final String name;

  /// Path relative to the granted tree root, `/`-separated.
  final String path;

  final bool isDirectory;
  final int? size;
  final DateTime? lastModified;

  factory RemoteFile.fromPlatformMap(Map<Object?, Object?> raw) {
    final modified = raw['lastModified'];
    return RemoteFile(
      name: raw['name'] as String? ?? '',
      path: raw['path'] as String? ?? '',
      isDirectory: raw['directory'] as bool? ?? false,
      size: (raw['size'] as num?)?.toInt(),
      lastModified: modified is num
          ? DateTime.fromMillisecondsSinceEpoch(modified.toInt())
          : null,
    );
  }
}

/// Random-access-ish access to the camera's storage through a SAF tree grant.
abstract interface class CameraStorage {
  /// Persisted `content://.../tree/...` URI.
  String get treeUri;

  /// Human label for the volume, e.g. `disk`.
  String get label;

  Future<List<RemoteFile>> list(String relativeDir);

  /// File bytes, or null when the path does not exist.
  Future<Uint8List?> read(String relativePath);

  /// Writes (creating or truncating) a file, creating parent folders.
  Future<void> write(String relativePath, Uint8List bytes);

  Future<void> delete(String relativePath);

  Future<bool> exists(String relativePath);
}

/// A storage operation failed; [code] is stable enough to branch on.
class CameraStorageException implements Exception {
  const CameraStorageException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'CameraStorageException($code): $message';
}

/// Stable paths inside the camera's storage.
abstract final class CameraStoragePaths {
  /// The camera's media index; its presence proves the picked folder is the
  /// camera drive rather than phone storage.
  static const String index = 'DCIM/fileinfo_list.list';

  /// The directory the camera's own photos live in.
  static const String cameraDir = 'DCIM/Camera01';
}

/// Resolves (and remembers) the camera's SAF tree grant.
abstract interface class CameraStorageRepository {
  /// The remembered, still-persisted storage for [camera], or null.
  Future<CameraStorage?> grantedStorageFor(UsbCamera camera);

  /// Opens the system folder picker and stores the grant for [camera].
  ///
  /// Returns null when the user cancels. Throws [CameraStorageException] when
  /// the chosen folder is not the camera's storage or is read-only.
  Future<CameraStorage?> requestStorageFor(UsbCamera camera);
}
