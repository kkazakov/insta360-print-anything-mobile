import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/camera_repository.dart';
import '../domain/usb_camera.dart';

/// What the camera picker should be showing.
enum CameraScanStatus {
  /// First scan in flight.
  scanning,

  /// At least one usable camera.
  ready,

  /// USB host works but nothing camera-like is attached.
  empty,

  /// The device cannot act as a USB host at all.
  unsupported,

  /// The scan itself failed.
  error,
}

/// State and commands for the "choose a camera" sheet.
///
/// While the sheet is open it re-scans on a timer, so plugging the camera in
/// after opening the sheet still works.
class CameraPickerViewModel extends ChangeNotifier {
  CameraPickerViewModel(
    this._repository, {
    this.pollInterval = const Duration(seconds: 2),
  });

  final CameraRepository _repository;

  /// Re-scan period; null disables polling (used in tests).
  final Duration? pollInterval;

  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _isScanning = false;
  bool _isRequesting = false;
  String? _requestingDeviceId;

  CameraScanStatus _status = CameraScanStatus.scanning;
  List<UsbCamera> _cameras = const <UsbCamera>[];
  String? _errorMessage;
  String? _permissionError;

  CameraScanStatus get status => _status;
  List<UsbCamera> get cameras => _cameras;
  String? get errorMessage => _errorMessage;
  String? get permissionError => _permissionError;
  bool get isScanning => _isScanning;
  bool get isRequestingPermission => _isRequesting;
  String? get requestingDeviceId => _requestingDeviceId;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final supported = await _repository.supportsUsbHost();
    if (_disposed) return;
    if (!supported) {
      _status = CameraScanStatus.unsupported;
      _notify();
      return;
    }

    await _scan(initial: true);

    if (!_disposed && pollInterval != null) {
      _timer = Timer.periodic(pollInterval!, (_) => unawaited(_scan()));
    }
  }

  /// Explicit "scan again" from the sheet.
  Future<void> refresh() async {
    if (_isScanning) return;
    _status = CameraScanStatus.scanning;
    _errorMessage = null;
    _notify();
    await _scan();
  }

  /// Asks Android for USB access to [camera].
  ///
  /// Returns the camera (with [UsbCamera.permissionGranted] set) on success,
  /// or null when the user declined or the request failed.
  Future<UsbCamera?> select(UsbCamera camera) async {
    if (_isRequesting) return null;
    _isRequesting = true;
    _requestingDeviceId = camera.deviceId;
    _permissionError = null;
    _notify();

    var selected = camera;
    try {
      final granted =
          camera.permissionGranted ||
          await _repository.requestPermission(camera);
      if (!granted) {
        _permissionError =
            'USB access was denied. Tap the camera again and allow access.';
        return null;
      }
      selected = camera.copyWith(permissionGranted: true);
      _cameras = _cameras
          .map((entry) => entry.deviceId == camera.deviceId ? selected : entry)
          .toList(growable: false);
      return selected;
    } catch (_) {
      _permissionError =
          'Could not get USB access to this camera. Reconnect it and retry.';
      return null;
    } finally {
      _isRequesting = false;
      _requestingDeviceId = null;
      _notify();
    }
  }

  void clearPermissionError() {
    if (_permissionError == null) return;
    _permissionError = null;
    _notify();
  }

  Future<void> _scan({bool initial = false}) async {
    if (_isScanning || _disposed) return;
    _isScanning = true;
    _notify();

    try {
      final cameras = await _repository.connectedCameras();
      if (_disposed) return;
      _cameras = cameras;
      _status = cameras.isEmpty
          ? CameraScanStatus.empty
          : CameraScanStatus.ready;
      _errorMessage = null;
    } catch (error) {
      if (_disposed) return;
      // A failed background poll must not replace a populated list.
      if (initial || _cameras.isEmpty) {
        _status = CameraScanStatus.error;
        _errorMessage = 'Could not read the USB device list.';
      } else {
        _status = CameraScanStatus.ready;
      }
    } finally {
      _isScanning = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
