import '../domain/camera_repository.dart';
import '../domain/usb_camera.dart';
import 'usb_camera_service.dart';

/// [CameraRepository] over the Android USB host channel.
class UsbCameraRepository implements CameraRepository {
  UsbCameraRepository({UsbCameraService? service})
    : _service = service ?? const UsbCameraService();

  final UsbCameraService _service;

  @override
  Future<bool> supportsUsbHost() => _service.supportsUsbHost();

  @override
  Future<List<UsbCamera>> connectedCameras() async {
    final rawDevices = await _service.listDevices();
    final cameras = <UsbCamera>[];
    for (final raw in rawDevices) {
      final camera = UsbCamera.fromPlatformMap(raw);
      if (camera.isRelevant) cameras.add(camera);
    }
    cameras.sort((a, b) {
      if (a.isInsta360 != b.isInsta360) return a.isInsta360 ? -1 : 1;
      if (a.massStorage != b.massStorage) return a.massStorage ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return cameras;
  }

  @override
  Future<bool> requestPermission(UsbCamera camera) =>
      _service.requestPermission(camera.deviceId);
}
