import 'package:flutter/material.dart';

import '../../domain/photo_asset.dart';

/// One square thumbnail in the gallery grid.
///
/// The image is supplied by the view model (an [ImageProvider] backed by the
/// platform thumbnail cache); a missing provider renders a neutral placeholder
/// instead of an exception.
class PhotoTile extends StatelessWidget {
  const PhotoTile({
    super.key,
    required this.photo,
    required this.imageProvider,
    required this.onTap,
  });

  final PhotoAsset photo;
  final ImageProvider? imageProvider;
  final VoidCallback onTap;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(10));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      button: true,
      label: _semanticsLabel(context),
      child: ClipRRect(
        borderRadius: _radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHigh),
            if (imageProvider != null)
              Image(
                image: imageProvider!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: child,
                  );
                },
                errorBuilder: (context, error, stackTrace) => Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              )
            else
              Center(
                child: Icon(
                  Icons.image_outlined,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                ),
              ),
            // The tap layer sits above the image so the ripple stays visible.
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onTap,
                  splashFactory: InkRipple.splashFactory,
                  overlayColor: WidgetStatePropertyAll(
                    scheme.primary.withValues(alpha: 0.14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _semanticsLabel(BuildContext context) {
    final date = photo.createdAt;
    if (date == null) return 'Photo';
    final formatted = MaterialLocalizations.of(context).formatShortDate(date);
    return 'Photo from $formatted';
  }
}
