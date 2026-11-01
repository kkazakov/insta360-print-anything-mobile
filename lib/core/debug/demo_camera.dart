import '../../features/cameras/domain/usb_camera.dart';

/// Compile-time development switch: `--dart-define=INSTA360_DEMO_CAMERA=true`.
///
/// Adds a "demo camera" entry to the empty camera sheet so the full SAF +
/// copy pipeline can be exercised against a folder on the phone (for example
/// `Download/insta360-sim/DCIM/...`) when no physical camera is attached.
/// Normal builds default to false and tree-shake this out.
const bool kDemoCameraEnabled = bool.fromEnvironment('INSTA360_DEMO_CAMERA');

/// Synthetic camera used by the demo path.
///
/// It has no USB identity, so it can only be used with a folder grant.
UsbCamera demoCamera() => const UsbCamera(
  deviceId: '/demo/insta360-sim',
  vendorId: 0,
  productId: 0,
  name: 'Insta360 (demo folder)',
  massStorage: true,
  permissionGranted: true,
  isInsta360: true,
);
