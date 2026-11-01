import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../gallery/domain/photo_asset.dart';
import '../domain/crop_window.dart';

/// Full-screen 4:3 crop editor: pinch to zoom, drag to move, apply the window.
///
/// The native side receives the returned [CropWindow] as normalized source
/// coordinates, so the preview here uses the same geometry as the copy.
class CropEditorPage extends StatefulWidget {
  const CropEditorPage({
    super.key,
    required this.photo,
    required this.imageProvider,
    required this.initialCrop,
  });

  final PhotoAsset photo;
  final ImageProvider imageProvider;
  final CropWindow initialCrop;

  @override
  State<CropEditorPage> createState() => _CropEditorPageState();
}

class _CropEditorPageState extends State<CropEditorPage> {
  final GlobalKey<_CropCanvasState> _canvasKey = GlobalKey<_CropCanvasState>();

  void _apply() {
    final canvas = _canvasKey.currentState;
    if (canvas == null) return;
    final crop = canvas.currentCrop.clamp();
    if (!crop.isValid) return;
    Navigator.of(context).pop(crop);
  }

  void _reset() {
    _canvasKey.currentState?.reset();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Adjust crop'),
        actions: [
          TextButton(onPressed: _reset, child: const Text('Reset')),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _apply,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('Apply'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final frame = _frameSize(constraints.biggest);
                return Center(
                  child: _CropCanvas(
                    key: _canvasKey,
                    photo: widget.photo,
                    imageProvider: widget.imageProvider,
                    initialCrop: widget.initialCrop,
                    frame: frame,
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.pinch_outlined,
                        size: 18,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Pinch to zoom · drag to move',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "The 4:3 area becomes the camera's photo.",
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Size _frameSize(Size available) {
    const inset = 12.0;
    final maxWidth = math.max(1.0, available.width - inset * 2);
    final maxHeight = math.max(1.0, available.height - inset * 2);
    var width = maxWidth;
    var height = width / cameraFrameAspect;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * cameraFrameAspect;
    }
    return Size(width, height);
  }
}

class _CropCanvas extends StatefulWidget {
  const _CropCanvas({
    super.key,
    required this.photo,
    required this.imageProvider,
    required this.initialCrop,
    required this.frame,
  });

  final PhotoAsset photo;
  final ImageProvider imageProvider;
  final CropWindow initialCrop;
  final Size frame;

  @override
  State<_CropCanvas> createState() => _CropCanvasState();
}

class _CropCanvasState extends State<_CropCanvas> {
  static const double _maxZoom = 5;

  late final double _imageAspect;
  late double _displayWidth;
  late double _displayHeight;
  late final TransformationController _controller;

  @override
  void initState() {
    super.initState();
    final aspect = widget.photo.aspectRatio;
    _imageAspect = aspect.isFinite && aspect > 0 ? aspect : cameraFrameAspect;
    _updateDisplaySize();
    _controller = TransformationController(_matrixFor(widget.initialCrop));
  }

  @override
  void didUpdateWidget(covariant _CropCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame != widget.frame) {
      final crop = currentCrop;
      _updateDisplaySize();
      _controller.value = _matrixFor(crop);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _updateDisplaySize() {
    if (_imageAspect > widget.frame.width / widget.frame.height) {
      _displayHeight = widget.frame.height;
      _displayWidth = _displayHeight * _imageAspect;
    } else {
      _displayWidth = widget.frame.width;
      _displayHeight = _displayWidth / _imageAspect;
    }
  }

  Matrix4 _matrixFor(CropWindow window) {
    final safe = window.isValid
        ? window
        : CropWindow.centered(imageAspect: _imageAspect);
    final rawScale = math.max(
      widget.frame.width / (_displayWidth * safe.width),
      widget.frame.height / (_displayHeight * safe.height),
    );
    final scale = rawScale.clamp(1.0, _maxZoom).toDouble();
    return Matrix4.identity()
      ..translateByDouble(
        -safe.left * _displayWidth * scale,
        -safe.top * _displayHeight * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  CropWindow get currentCrop {
    final inverse = Matrix4.inverted(_controller.value);
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(
      inverse,
      Offset(widget.frame.width, widget.frame.height),
    );
    final left = (topLeft.dx / _displayWidth).clamp(0.0, 1.0).toDouble();
    final top = (topLeft.dy / _displayHeight).clamp(0.0, 1.0).toDouble();
    final right = (bottomRight.dx / _displayWidth).clamp(0.0, 1.0).toDouble();
    final bottom = (bottomRight.dy / _displayHeight).clamp(0.0, 1.0).toDouble();
    final crop = CropWindow(
      left: left,
      top: top,
      width: right - left,
      height: bottom - top,
    );
    return crop.isValid ? crop : CropWindow.centered(imageAspect: _imageAspect);
  }

  void reset() {
    _controller.value = _matrixFor(
      CropWindow.centered(imageAspect: _imageAspect),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.frame.width,
      height: widget.frame.height,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              key: const Key('crop-viewer'),
              constrained: false,
              transformationController: _controller,
              minScale: 1,
              maxScale: _maxZoom,
              boundaryMargin: EdgeInsets.zero,
              child: SizedBox(
                width: _displayWidth,
                height: _displayHeight,
                child: Image(
                  image: widget.imageProvider,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, error, stackTrace) => ColoredBox(
                    color: const Color(0xFF202024),
                    child: Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IgnorePointer(child: CustomPaint(painter: _CropGridPainter())),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.8),
                    width: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.32)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
