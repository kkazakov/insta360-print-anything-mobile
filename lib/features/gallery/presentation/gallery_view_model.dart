import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show ImageProvider;
import 'package:flutter/services.dart' show PlatformException;

import '../domain/gallery_access.dart';
import '../domain/gallery_repository.dart';
import '../domain/photo_asset.dart';

/// What the gallery screen should be showing.
enum GalleryStatus {
  /// The system permission prompt is up (or about to be).
  requestingAccess,

  /// The user declined; the screen shows a button to ask again.
  accessDenied,

  /// Permission is blocked by the platform or device policy; only Settings
  /// can change it.
  accessRestricted,

  /// Permission is fine, the first page is loading.
  loading,

  /// Photos are available.
  ready,

  /// Permission is fine but there is nothing to show.
  empty,

  /// Something failed; [GalleryViewModel.errorMessage] says what.
  error,
}

/// State and commands for the photo grid.
class GalleryViewModel extends ChangeNotifier {
  GalleryViewModel(this._repository, {this.pageSize = 80});

  final GalleryRepository _repository;
  final int pageSize;

  GalleryStatus _status = GalleryStatus.requestingAccess;
  GalleryAccess _access = GalleryAccess.unknown;
  List<PhotoAsset> _photos = const <PhotoAsset>[];
  int _totalCount = 0;
  String? _errorMessage;
  String? _loadMoreError;
  bool _isLoadingMore = false;
  bool _isRefreshing = false;
  bool _isRequesting = false;
  bool _started = false;
  bool _disposed = false;

  GalleryStatus get status => _status;
  GalleryAccess get access => _access;
  List<PhotoAsset> get photos => _photos;
  int get totalCount => _totalCount;
  int get loadedCount => _photos.length;
  String? get errorMessage => _errorMessage;
  String? get loadMoreError => _loadMoreError;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _photos.length < _totalCount;

  /// First load: asks for permission, then reads the newest page.
  ///
  /// Called once from the gallery screen's `initState`, which is what makes
  /// the permission prompt appear on app open.
  Future<void> initialize() async {
    if (_started) return;
    _started = true;
    await _acquireAccess(request: true);
  }

  /// The "Allow access" / "Try again" button on the denied screen.
  Future<void> requestAccess() async {
    await _acquireAccess(request: true);
  }

  /// Opens the system photo picker for a limited grant, then reloads.
  Future<void> manageLimitedAccess() async {
    try {
      await _repository.presentLimitedSelection();
    } finally {
      if (!_disposed) await refresh();
    }
  }

  /// Opens the OS settings page; the screen reloads on resume.
  Future<void> openSystemSettings() => _repository.openSystemSettings();

  /// Re-reads a denied/restricted permission without prompting.
  ///
  /// Used when the app comes back to the foreground, so returning from the
  /// settings page updates the grid immediately.
  Future<void> recheckAccess() async {
    final relevant =
        _status == GalleryStatus.accessDenied ||
        _status == GalleryStatus.accessRestricted;
    if (!relevant) return;
    try {
      final access = await _repository.currentAccess();
      if (!access.canBrowse) return;
      _access = access;
      await _loadFirstPage();
      _notify();
    } catch (_) {
      // Keep the prompt on screen; the explicit buttons still work.
    }
  }

  /// Reloads from the newest photo, keeping the current content visible until
  /// the new page arrives. Rethrows on failure so pull-to-refresh can report
  /// it without turning a working grid into an error screen.
  Future<void> refresh() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    try {
      final page = await _repository.photos(offset: 0, limit: pageSize);
      _photos = page.photos;
      _totalCount = page.totalCount;
      _loadMoreError = null;
      _errorMessage = null;
      _status = _photos.isEmpty ? GalleryStatus.empty : GalleryStatus.ready;
    } catch (error) {
      _errorMessage = _describe(error);
      if (_photos.isEmpty) _status = GalleryStatus.error;
      rethrow;
    } finally {
      _isRefreshing = false;
      _notify();
    }
  }

  /// Appends the next page. Safe to call from a scroll listener.
  Future<void> loadMore() async {
    if (_status != GalleryStatus.ready || _isLoadingMore || !hasMore) return;
    _isLoadingMore = true;
    _loadMoreError = null;
    _notify();

    try {
      final page = await _repository.photos(
        offset: _photos.length,
        limit: pageSize,
      );
      final seen = _photos.map((photo) => photo.id).toSet();
      final appended = page.photos
          .where((photo) => !seen.contains(photo.id))
          .toList(growable: false);
      _photos = <PhotoAsset>[..._photos, ...appended];
      // An empty page means the library shrank (deletions, limited grant
      // changed). Stop pretending there is more to load.
      _totalCount = appended.isEmpty ? _photos.length : page.totalCount;
    } catch (error) {
      _loadMoreError = _describe(error);
    } finally {
      _isLoadingMore = false;
      _notify();
    }
  }

  ImageProvider? thumbnailFor(PhotoAsset photo, {required int cacheSize}) {
    try {
      return _repository.thumbnailFor(photo, cacheSize: cacheSize);
    } catch (_) {
      return null;
    }
  }

  Future<void> _acquireAccess({required bool request}) async {
    if (_isRequesting) return;
    _isRequesting = true;
    _status = GalleryStatus.requestingAccess;
    _errorMessage = null;
    _notify();

    try {
      final access = request
          ? await _repository.requestAccess()
          : await _repository.currentAccess();
      _access = access;

      if (!access.canBrowse) {
        _status = access.needsSettings
            ? GalleryStatus.accessRestricted
            : GalleryStatus.accessDenied;
        return;
      }

      await _loadFirstPage();
    } catch (error) {
      _errorMessage = _describe(error);
      _status = GalleryStatus.error;
    } finally {
      _isRequesting = false;
      _notify();
    }
  }

  Future<void> _loadFirstPage() async {
    _status = GalleryStatus.loading;
    _photos = const <PhotoAsset>[];
    _totalCount = 0;
    _loadMoreError = null;
    _notify();

    try {
      final page = await _repository.photos(offset: 0, limit: pageSize);
      _photos = page.photos;
      _totalCount = page.totalCount;
      _status = _photos.isEmpty ? GalleryStatus.empty : GalleryStatus.ready;
    } catch (error) {
      _errorMessage = _describe(error);
      _status = GalleryStatus.error;
    }
  }

  String _describe(Object error) {
    if (error is GalleryAccessException) {
      return 'Photo access was turned off. Allow it again to see your photos.';
    }
    if (error is PlatformException) {
      return error.message ?? 'The system could not list your photos.';
    }
    return 'Something went wrong while reading your photos. Try again.';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
