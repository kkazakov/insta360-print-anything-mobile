import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/gallery/domain/gallery_access.dart';
import 'package:insta360_print_anything_mobile/features/gallery/presentation/gallery_view_model.dart';

import '../../support/fakes.dart';

void main() {
  group('GalleryViewModel permission flow', () {
    test('asks for access on initialize and loads the newest page', () async {
      final repository = FakeGalleryRepository(photos: makePhotos(5));
      final viewModel = GalleryViewModel(repository, pageSize: 3);
      addTearDown(viewModel.dispose);

      expect(viewModel.status, GalleryStatus.requestingAccess);

      await viewModel.initialize();

      expect(repository.requestCount, 1);
      expect(viewModel.access, GalleryAccess.granted);
      expect(viewModel.status, GalleryStatus.ready);
      expect(viewModel.photos, hasLength(3));
      expect(viewModel.totalCount, 5);
      expect(viewModel.hasMore, isTrue);
    });

    test('initialize only requests once', () async {
      final repository = FakeGalleryRepository(photos: makePhotos(2));
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();
      await viewModel.initialize();

      expect(repository.requestCount, 1);
    });

    test('denied access shows the retry state and can re-ask', () async {
      final repository = FakeGalleryRepository(
        access: GalleryAccess.denied,
        onRequest: GalleryAccess.denied,
        photos: makePhotos(4),
      );
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();
      expect(viewModel.status, GalleryStatus.accessDenied);
      expect(viewModel.photos, isEmpty);

      // The user allows on the second prompt.
      repository.onRequest = GalleryAccess.granted;
      await viewModel.requestAccess();

      expect(repository.requestCount, 2);
      expect(viewModel.status, GalleryStatus.ready);
      expect(viewModel.photos, hasLength(4));
    });

    test('restricted access cannot be re-prompted from the app', () async {
      final repository = FakeGalleryRepository(
        access: GalleryAccess.restricted,
        onRequest: GalleryAccess.restricted,
      );
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();

      expect(viewModel.status, GalleryStatus.accessRestricted);
      expect(viewModel.access.needsSettings, isTrue);
    });

    test('recheckAccess picks up a grant made in system settings', () async {
      final repository = FakeGalleryRepository(
        access: GalleryAccess.denied,
        onRequest: GalleryAccess.denied,
        photos: makePhotos(2),
      );
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();
      expect(viewModel.status, GalleryStatus.accessDenied);

      // Simulates the user flipping the toggle in Settings and coming back.
      repository.access = GalleryAccess.granted;
      await viewModel.recheckAccess();

      expect(repository.requestCount, 1, reason: 'no new prompt');
      expect(viewModel.status, GalleryStatus.ready);
      expect(viewModel.photos, hasLength(2));
    });

    test('recheckAccess leaves the prompt alone when still denied', () async {
      final repository = FakeGalleryRepository(
        access: GalleryAccess.denied,
        onRequest: GalleryAccess.denied,
      );
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();
      await viewModel.recheckAccess();

      expect(viewModel.status, GalleryStatus.accessDenied);
    });
  });

  group('GalleryViewModel content', () {
    test('granted with no photos shows the empty state', () async {
      final repository = FakeGalleryRepository();
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();

      expect(viewModel.status, GalleryStatus.empty);
      expect(viewModel.totalCount, 0);
    });

    test('limited access is surfaced and can be managed', () async {
      final repository = FakeGalleryRepository(
        access: GalleryAccess.limited,
        photos: makePhotos(1),
      );
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();
      expect(viewModel.access.isLimited, isTrue);
      expect(viewModel.status, GalleryStatus.ready);

      await viewModel.manageLimitedAccess();

      expect(repository.limitedSelectionCount, 1);
      expect(repository.pageCount, greaterThanOrEqualTo(2));
    });

    test('loadMore appends pages and stops at the total', () async {
      final repository = FakeGalleryRepository(photos: makePhotos(5));
      final viewModel = GalleryViewModel(repository, pageSize: 2);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();
      expect(viewModel.photos, hasLength(2));

      await viewModel.loadMore();
      expect(viewModel.photos, hasLength(4));

      await viewModel.loadMore();
      expect(viewModel.photos, hasLength(5));
      expect(viewModel.hasMore, isFalse);

      // No-op once everything is loaded.
      await viewModel.loadMore();
      expect(viewModel.photos, hasLength(5));
    });

    test(
      'loadMore failure keeps existing photos and exposes the error',
      () async {
        final repository = FakeGalleryRepository(photos: makePhotos(4));
        final viewModel = GalleryViewModel(repository, pageSize: 2);
        addTearDown(viewModel.dispose);

        await viewModel.initialize();
        repository.error = Exception('boom');
        await viewModel.loadMore();

        expect(viewModel.photos, hasLength(2));
        expect(viewModel.loadMoreError, isNotNull);

        repository.error = null;
        await viewModel.loadMore();
        expect(viewModel.photos, hasLength(4));
        expect(viewModel.loadMoreError, isNull);
      },
    );

    test('refresh reloads the first page', () async {
      final repository = FakeGalleryRepository(photos: makePhotos(2));
      final viewModel = GalleryViewModel(repository, pageSize: 2);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();
      repository.assets = makePhotos(3);
      await viewModel.refresh();

      expect(viewModel.photos, hasLength(2));
      expect(viewModel.totalCount, 3);
    });

    test('refresh failure with existing content keeps the grid', () async {
      final repository = FakeGalleryRepository(photos: makePhotos(2));
      final viewModel = GalleryViewModel(repository, pageSize: 2);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();
      repository.error = Exception('offline');
      await expectLater(viewModel.refresh(), throwsA(isA<Exception>()));

      expect(viewModel.status, GalleryStatus.ready);
      expect(viewModel.photos, hasLength(2));
      expect(viewModel.errorMessage, isNotNull);
    });
  });

  group('GalleryViewModel failures', () {
    test('a failing photo query shows the error state', () async {
      final repository = FakeGalleryRepository(
        photos: makePhotos(3),
        error: Exception('media store broke'),
      );
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();

      expect(viewModel.status, GalleryStatus.error);
      expect(viewModel.errorMessage, isNotNull);
    });

    test('access revoked while reading the page surfaces an error', () async {
      final repository = FakeGalleryRepository(photos: makePhotos(3));
      repository.loseAccessOnPage = true;
      final viewModel = GalleryViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.initialize();

      expect(viewModel.status, GalleryStatus.error);
      expect(viewModel.errorMessage, contains('access'));
      expect(viewModel.photos, isEmpty);
    });

    test('notifications after dispose are swallowed', () async {
      final repository = FakeGalleryRepository(
        photos: makePhotos(2),
        pageDelay: const Duration(milliseconds: 5),
      );
      final viewModel = GalleryViewModel(repository);

      final pending = viewModel.initialize();
      viewModel.dispose();

      await expectLater(pending, completes);
    });
  });
}
