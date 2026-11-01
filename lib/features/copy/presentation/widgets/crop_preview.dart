import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/crop_window.dart';

/// Paints the part of [imageProvider] selected by [crop], filling its box.
///
/// The box must have [cameraFrameAspect]; the image is shown at "cover" size
/// and offset/scaled so exactly the stored crop is visible.
class CropPreview extends StatelessWidget {
  const CropPreview({
    super.key,
    required this.imageProvider,
    required this.imageAspect,
    required this.crop,
  });

  final ImageProvider imageProvider;
  final double imageAspect;
  final CropWindow crop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final frameWidth = constraints.maxWidth;
        final frameHeight = constraints.maxHeight;
        if (frameWidth <= 0 || frameHeight <= 0) {
          return const SizedBox.shrink();
        }

        final aspect = imageAspect.isFinite && imageAspect > 0
            ? imageAspect
            : cameraFrameAspect;
        final double displayWidth;
        final double displayHeight;
        if (aspect > frameWidth / frameHeight) {
          displayHeight = frameHeight;
          displayWidth = frameHeight * aspect;
        } else {
          displayWidth = frameWidth;
          displayHeight = frameWidth / aspect;
        }

        final safeCrop = crop.isValid ? crop : CropWindow.full;
        final scale = math.max(
          frameWidth / (displayWidth * safeCrop.width),
          frameHeight / (displayHeight * safeCrop.height),
        );
        final scaledWidth = displayWidth * scale;
        final scaledHeight = displayHeight * scale;

        return ClipRect(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: -safeCrop.left * scaledWidth,
                top: -safeCrop.top * scaledHeight,
                width: scaledWidth,
                height: scaledHeight,
                child: Image(
                  image: imageProvider,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, error, stackTrace) => ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
