import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/photo_asset.dart';
import 'photo_tile.dart';

/// Responsive, lazily built photo grid.
///
/// One grid delegate scales from phone portrait (3 columns) to tablet
/// landscape (8+) because tiles get a maximum width instead of a fixed column
/// count; nothing needs to know the device class.
class PhotoGrid extends StatelessWidget {
  const PhotoGrid({
    super.key,
    required this.photos,
    required this.thumbnailBuilder,
    required this.onPhotoTap,
    required this.onRefresh,
    required this.isLoadingMore,
    required this.loadMoreError,
    required this.onRetryLoadMore,
    required this.controller,
  });

  final List<PhotoAsset> photos;
  final ImageProvider? Function(PhotoAsset photo) thumbnailBuilder;
  final ValueChanged<PhotoAsset> onPhotoTap;
  final Future<void> Function() onRefresh;
  final bool isLoadingMore;
  final String? loadMoreError;
  final VoidCallback onRetryLoadMore;
  final ScrollController controller;

  static const double _maxTileExtent = 128;
  static const double _gap = 4;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLarge = constraints.maxWidth >= 720;
        final horizontalPadding = isLarge ? 24.0 : 8.0;

        return RefreshIndicator(
          onRefresh: onRefresh,
          child: CustomScrollView(
            controller: controller,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  isLarge ? 12 : 4,
                  horizontalPadding,
                  0,
                ),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: _maxTileExtent,
                    mainAxisSpacing: _gap,
                    crossAxisSpacing: _gap,
                    childAspectRatio: 1,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (context, index) {
                    final photo = photos[index];
                    return PhotoTile(
                      key: ValueKey<String>(photo.id),
                      photo: photo,
                      imageProvider: thumbnailBuilder(photo),
                      onTap: () => onPhotoTap(photo),
                    );
                  },
                ),
              ),
              SliverToBoxAdapter(
                child: _Footer(
                  isLoadingMore: isLoadingMore,
                  loadMoreError: loadMoreError,
                  onRetry: onRetryLoadMore,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.isLoadingMore,
    required this.loadMoreError,
    required this.onRetry,
  });

  final bool isLoadingMore;
  final String? loadMoreError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    Widget child;
    if (isLoadingMore) {
      child = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (loadMoreError != null) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            loadMoreError!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      );
    } else {
      child = const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        math.max(24.0, bottomInset + 16),
      ),
      child: Center(child: child),
    );
  }
}
