import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/ui/status_message.dart';
import '../../cameras/domain/camera_repository.dart';
import '../../cameras/domain/camera_storage.dart';
import '../../cameras/presentation/camera_picker_sheet.dart';
import '../../copy/domain/copy_engine.dart';
import '../../copy/presentation/copy_review_page.dart';
import '../domain/gallery_repository.dart';
import '../domain/photo_asset.dart';
import 'gallery_view_model.dart';
import 'widgets/limited_access_banner.dart';
import 'widgets/permission_prompt.dart';
import 'widgets/photo_grid.dart';

/// The app's home screen: every recent photo, newest first.
///
/// Tapping a photo opens the USB camera picker; choosing a camera leads to the
/// review screen, which is where the copy pipeline runs.
class GalleryPage extends StatefulWidget {
  const GalleryPage({
    super.key,
    required this.galleryRepository,
    required this.cameraRepository,
    required this.storageRepository,
    required this.copyEngine,
  });

  final GalleryRepository galleryRepository;
  final CameraRepository cameraRepository;
  final CameraStorageRepository storageRepository;
  final CopyEngine copyEngine;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> with WidgetsBindingObserver {
  /// Big enough for the review screen on a high-density phone, small enough
  /// that the platform does not decode a full 50 MP original.
  static const int _previewCacheSize = 1400;

  late final GalleryViewModel _viewModel;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _viewModel = GalleryViewModel(widget.galleryRepository);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_viewModel.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _viewModel.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the system settings page is the common way to go from
    // "denied" to "granted"; re-read access without prompting.
    if (state == AppLifecycleState.resumed) {
      unawaited(_viewModel.recheckAccess());
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 900) {
      unawaited(_viewModel.loadMore());
    }
  }

  Future<void> _refresh() async {
    try {
      await _viewModel.refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not refresh the photo list.')),
      );
    }
  }

  Future<void> _openCameraPicker(PhotoAsset photo) async {
    final camera = await CameraPickerSheet.show(
      context,
      repository: widget.cameraRepository,
    );
    if (camera == null || !mounted) return;

    final preview = _viewModel.thumbnailFor(
      photo,
      cacheSize: _previewCacheSize,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CopyReviewPage(
          photo: photo,
          camera: camera,
          copyEngine: widget.copyEngine,
          storageRepository: widget.storageRepository,
          preview: preview,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final viewModel = _viewModel;
        final showChrome =
            viewModel.status == GalleryStatus.ready ||
            viewModel.status == GalleryStatus.empty;
        final limited =
            viewModel.access.isLimited && viewModel.access.canBrowse;

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 76,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Recent photos'),
                if (showChrome) ...[
                  const SizedBox(height: 1),
                  Text(
                    _photoCountLabel(viewModel.totalCount),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              if (showChrome)
                IconButton(
                  tooltip: 'Refresh photos',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              const SizedBox(width: 8),
            ],
            bottom: limited
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(
                      LimitedAccessBanner.height,
                    ),
                    child: LimitedAccessBanner(
                      onManage: () =>
                          unawaited(viewModel.manageLimitedAccess()),
                    ),
                  )
                : null,
          ),
          body: _body(context, viewModel),
        );
      },
    );
  }

  Widget _body(BuildContext context, GalleryViewModel viewModel) {
    switch (viewModel.status) {
      case GalleryStatus.requestingAccess:
        return const _Busy(label: 'Asking for photo access…');
      case GalleryStatus.loading:
        return const _Busy(label: 'Loading photos…');
      case GalleryStatus.accessDenied:
        return SafeArea(
          child: PermissionPrompt(
            restricted: false,
            onRequestAccess: () => unawaited(viewModel.requestAccess()),
            onOpenSettings: () => unawaited(viewModel.openSystemSettings()),
          ),
        );
      case GalleryStatus.accessRestricted:
        return SafeArea(
          child: PermissionPrompt(
            restricted: true,
            onRequestAccess: () => unawaited(viewModel.requestAccess()),
            onOpenSettings: () => unawaited(viewModel.openSystemSettings()),
          ),
        );
      case GalleryStatus.error:
        return SafeArea(
          child: StatusMessage(
            icon: Icons.error_outline_rounded,
            title: "Couldn't load photos",
            message: viewModel.errorMessage ?? 'Unknown error.',
            actions: [
              FilledButton(
                onPressed: () => unawaited(viewModel.requestAccess()),
                child: const Text('Try again'),
              ),
              OutlinedButton(
                onPressed: () => unawaited(viewModel.openSystemSettings()),
                child: const Text('Open settings'),
              ),
            ],
          ),
        );
      case GalleryStatus.empty:
        return SafeArea(
          child: _EmptyGallery(
            isLimited: viewModel.access.isLimited,
            onSelectPhotos: () => unawaited(viewModel.manageLimitedAccess()),
            onRefresh: _refresh,
          ),
        );
      case GalleryStatus.ready:
        final tileCacheSize = (128 * MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(128, 512)
            .toInt();
        return PhotoGrid(
          photos: viewModel.photos,
          controller: _scrollController,
          thumbnailBuilder: (photo) =>
              viewModel.thumbnailFor(photo, cacheSize: tileCacheSize),
          onPhotoTap: _openCameraPicker,
          onRefresh: _refresh,
          isLoadingMore: viewModel.isLoadingMore,
          loadMoreError: viewModel.loadMoreError,
          onRetryLoadMore: () => unawaited(viewModel.loadMore()),
        );
    }
  }

  String _photoCountLabel(int count) {
    if (count == 0) return 'Nothing to show';
    return count == 1 ? '1 photo' : '$count photos';
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery({
    required this.isLimited,
    required this.onSelectPhotos,
    required this.onRefresh,
  });

  final bool isLimited;
  final VoidCallback onSelectPhotos;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return StatusMessage(
      icon: Icons.photo_library_outlined,
      title: isLimited ? 'No photos selected' : 'No photos yet',
      message: isLimited
          ? 'The app can only see the photos you selected for it. Choose a '
                'few from your library to start.'
          : 'The photo library on this device is empty.',
      actions: [
        if (isLimited)
          FilledButton(
            onPressed: onSelectPhotos,
            child: const Text('Select photos'),
          ),
        OutlinedButton(
          onPressed: () => unawaited(onRefresh()),
          child: const Text('Refresh'),
        ),
      ],
    );
  }
}
