import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/debug/demo_camera.dart';
import '../../../core/ui/status_message.dart';
import '../domain/camera_repository.dart';
import '../domain/usb_camera.dart';
import 'camera_picker_view_model.dart';
import 'widgets/camera_card.dart';

/// Bottom sheet listing attached USB cameras; returns the chosen camera.
///
/// It owns its view model and polls while visible, so the camera can be
/// plugged in after the sheet is already open.
class CameraPickerSheet extends StatefulWidget {
  const CameraPickerSheet({super.key, required this.repository});

  final CameraRepository repository;

  /// Opens the sheet and resolves to the chosen camera (null when dismissed).
  static Future<UsbCamera?> show(
    BuildContext context, {
    required CameraRepository repository,
  }) {
    return showModalBottomSheet<UsbCamera>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => CameraPickerSheet(repository: repository),
    );
  }

  @override
  State<CameraPickerSheet> createState() => _CameraPickerSheetState();
}

class _CameraPickerSheetState extends State<CameraPickerSheet> {
  late final CameraPickerViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = CameraPickerViewModel(widget.repository);
    unawaited(_viewModel.start());
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final height = (MediaQuery.sizeOf(context).height * 0.68)
        .clamp(300.0, 560.0)
        .toDouble();

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        return SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 6),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.usb_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Choose a camera',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _subtitle(_viewModel),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _viewModel.isScanning
                          ? null
                          : _viewModel.refresh,
                      tooltip: 'Scan again',
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
              if (_viewModel.permissionError != null)
                _PermissionErrorBanner(message: _viewModel.permissionError!),
              Expanded(child: _buildContent(context)),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  8,
                  20,
                  12 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'The camera must be in USB storage / file transfer mode.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _subtitle(CameraPickerViewModel viewModel) {
    return switch (viewModel.status) {
      CameraScanStatus.scanning => 'Looking for connected cameras…',
      CameraScanStatus.ready =>
        viewModel.cameras.length == 1
            ? '1 camera connected over USB'
            : '${viewModel.cameras.length} cameras connected over USB',
      CameraScanStatus.empty => 'Nothing attached yet',
      CameraScanStatus.unsupported => 'USB host unavailable',
      CameraScanStatus.error => 'Scan failed',
    };
  }

  Widget _buildContent(BuildContext context) {
    final viewModel = _viewModel;
    switch (viewModel.status) {
      case CameraScanStatus.scanning:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: 14),
              Text('Looking for connected cameras…'),
            ],
          ),
        );
      case CameraScanStatus.unsupported:
        return const StatusMessage(
          compact: true,
          icon: Icons.usb_off_rounded,
          title: 'USB host is not available',
          message:
              'This device cannot talk to USB accessories, so an Insta360 '
              'camera cannot be reached from here.',
        );
      case CameraScanStatus.error:
        return StatusMessage(
          compact: true,
          icon: Icons.error_outline_rounded,
          title: 'Could not scan USB',
          message: viewModel.errorMessage ?? 'The USB device list failed.',
          actions: [
            OutlinedButton(
              onPressed: viewModel.refresh,
              child: const Text('Scan again'),
            ),
          ],
        );
      case CameraScanStatus.empty:
        return StatusMessage(
          compact: true,
          icon: Icons.usb_rounded,
          title: 'No Insta360 camera found',
          message:
              'Plug the camera in with a USB-C cable and set it to USB '
              'storage / file transfer mode. It will show up here.',
          actions: [
            OutlinedButton(
              onPressed: viewModel.refresh,
              child: const Text('Scan again'),
            ),
            if (kDemoCameraEnabled)
              OutlinedButton.icon(
                onPressed: _selectDemo,
                icon: const Icon(Icons.science_outlined, size: 18),
                label: const Text('Use demo camera folder'),
              ),
          ],
        );
      case CameraScanStatus.ready:
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          itemCount: viewModel.cameras.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final camera = viewModel.cameras[index];
            return CameraCard(
              key: ValueKey<String>(camera.deviceId),
              camera: camera,
              isBusy: viewModel.requestingDeviceId == camera.deviceId,
              onTap: () => _select(camera),
            );
          },
        );
    }
  }

  Future<void> _select(UsbCamera camera) async {
    final selected = await _viewModel.select(camera);
    if (!mounted || selected == null) return;
    Navigator.of(context).pop(selected);
  }

  void _selectDemo() {
    Navigator.of(context).pop(demoCamera());
  }
}

class _PermissionErrorBanner extends StatelessWidget {
  const _PermissionErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onErrorContainer, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
