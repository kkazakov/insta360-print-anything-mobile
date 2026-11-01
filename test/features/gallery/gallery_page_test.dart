import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/core/theme/app_theme.dart';
import 'package:insta360_print_anything_mobile/features/cameras/presentation/camera_picker_sheet.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/copy_engine.dart';
import 'package:insta360_print_anything_mobile/features/copy/presentation/copy_review_page.dart';
import 'package:insta360_print_anything_mobile/features/gallery/domain/gallery_access.dart';
import 'package:insta360_print_anything_mobile/features/gallery/presentation/gallery_page.dart';
import 'package:insta360_print_anything_mobile/features/gallery/presentation/widgets/photo_tile.dart';

import '../../support/fakes.dart';

Widget _app({
  required FakeGalleryRepository gallery,
  required FakeCameraRepository cameras,
  FakeCopyEngine? engine,
  FakeCameraStorageRepository? storage,
}) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: GalleryPage(
      galleryRepository: gallery,
      cameraRepository: cameras,
      storageRepository: storage ?? FakeCameraStorageRepository(),
      copyEngine: engine ?? FakeCopyEngine(),
    ),
  );
}

int _firstRowCount(WidgetTester tester) {
  final tiles = find.byType(PhotoTile);
  final count = tiles.evaluate().length;
  if (count == 0) return 0;
  final firstTop = tester.getTopLeft(tiles.at(0)).dy;
  var row = 0;
  for (var i = 0; i < count; i++) {
    if ((tester.getTopLeft(tiles.at(i)).dy - firstTop).abs() < 1) row++;
  }
  return row;
}

void main() {
  testWidgets('shows the photo grid and count once access is granted', (
    tester,
  ) async {
    final gallery = FakeGalleryRepository(photos: makePhotos(4));

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: FakeCameraRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PhotoTile), findsWidgets);
    expect(find.text('Recent photos'), findsOneWidget);
    expect(find.text('4 photos'), findsOneWidget);
    expect(gallery.requestCount, 1);
  });

  testWidgets('denied access shows the prompt and both escape hatches', (
    tester,
  ) async {
    final gallery = FakeGalleryRepository(
      access: GalleryAccess.denied,
      onRequest: GalleryAccess.denied,
      photos: makePhotos(3),
    );

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: FakeCameraRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Photo access needed'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Allow access'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Open settings'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Open settings'));
    await tester.pumpAndSettle();
    expect(gallery.settingsCount, 1);
  });

  testWidgets('the prompt button re-asks and recovers when granted', (
    tester,
  ) async {
    final gallery = FakeGalleryRepository(
      access: GalleryAccess.denied,
      onRequest: GalleryAccess.denied,
      photos: makePhotos(3),
    );

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: FakeCameraRepository()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Photo access needed'), findsOneWidget);

    // The user allows the second system prompt.
    gallery.onRequest = GalleryAccess.granted;
    await tester.tap(find.widgetWithText(FilledButton, 'Allow access'));
    await tester.pumpAndSettle();

    expect(gallery.requestCount, 2);
    expect(find.byType(PhotoTile), findsWidgets);
    expect(find.text('Photo access needed'), findsNothing);
  });

  testWidgets('a still-denied re-ask keeps the prompt on screen', (
    tester,
  ) async {
    final gallery = FakeGalleryRepository(
      access: GalleryAccess.denied,
      onRequest: GalleryAccess.denied,
    );

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: FakeCameraRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Allow access'));
    await tester.pumpAndSettle();

    expect(gallery.requestCount, 2);
    expect(find.text('Photo access needed'), findsOneWidget);
  });

  testWidgets('limited access shows the banner and manage action', (
    tester,
  ) async {
    final gallery = FakeGalleryRepository(
      access: GalleryAccess.limited,
      photos: makePhotos(2),
    );

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: FakeCameraRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Only your selected photos are visible'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Manage'));
    await tester.pumpAndSettle();

    expect(gallery.limitedSelectionCount, 1);
  });

  testWidgets('choosing a camera opens the review screen and copies', (
    tester,
  ) async {
    final gallery = FakeGalleryRepository(photos: makePhotos(6));
    final cameras = FakeCameraRepository(cameras: [makeCamera()]);
    final engine = FakeCopyEngine(
      result: const CopyResult.failure('Camera write path is not ready.'),
    );

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: cameras, engine: engine),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PhotoTile).first);
    await tester.pumpAndSettle();

    expect(find.text('Choose a camera'), findsOneWidget);
    expect(find.text('Insta360 GO Ultra'), findsOneWidget);

    await tester.tap(find.text('Insta360 GO Ultra'));
    await tester.pumpAndSettle();

    expect(find.byType(CopyReviewPage), findsOneWidget);
    expect(cameras.permissionRequests, 1);

    await tester.scrollUntilVisible(find.text('TARGET CAMERA'), 250);
    expect(find.text('TARGET CAMERA'), findsOneWidget);
    expect(find.text('USB mass storage'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Copy to camera'));
    await tester.pumpAndSettle();

    expect(find.text('Not copied yet'), findsOneWidget);
    expect(find.text('Camera write path is not ready.'), findsOneWidget);
    expect(engine.copyCount, 1);
  });

  testWidgets('the sheet explains when no camera is attached', (tester) async {
    final gallery = FakeGalleryRepository(photos: makePhotos(3));

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: FakeCameraRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PhotoTile).first);
    await tester.pumpAndSettle();

    expect(find.byType(CameraPickerSheet), findsOneWidget);
    expect(find.text('No Insta360 camera found'), findsOneWidget);

    // Dismiss the sheet so its polling timer is cancelled.
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(CameraPickerSheet), findsNothing);
  });

  testWidgets('the grid reflows across phone portrait, landscape and tablet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final gallery = FakeGalleryRepository(photos: makePhotos(20));

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: FakeCameraRepository()),
    );
    await tester.pumpAndSettle();

    expect(_firstRowCount(tester), 3, reason: 'phone portrait');

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(_firstRowCount(tester), 7, reason: 'phone landscape');

    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();
    expect(_firstRowCount(tester), 8, reason: 'tablet landscape');
  });

  testWidgets('permission actions stay on screen in phone landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final gallery = FakeGalleryRepository(
      access: GalleryAccess.denied,
      onRequest: GalleryAccess.denied,
    );

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: FakeCameraRepository()),
    );
    await tester.pumpAndSettle();

    final allow = find.widgetWithText(FilledButton, 'Allow access');
    final settings = find.widgetWithText(OutlinedButton, 'Open settings');
    expect(allow, findsOneWidget);
    expect(settings, findsOneWidget);

    // Both actions must be inside the viewport without scrolling: this is the
    // phone-landscape regression the adaptive status layout fixes.
    final allowRect = tester.getRect(allow);
    final settingsRect = tester.getRect(settings);
    expect(allowRect.top, greaterThanOrEqualTo(0));
    expect(allowRect.bottom, lessThanOrEqualTo(390));
    expect(settingsRect.bottom, lessThanOrEqualTo(390));

    await tester.tap(allow);
    await tester.pumpAndSettle();
    expect(gallery.requestCount, 2);
  });

  testWidgets('the review screen needs camera storage before copying', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final gallery = FakeGalleryRepository(photos: makePhotos(4));
    final cameras = FakeCameraRepository(cameras: [makeCamera()]);
    final storage = FakeCameraStorageRepository(grant: false);

    await tester.pumpWidget(
      _app(gallery: gallery, cameras: cameras, storage: storage),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PhotoTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insta360 GO Ultra'));
    await tester.pumpAndSettle();

    expect(find.text('Folder access needed'), findsOneWidget);
    final copyFinder = find.widgetWithText(FilledButton, 'Copy to camera');
    expect(tester.widget<FilledButton>(copyFinder).onPressed, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Choose camera folder'));
    await tester.pumpAndSettle();

    expect(storage.requestCount, 1);
    expect(find.text('Folder access granted'), findsOneWidget);
    expect(tester.widget<FilledButton>(copyFinder).onPressed, isNotNull);
  });
}
