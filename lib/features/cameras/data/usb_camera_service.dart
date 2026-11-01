import 'package:flutter/services.dart';

/// Platform-channel client for the Android USB host API.
///
/// Implemented in `UsbCameraChannel.kt`; it only enumerates devices and asks
/// for access. File transfer (mass-storage reads/writes) arrives in stage 2.
class UsbCameraService {
  const UsbCameraService([this._channel = const MethodChannel(channelName)]);

  static const String channelName =
      'insta360_print_anything_mobile/usb_cameras';

  final MethodChannel _channel;

  /// False when the platform has no USB host support (or no plugin, e.g. when
  /// running the widget layer off-device).
  Future<bool> supportsUsbHost() async {
    try {
      return await _channel.invokeMethod<bool>('supportsUsbHost') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<List<Map<Object?, Object?>>> listDevices() async {
    final raw = await _channel.invokeMethod<List<Object?>>('listDevices');
    if (raw == null) return const <Map<Object?, Object?>>[];
    return raw.whereType<Map<Object?, Object?>>().toList(growable: false);
  }

  Future<bool> requestPermission(String deviceId) async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestPermission',
            <String, Object?>{'deviceId': deviceId},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
