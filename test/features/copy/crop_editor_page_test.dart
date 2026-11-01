import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/core/theme/app_theme.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/crop_window.dart';
import 'package:insta360_print_anything_mobile/features/copy/presentation/copy_review_page.dart';
import 'package:insta360_print_anything_mobile/features/gallery/domain/photo_asset.dart';

import '../../support/fakes.dart';

/// 4x3 PNG so the preview has something real to decode in the test.
const String _testPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAE0lEQVR4nGM8EaXBAANM'
    'cBY6BwAw7gFQgcLqQAAAAABJRU5ErkJggg==';

void main() {
  testWidgets('crop editor moves the crop and sends it with the copy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = FakeCopyEngine();
    const photo = PhotoAsset(id: 'wide', width: 4000, height: 2250);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: CopyReviewPage(
          photo: photo,
          camera: makeCamera(),
          copyEngine: engine,
          storageRepository: FakeCameraStorageRepository(),
          preview: MemoryImage(base64Decode(_testPngBase64)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final adjust = find.byKey(const Key('adjust-crop'));
    expect(adjust, findsOneWidget);
    await tester.tap(adjust);
    await tester.pumpAndSettle();

    expect(find.text('Adjust crop'), findsOneWidget);
    expect(find.byKey(const Key('crop-viewer')), findsOneWidget);

    // Pan the 16:9 image left inside the 4:3 frame; the kept window shifts
    // to the right of the photo.
    await tester.drag(
      find.byKey(const Key('crop-viewer')),
      const Offset(-70, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Copy to camera'));
    await tester.pumpAndSettle();

    expect(engine.copyCount, 1);
    final crop = engine.lastRequest!.crop;
    expect(crop, isNotNull);
    expect(crop!.isValid, isTrue);
    expect(
      crop.left,
      greaterThan(CropWindow.centered(imageAspect: 16 / 9).left),
      reason: 'panning left keeps a window further right in the source',
    );
    expect(crop.width, closeTo(0.75, 0.01));

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });
}
