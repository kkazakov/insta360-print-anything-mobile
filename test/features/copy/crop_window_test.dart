import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/crop_window.dart';

void main() {
  group('CropWindow.centered', () {
    test('wide 16:9 photo keeps full height and centres a 4:3 window', () {
      final crop = CropWindow.centered(imageAspect: 16 / 9);
      expect(crop.left, closeTo(0.125, 1e-9));
      expect(crop.top, 0);
      expect(crop.width, closeTo(0.75, 1e-9));
      expect(crop.height, 1);
    });

    test('tall 9:16 photo keeps full width and centres a 4:3 window', () {
      final crop = CropWindow.centered(imageAspect: 9 / 16);
      expect(crop.left, 0);
      expect(crop.top, closeTo(0.2890625, 1e-9));
      expect(crop.width, 1);
      expect(crop.height, closeTo(0.421875, 1e-9));
    });

    test('square photo letterboxes the 4:3 window vertically', () {
      final crop = CropWindow.centered(imageAspect: 1);
      expect(crop.left, 0);
      expect(crop.top, closeTo(0.125, 1e-9));
      expect(crop.width, 1);
      expect(crop.height, closeTo(0.75, 1e-9));
    });

    test('4:3 photo needs no crop', () {
      expect(CropWindow.centered(imageAspect: 4 / 3), CropWindow.full);
    });

    test('invalid aspect falls back to the full photo', () {
      expect(CropWindow.centered(imageAspect: 0), CropWindow.full);
      expect(CropWindow.centered(imageAspect: double.nan), CropWindow.full);
      expect(
        CropWindow.centered(imageAspect: 1, targetAspect: 0),
        CropWindow.full,
      );
    });

    test('every centred window has the target pixel aspect', () {
      for (final aspect in <double>[0.25, 0.75, 1, 4 / 3, 16 / 9, 3]) {
        final crop = CropWindow.centered(imageAspect: aspect);
        final pixelAspect = (crop.width * aspect) / crop.height;
        expect(pixelAspect, closeTo(cameraFrameAspect, 1e-9));
      }
    });
  });

  group('CropWindow validation', () {
    test('accepts a normalised rect', () {
      const crop = CropWindow(left: 0.1, top: 0.2, width: 0.5, height: 0.4);
      expect(crop.isValid, isTrue);
    });

    test('rejects rects outside the image or of zero size', () {
      expect(
        const CropWindow(left: 0.6, top: 0, width: 0.5, height: 1).isValid,
        isFalse,
      );
      expect(
        const CropWindow(left: 0, top: 0, width: 0, height: 1).isValid,
        isFalse,
      );
    });

    test('clamp pulls an out-of-bounds rect back in', () {
      const crop = CropWindow(left: 0.8, top: 0.9, width: 0.4, height: 0.4);
      final clamped = crop.clamp();
      expect(clamped.isValid, isTrue);
      expect(clamped.left, 0.8);
      expect(clamped.top, 0.9);
      expect(clamped.width, closeTo(0.2, 1e-9));
      expect(clamped.height, closeTo(0.1, 1e-9));
    });
  });
}
