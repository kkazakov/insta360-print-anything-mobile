import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/cameras/presentation/camera_picker_view_model.dart';

import '../../support/fakes.dart';

void main() {
  test('reports unsupported when the device has no USB host', () async {
    final repository = FakeCameraRepository(supported: false);
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);

    await viewModel.start();

    expect(viewModel.status, CameraScanStatus.unsupported);
    expect(repository.scanCount, 0);
  });

  test('reports empty when nothing is attached', () async {
    final repository = FakeCameraRepository();
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);

    await viewModel.start();

    expect(viewModel.status, CameraScanStatus.empty);
    expect(viewModel.cameras, isEmpty);
  });

  test('lists attached cameras', () async {
    final repository = FakeCameraRepository(cameras: [makeCamera()]);
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);

    await viewModel.start();

    expect(viewModel.status, CameraScanStatus.ready);
    expect(viewModel.cameras, hasLength(1));
    expect(viewModel.cameras.single.name, 'Insta360 GO Ultra');
  });

  test('select returns the camera once USB permission is granted', () async {
    final repository = FakeCameraRepository(cameras: [makeCamera()]);
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);
    await viewModel.start();

    final selected = await viewModel.select(viewModel.cameras.single);

    expect(selected, isNotNull);
    expect(selected!.permissionGranted, isTrue);
    expect(repository.permissionRequests, 1);
    expect(viewModel.permissionError, isNull);
    expect(viewModel.cameras.single.permissionGranted, isTrue);
  });

  test('select reports a denied USB prompt', () async {
    final repository = FakeCameraRepository(
      cameras: [makeCamera()],
      permissionResult: false,
    );
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);
    await viewModel.start();

    final selected = await viewModel.select(viewModel.cameras.single);

    expect(selected, isNull);
    expect(viewModel.permissionError, isNotNull);
    expect(viewModel.cameras.single.permissionGranted, isFalse);
  });

  test('select skips the prompt when permission is already held', () async {
    final repository = FakeCameraRepository(
      cameras: [makeCamera(permissionGranted: true)],
    );
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);
    await viewModel.start();

    final selected = await viewModel.select(viewModel.cameras.single);

    expect(selected, isNotNull);
    expect(repository.permissionRequests, 0);
  });

  test('a scan failure with nothing listed becomes an error state', () async {
    final repository = FakeCameraRepository(error: Exception('usb broke'));
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);

    await viewModel.start();

    expect(viewModel.status, CameraScanStatus.error);
    expect(viewModel.errorMessage, isNotNull);
  });

  test('a failed background poll keeps a populated list', () async {
    final repository = FakeCameraRepository(cameras: [makeCamera()]);
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);
    await viewModel.start();
    expect(viewModel.status, CameraScanStatus.ready);

    repository.error = Exception('unplugged mid-scan');
    await viewModel.refresh();

    expect(viewModel.status, CameraScanStatus.ready);
    expect(viewModel.cameras, hasLength(1));
  });

  test('refresh finds a camera plugged in after the sheet opened', () async {
    final repository = FakeCameraRepository();
    final viewModel = CameraPickerViewModel(repository, pollInterval: null);
    addTearDown(viewModel.dispose);
    await viewModel.start();
    expect(viewModel.status, CameraScanStatus.empty);

    repository.cameras = [makeCamera()];
    await viewModel.refresh();

    expect(viewModel.status, CameraScanStatus.ready);
    expect(viewModel.cameras, hasLength(1));
  });
}
