import 'package:flutter/foundation.dart';

/// A camera (or any storage device) currently attached over USB.
///
/// The Insta360 cameras expose themselves as USB mass storage, so the app only
/// needs the device identity and a granted USB permission to talk to one.
@immutable
class UsbCamera {
  const UsbCamera({
    required this.deviceId,
    required this.vendorId,
    required this.productId,
    required this.name,
    this.manufacturer,
    this.product,
    this.serialNumber,
    this.massStorage = false,
    this.permissionGranted = false,
    this.isInsta360 = false,
  });

  /// Platform device path, e.g. `/dev/bus/usb/001/004`. Unique per plug-in.
  final String deviceId;

  final int vendorId;
  final int productId;

  /// Best available human name (product, then manufacturer, then device path).
  final String name;

  final String? manufacturer;
  final String? product;
  final String? serialNumber;

  /// Has a mass-storage interface (USB class 8), i.e. can hold files.
  final bool massStorage;

  /// The user already allowed USB access to this device for this session.
  final bool permissionGranted;

  /// Heuristic: the device names itself Insta360/Arashi Vision, or matches a
  /// known Insta360 vendor id.
  final bool isInsta360;

  String get vendorProductId => '${_hex16(vendorId)}:${_hex16(productId)}';

  /// Device has a plausible use for this app: either it names itself Insta360
  /// or it offers mass storage we could write to.
  bool get isRelevant => isInsta360 || massStorage;

  UsbCamera copyWith({bool? permissionGranted}) {
    return UsbCamera(
      deviceId: deviceId,
      vendorId: vendorId,
      productId: productId,
      name: name,
      manufacturer: manufacturer,
      product: product,
      serialNumber: serialNumber,
      massStorage: massStorage,
      permissionGranted: permissionGranted ?? this.permissionGranted,
      isInsta360: isInsta360,
    );
  }

  /// Maps the platform channel payload.
  ///
  /// Vendor ids of Insta360 bodies are not stable across product lines, so the
  /// name check is the reliable half; [knownInsta360VendorIds] is filled in
  /// once a real camera has been inspected.
  factory UsbCamera.fromPlatformMap(Map<Object?, Object?> raw) {
    final vendorId = _asInt(raw['vendorId']) ?? 0;
    final productId = _asInt(raw['productId']) ?? 0;
    final product = _asString(raw['product']);
    final manufacturer = _asString(raw['manufacturer']);
    final deviceName =
        _asString(raw['deviceName']) ?? 'usb-$vendorId-$productId';

    final names = <String>[?product, ?manufacturer, deviceName];
    final lowerNames = names.join(' ').toLowerCase();
    final nameMatches =
        lowerNames.contains('insta360') || lowerNames.contains('arashi');

    final rawInterfaces = raw['interfaces'];
    var massStorage = _asBool(raw['massStorage']) ?? false;
    if (rawInterfaces is List) {
      for (final entry in rawInterfaces) {
        if (entry is! Map) continue;
        if (_asInt(entry['interfaceClass']) == 8) massStorage = true;
      }
    }

    final displayName =
        product ??
        manufacturer ??
        _asString(raw['deviceName']) ??
        _asString(raw['deviceId']) ??
        'USB device ${_hex16(vendorId)}:${_hex16(productId)}';

    return UsbCamera(
      deviceId: _asString(raw['deviceId']) ?? deviceName,
      vendorId: vendorId,
      productId: productId,
      name: displayName,
      manufacturer: manufacturer,
      product: product,
      serialNumber: _asString(raw['serialNumber']),
      massStorage: massStorage,
      permissionGranted: _asBool(raw['permissionGranted']) ?? false,
      isInsta360: nameMatches || knownInsta360VendorIds.contains(vendorId),
    );
  }

  /// USB vendor ids confirmed to be Insta360 bodies.
  ///
  /// `0x2E1A` was read from an Insta360 GO Ultra (`dumpsys usb`, product
  /// 0x1006, manufacturer "Arashi Vision"). The name check stays as a fallback
  /// for bodies that do not expose a product string.
  static const Set<int> knownInsta360VendorIds = <int>{0x2E1A};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UsbCamera &&
          other.deviceId == deviceId &&
          other.permissionGranted == permissionGranted);

  @override
  int get hashCode => Object.hash(deviceId, permissionGranted);

  @override
  String toString() =>
      'UsbCamera($name, $vendorProductId, msc=$massStorage, '
      'granted=$permissionGranted)';

  static String _hex16(int value) =>
      '0x${value.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static bool? _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return null;
  }

  static String? _asString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
