import 'package:flutter/material.dart';

import '../../cameras/domain/camera_storage.dart';
import '../../cameras/domain/usb_camera.dart';
import '../../gallery/domain/photo_asset.dart';
import '../domain/camera_image_pipeline.dart';
import '../domain/copy_engine.dart';
import '../domain/copy_request.dart';
import '../domain/crop_window.dart';
import 'crop_editor_page.dart';
import 'widgets/crop_preview.dart';

/// Final confirmation before a photo is written to the camera.
///
/// Shows exactly what will happen, then hands the request to the [CopyEngine].
/// The engine is the only piece that changes in stage 2.
class CopyReviewPage extends StatefulWidget {
  const CopyReviewPage({
    super.key,
    required this.photo,
    required this.camera,
    required this.copyEngine,
    required this.storageRepository,
    this.preview,
  });

  final PhotoAsset photo;
  final UsbCamera camera;
  final CopyEngine copyEngine;
  final CameraStorageRepository storageRepository;

  /// Full-size-ish preview of the chosen photo (may be null if unavailable).
  final ImageProvider? preview;

  @override
  State<CopyReviewPage> createState() => _CopyReviewPageState();
}

class _CopyReviewPageState extends State<CopyReviewPage> {
  bool _isCopying = false;
  String? _copyProgress;
  CopyFit _fit = CopyFit.crop;
  late CropWindow _crop;
  bool _isLoadingStorage = true;
  bool _isGrantingStorage = false;
  CameraStorage? _storage;
  String? _storageError;

  @override
  void initState() {
    super.initState();
    _crop = CropWindow.centered(imageAspect: widget.photo.aspectRatio);
    _loadStorage();
  }

  Future<void> _adjustCrop() async {
    final imageProvider = widget.preview;
    if (imageProvider == null) return;
    final crop = await Navigator.of(context).push<CropWindow>(
      MaterialPageRoute<CropWindow>(
        builder: (context) => CropEditorPage(
          photo: widget.photo,
          imageProvider: imageProvider,
          initialCrop: _crop,
        ),
      ),
    );
    if (crop == null || !mounted) return;
    setState(() => _crop = crop);
  }

  Future<void> _loadStorage() async {
    try {
      final storage = await widget.storageRepository.grantedStorageFor(
        widget.camera,
      );
      var usable = false;
      if (storage != null) {
        usable = await _storageHasIndex(storage);
      }
      if (!mounted) return;
      setState(() {
        _storage = usable ? storage : null;
        _isLoadingStorage = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingStorage = false;
        _storageError = 'Could not read the camera storage.';
      });
    }
  }

  Future<bool> _storageHasIndex(CameraStorage storage) async {
    try {
      return await storage.exists(CameraStoragePaths.index);
    } catch (_) {
      return false;
    }
  }

  Future<void> _grantStorage() async {
    if (_isGrantingStorage) return;
    setState(() {
      _isGrantingStorage = true;
      _storageError = null;
    });

    try {
      final storage = await widget.storageRepository.requestStorageFor(
        widget.camera,
      );
      if (!mounted) return;
      setState(() {
        _storage = storage;
        _isGrantingStorage = false;
      });
    } on CameraStorageException catch (error) {
      if (!mounted) return;
      setState(() {
        _storageError = error.message;
        _isGrantingStorage = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _storageError = 'Could not open the camera storage.';
        _isGrantingStorage = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unavailableReason = widget.copyEngine.unavailableReason;

    return Scaffold(
      appBar: AppBar(title: const Text('Copy to camera')),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _Preview(
              photo: widget.photo,
              imageProvider: widget.preview,
              fit: _fit,
              crop: _crop,
              onAdjust: widget.preview == null ? null : _adjustCrop,
            ),
            const SizedBox(height: 18),
            if (unavailableReason != null) ...[
              _Notice(
                icon: Icons.construction_rounded,
                title: 'Not ready to write yet',
                message: unavailableReason,
                background: scheme.tertiaryContainer.withValues(alpha: 0.45),
                foreground: scheme.onTertiaryContainer,
              ),
              const SizedBox(height: 14),
            ],
            _StorageCard(
              isLoading: _isLoadingStorage,
              storage: _storage,
              error: _storageError,
              isGranting: _isGrantingStorage,
              onGrant: _grantStorage,
            ),
            const SizedBox(height: 12),
            _InfoCard(
              title: 'Your photo',
              children: [
                _InfoRow(label: 'Size', value: _sizeLabel(widget.photo)),
                _InfoRow(label: 'Taken', value: _dateLabel(context)),
                const SizedBox(height: 12),
                SegmentedButton<CopyFit>(
                  segments: const <ButtonSegment<CopyFit>>[
                    ButtonSegment<CopyFit>(
                      value: CopyFit.crop,
                      label: Text('Crop'),
                      icon: Icon(Icons.crop_rounded, size: 16),
                    ),
                    ButtonSegment<CopyFit>(
                      value: CopyFit.pad,
                      label: Text('Fit'),
                      icon: Icon(Icons.fit_screen_rounded, size: 16),
                    ),
                  ],
                  selected: <CopyFit>{_fit},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    setState(() => _fit = selection.first);
                  },
                ),
                if (_fit == CopyFit.crop)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('adjust-crop'),
                      onPressed: widget.preview == null ? null : _adjustCrop,
                      icon: const Icon(Icons.crop_free_rounded, size: 18),
                      label: const Text('Adjust crop'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                const SizedBox(height: 2),
                Text(
                  _fit == CopyFit.crop
                      ? 'Fills the camera frame; tap Adjust crop to zoom and '
                            'choose what stays.'
                      : 'Keeps the whole photo; black bars fill the frame.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoCard(
              title: 'Target camera',
              children: [
                _InfoRow(label: 'Name', value: widget.camera.name),
                _InfoRow(label: 'USB id', value: widget.camera.vendorProductId),
                _InfoRow(
                  label: 'Storage',
                  value: widget.camera.massStorage
                      ? 'USB mass storage'
                      : 'No storage interface',
                ),
                if (widget.camera.serialNumber != null)
                  _InfoRow(label: 'Serial', value: widget.camera.serialNumber!),
              ],
            ),
            const SizedBox(height: 12),
            const _InfoCard(
              title: 'What the copy does',
              children: [
                _Step(
                  number: 1,
                  text:
                      'Reads a photo already on the camera to borrow its '
                      'identity: model, serial, EXIF, quantisation tables and '
                      'the proprietary trailer.',
                ),
                _Step(
                  number: 2,
                  text:
                      'Rebuilds your photo as a camera JPEG and dates it as '
                      'the newest shot, so it appears first in the camera '
                      'gallery.',
                ),
                _Step(
                  number: 3,
                  text:
                      'Writes it into DCIM/Camera01 and registers it in '
                      'DCIM/fileinfo_list.list.',
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isCopying && _copyProgress != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _copyProgress!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              FilledButton.icon(
                onPressed: _isCopying || _storage == null ? null : _copy,
                icon: _isCopying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded, size: 20),
                label: Text(_isCopying ? 'Copying…' : 'Copy to camera'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy() async {
    setState(() {
      _isCopying = true;
      _copyProgress = null;
    });
    CopyResult result;
    try {
      result = await widget.copyEngine.copy(
        CopyRequest(
          photo: widget.photo,
          camera: widget.camera,
          storage: _storage,
          fit: _fit,
          crop: _fit == CopyFit.crop ? _crop : null,
        ),
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _copyProgress = progress.message);
        },
      );
    } catch (error) {
      result = CopyResult.failure('Copy failed: $error');
    }
    if (!mounted) return;
    setState(() {
      _isCopying = false;
      _copyProgress = null;
    });

    final message = result.message;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          result.success
              ? Icons.check_circle_outline_rounded
              : Icons.info_outline_rounded,
        ),
        title: Text(result.success ? 'Copied to camera' : 'Not copied yet'),
        content: Text(
          message ??
              (result.success
                  ? 'The photo is now in ${widget.camera.name}\'s gallery.'
                  : 'The photo was not written to the camera.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          if (result.success)
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop();
              },
              child: const Text('Done'),
            ),
        ],
      ),
    );
  }

  String _sizeLabel(PhotoAsset photo) {
    final megapixels = photo.megapixels;
    final mp = megapixels >= 0.05
        ? ' · ${megapixels.toStringAsFixed(1)} MP'
        : '';
    return '${photo.width} × ${photo.height}$mp';
  }

  String _dateLabel(BuildContext context) {
    final date = widget.photo.createdAt;
    if (date == null) return 'Unknown';
    final localizations = MaterialLocalizations.of(context);
    final day = localizations.formatFullDate(date);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(date),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '$day · $time';
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({
    required this.isLoading,
    required this.storage,
    required this.error,
    required this.isGranting,
    required this.onGrant,
  });

  final bool isLoading;
  final CameraStorage? storage;
  final String? error;
  final bool isGranting;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget content;
    if (isLoading) {
      content = Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Checking folder access…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    } else if (storage != null) {
      content = Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Folder access granted',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Mounted as “${storage!.label}”',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: isGranting ? null : onGrant,
            child: const Text('Change'),
          ),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.folder_off_outlined, size: 20, color: scheme.tertiary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Folder access needed',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Android needs permission to read and write the camera drive. '
            'Pick the drive itself (named “disk” on most Insta360 cameras) and '
            'the app remembers it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.error,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: isGranting ? null : onGrant,
            icon: isGranting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open_rounded, size: 18),
            label: Text(isGranting ? 'Opening…' : 'Choose camera folder'),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CAMERA STORAGE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 10),
          content,
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.photo,
    required this.imageProvider,
    required this.fit,
    required this.crop,
    required this.onAdjust,
  });

  final PhotoAsset photo;
  final ImageProvider? imageProvider;
  final CopyFit fit;
  final CropWindow crop;
  final VoidCallback? onAdjust;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 300,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: fit == CopyFit.pad ? Colors.black : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: imageProvider == null
          ? Center(
              child: Icon(
                Icons.image_outlined,
                size: 36,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            )
          : fit == CopyFit.pad
          ? _ContainedPreview(imageProvider: imageProvider!)
          : Center(
              child: AspectRatio(
                aspectRatio: cameraFrameAspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CropPreview(
                      imageProvider: imageProvider!,
                      imageAspect: photo.aspectRatio,
                      crop: crop,
                    ),
                    const Positioned(left: 10, top: 10, child: _CropBadge()),
                    if (onAdjust != null)
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: FilledButton.tonalIcon(
                          key: const Key('adjust-crop-overlay'),
                          onPressed: onAdjust,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.crop_free_rounded, size: 16),
                          label: const Text('Adjust'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _CropBadge extends StatelessWidget {
  const _CropBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'CROP 4:3',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class _ContainedPreview extends StatelessWidget {
  const _ContainedPreview({required this.imageProvider});

  final ImageProvider imageProvider;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: imageProvider,
      fit: BoxFit.contain,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 200),
          child: child,
        );
      },
      errorBuilder: (context, error, stackTrace) => Icon(
        Icons.broken_image_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.message,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String title;
  final String message;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: foreground,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
