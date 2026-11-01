import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/cameras/domain/usb_camera.dart';

void main() {
  group('UsbCamera.fromPlatformMap', () {
    test('parses a full Android payload', () {
      final camera = UsbCamera.fromPlatformMap(const <String, Object?>{
        'deviceId': '/dev/bus/usb/001/004',
        'deviceName': '/dev/bus/usb/001/004',
        'vendorId': 0x1234,
        'productId': 0x5678,
        'manufacturer': 'Arashi Vision',
        'product': 'Insta360 GO Ultra',
        'serialNumber': 'IBEXAMPLE00001',
        'massStorage': true,
        'permissionGranted': false,
        'interfaces': <Object?>[
          <String, Object?>{
            'interfaceClass': 8,
            'interfaceSubclass': 6,
            'interfaceProtocol': 80,
          },
        ],
      });

      expect(camera.deviceId, '/dev/bus/usb/001/004');
      expect(camera.vendorId, 0x1234);
      expect(camera.productId, 0x5678);
      expect(camera.name, 'Insta360 GO Ultra');
      expect(camera.manufacturer, 'Arashi Vision');
      expect(camera.serialNumber, 'IBEXAMPLE00001');
      expect(camera.massStorage, isTrue);
      expect(camera.permissionGranted, isFalse);
      expect(camera.isInsta360, isTrue);
      expect(camera.vendorProductId, '0x1234:0x5678');
      expect(camera.isRelevant, isTrue);
    });

    test('derives mass storage from the interface list', () {
      final camera = UsbCamera.fromPlatformMap(const <String, Object?>{
        'deviceId': '/dev/bus/usb/002/001',
        'vendorId': 0x1000,
        'productId': 0x2000,
        'interfaces': <Object?>[
          <String, Object?>{'interfaceClass': 3},
          <String, Object?>{'interfaceClass': 8},
        ],
      });

      expect(camera.massStorage, isTrue);
      expect(camera.isInsta360, isFalse);
      expect(camera.isRelevant, isTrue);
    });

    test('falls back to the device name then a generic label', () {
      final withDeviceName = UsbCamera.fromPlatformMap(const <String, Object?>{
        'deviceId': '/dev/bus/usb/001/002',
        'vendorId': 0x1111,
        'productId': 0x2222,
      });
      expect(withDeviceName.name, '/dev/bus/usb/001/002');

      final anonymous = UsbCamera.fromPlatformMap(const <String, Object?>{});
      expect(anonymous.name, 'USB device 0x0000:0x0000');
      expect(anonymous.deviceId, startsWith('usb-'));
      expect(anonymous.isRelevant, isFalse);
    });

    test('recognises Insta360 by manufacturer when product is missing', () {
      final camera = UsbCamera.fromPlatformMap(const <String, Object?>{
        'deviceId': 'x',
        'manufacturer': 'insta360',
      });

      expect(camera.isInsta360, isTrue);
      expect(camera.name, 'insta360');
    });

    test('recognises the confirmed Arashi Vision vendor id', () {
      final camera = UsbCamera.fromPlatformMap(const <String, Object?>{
        'deviceId': 'x',
        'vendorId': 0x2E1A,
        'productId': 0x1006,
        'manufacturer': 'Arashi Vision',
        'product': 'Insta360 GO Ultra',
        'massStorage': true,
      });

      expect(camera.isInsta360, isTrue);
      expect(camera.vendorProductId, '0x2E1A:0x1006');
    });

    test('a bare Arashi vendor id is enough without a product name', () {
      final camera = UsbCamera.fromPlatformMap(const <String, Object?>{
        'deviceId': 'x',
        'vendorId': 0x2E1A,
        'productId': 0x1006,
      });

      expect(camera.isInsta360, isTrue);
      expect(camera.isRelevant, isTrue);
    });

    test('does not classify unrelated storage as Insta360', () {
      final camera = UsbCamera.fromPlatformMap(const <String, Object?>{
        'deviceId': 'x',
        'vendorId': 0x0781,
        'productId': 0x5567,
        'product': 'SanDisk Cruzer',
        'massStorage': true,
      });

      expect(camera.isInsta360, isFalse);
      expect(camera.isRelevant, isTrue);
      expect(camera.vendorProductId, '0x0781:0x5567');
    });

    test('copyWith changes permission only', () {
      final camera = UsbCamera.fromPlatformMap(const <String, Object?>{
        'deviceId': 'x',
        'vendorId': 1,
        'productId': 2,
        'product': 'Insta360 X5',
        'massStorage': true,
      });
      final granted = camera.copyWith(permissionGranted: true);

      expect(granted.permissionGranted, isTrue);
      expect(granted.deviceId, camera.deviceId);
      expect(granted.name, 'Insta360 X5');
      expect(granted.isInsta360, isTrue);
    });
  });
}
