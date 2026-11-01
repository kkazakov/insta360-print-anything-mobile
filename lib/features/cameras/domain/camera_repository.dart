import 'usb_camera.dart';

/// Single source of truth for USB cameras attached to the device.
abstract interface class CameraRepository {
  /// False on platforms/hardware without USB host support.
  Future<bool> supportsUsbHost();

  /// Cameras that look usable (Insta360 identity or mass storage), best first.
  Future<List<UsbCamera>> connectedCameras();

  /// Shows the Android USB access dialog when needed. Returns whether the app
  /// may now open the device.
  Future<bool> requestPermission(UsbCamera camera);
}
