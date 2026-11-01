import 'package:flutter/services.dart';

import '../domain/camera_storage.dart';

/// Platform-channel client for the Storage Access Framework.
///
/// Implemented by `CameraStorageChannel.kt`: one persisted tree grant for the
/// camera drive, then directory/file operations inside it.
class CameraStorageService {
  const CameraStorageService([
    MethodChannel channel = const MethodChannel(channelName),
  ]) : _channel = channel;

  static const String channelName =
      'insta360_print_anything_mobile/camera_storage';

  final MethodChannel _channel;

  /// Opens the system folder picker; null when the user cancels.
  Future<String?> pickTree({String? initialUri}) async {
    try {
      return await _channel.invokeMethod<String>('pickTree', <String, Object?>{
        'initialUri': initialUri,
      });
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      throw const CameraStorageException(
        'Folder access is only available on Android.',
        code: 'unsupported',
      );
    }
  }

  Future<String?> rememberedTree(String cameraKey) async {
    try {
      return await _channel.invokeMethod<String>(
        'rememberedTree',
        <String, Object?>{'cameraKey': cameraKey},
      );
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> rememberTree(String cameraKey, String treeUri) async {
    try {
      return await _channel.invokeMethod<bool>(
            'rememberTree',
            <String, Object?>{'cameraKey': cameraKey, 'treeUri': treeUri},
          ) ??
          false;
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> forgetTree(String cameraKey) async {
    try {
      await _channel.invokeMethod<void>('forgetTree', <String, Object?>{
        'cameraKey': cameraKey,
      });
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      // Nothing to forget without the plugin.
    }
  }

  Future<Map<Object?, Object?>> treeInfo(String treeUri) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'treeInfo',
        <String, Object?>{'treeUri': treeUri},
      );
      return raw ?? const <Object?, Object?>{};
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      return const <Object?, Object?>{};
    }
  }

  Future<List<Map<Object?, Object?>>> list(
    String treeUri,
    String relativeDir,
  ) async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'list',
        <String, Object?>{'treeUri': treeUri, 'relativeDir': relativeDir},
      );
      if (raw == null) return const <Map<Object?, Object?>>[];
      return raw.whereType<Map<Object?, Object?>>().toList(growable: false);
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      throw const CameraStorageException(
        'Folder access is only available on Android.',
        code: 'unsupported',
      );
    }
  }

  /// Null when the file does not exist.
  Future<Uint8List?> read(String treeUri, String relativePath) async {
    try {
      return await _channel.invokeMethod<Uint8List>('read', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
      });
    } on PlatformException catch (error) {
      if (error.code == 'not_found') return null;
      throw _wrap(error);
    } on MissingPluginException {
      throw const CameraStorageException(
        'Folder access is only available on Android.',
        code: 'unsupported',
      );
    }
  }

  Future<void> write(
    String treeUri,
    String relativePath,
    Uint8List bytes,
  ) async {
    try {
      await _channel.invokeMethod<bool>('write', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
        'bytes': bytes,
      });
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      throw const CameraStorageException(
        'Folder access is only available on Android.',
        code: 'unsupported',
      );
    }
  }

  Future<void> delete(String treeUri, String relativePath) async {
    try {
      await _channel.invokeMethod<bool>('delete', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
      });
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      throw const CameraStorageException(
        'Folder access is only available on Android.',
        code: 'unsupported',
      );
    }
  }

  Future<bool> exists(String treeUri, String relativePath) async {
    try {
      return await _channel.invokeMethod<bool>('exists', <String, Object?>{
            'treeUri': treeUri,
            'relativePath': relativePath,
          }) ??
          false;
    } on PlatformException catch (error) {
      throw _wrap(error);
    } on MissingPluginException {
      return false;
    }
  }

  CameraStorageException _wrap(PlatformException error) {
    return CameraStorageException(
      error.message ?? 'The camera storage operation failed.',
      code: error.code,
    );
  }
}
