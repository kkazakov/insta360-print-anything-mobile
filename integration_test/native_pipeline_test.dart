import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/copy/data/camera_image_service.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/camera_image_pipeline.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/crop_window.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/jpeg.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photo_manager/photo_manager.dart';

/// The GO Ultra's quantisation tables, natural (Pillow) order, read from
/// `.dev-samples/IMG_20261101_085513_004.jpg`.
const List<int> _lumaNatural = <int>[
  2,
  1,
  14,
  15,
  16,
  16,
  3,
  15,
  1,
  12,
  16,
  16,
  1,
  2,
  19,
  6,
  2,
  1,
  13,
  1,
  2,
  18,
  4,
  6,
  1,
  2,
  2,
  1,
  16,
  2,
  18,
  12,
  1,
  2,
  16,
  2,
  18,
  10,
  10,
  12,
  14,
  17,
  2,
  10,
  11,
  9,
  10,
  11,
  16,
  4,
  11,
  19,
  8,
  7,
  10,
  10,
  6,
  17,
  5,
  6,
  9,
  10,
  10,
  10,
];

const List<int> _chromaNatural = <int>[
  2,
  2,
  10,
  10,
  10,
  10,
  10,
  10,
  2,
  10,
  10,
  10,
  2,
  10,
  10,
  10,
  5,
  2,
  10,
  3,
  7,
  10,
  10,
  10,
  2,
  7,
  6,
  5,
  10,
  10,
  10,
  10,
  3,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
];

const List<int> _zigzag = <int>[
  0,
  1,
  8,
  16,
  9,
  2,
  3,
  10,
  17,
  24,
  32,
  25,
  18,
  11,
  4,
  5,
  12,
  19,
  26,
  33,
  40,
  48,
  41,
  34,
  27,
  20,
  13,
  6,
  7,
  14,
  21,
  28,
  35,
  42,
  49,
  56,
  57,
  50,
  43,
  36,
  29,
  22,
  15,
  23,
  30,
  37,
  44,
  51,
  58,
  59,
  52,
  45,
  38,
  31,
  39,
  46,
  53,
  60,
  61,
  54,
  47,
  55,
  62,
  63,
];

List<int> _toZigzag(List<int> natural) => <int>[
  for (final index in _zigzag) natural[index],
];

Future<String> _newestPhotoPath() async {
  final permission = await PhotoManager.requestPermissionExtend();
  expect(
    permission.isAuth || permission.hasAccess,
    isTrue,
    reason: 'grant photo access to the app before running this test',
  );
  final paths = await PhotoManager.getAssetPathList(
    type: RequestType.image,
    onlyAll: true,
  );
  expect(paths, isNotEmpty);
  final assets = await paths.first.getAssetListRange(start: 0, end: 1);
  expect(assets, isNotEmpty);
  final file = await assets.first.file;
  expect(file, isNotNull);
  return file!.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native pipeline rebuilds a real phone photo at camera size', (
    tester,
  ) async {
    final sourcePath = await _newestPhotoPath();
    final service = CameraImageService();

    final prepared = await service.prepare(
      sourcePath: sourcePath,
      width: 4096,
      height: 3072,
      previewWidth: 704,
      previewHeight: 544,
      thumbWidth: 160,
      thumbHeight: 120,
      lumaZigzag: _toZigzag(_lumaNatural),
      chromaZigzag: _toZigzag(_chromaNatural),
      fit: CopyFit.crop,
    );

    expect(jpegDimensions(prepared.mainJpeg), (width: 4096, height: 3072));
    expect(jpegDimensions(prepared.previewJpeg), (width: 704, height: 544));
    expect(jpegDimensions(prepared.thumbnailJpeg), (width: 160, height: 120));
    expect(jpegQTables(prepared.mainJpeg), <List<int>>[
      _lumaNatural,
      _chromaNatural,
    ]);
    expect(embeddedPreview(prepared.mainJpeg), isNull);
    expect(prepared.nv21.length, 704 * 544 * 3 ~/ 2);
    expect(prepared.mainJpeg.length, greaterThan(500000));

    final output = File(
      '${Directory.systemTemp.path}/insta360-native-main.jpg',
    );
    await output.writeAsBytes(prepared.mainJpeg);
    // ignore: avoid_print
    print(
      'NATIVE-CROP main=${prepared.mainJpeg.length}B '
      'preview=${prepared.previewJpeg.length}B '
      'thumb=${prepared.thumbnailJpeg.length}B '
      'nv21=${prepared.nv21.length}B out=${output.path}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('native pipeline applies a custom crop window', (tester) async {
    final sourcePath = await _newestPhotoPath();
    final service = CameraImageService();

    final prepared = await service.prepare(
      sourcePath: sourcePath,
      width: 4096,
      height: 3072,
      previewWidth: 704,
      previewHeight: 544,
      thumbWidth: 160,
      thumbHeight: 120,
      lumaZigzag: _toZigzag(_lumaNatural),
      chromaZigzag: _toZigzag(_chromaNatural),
      fit: CopyFit.crop,
      crop: const CropWindow(left: 0.05, top: 0.1, width: 0.5, height: 0.4),
    );

    expect(jpegDimensions(prepared.mainJpeg), (width: 4096, height: 3072));
    expect(jpegDimensions(prepared.previewJpeg), (width: 704, height: 544));
    expect(jpegDimensions(prepared.thumbnailJpeg), (width: 160, height: 120));
    expect(prepared.nv21.length, 704 * 544 * 3 ~/ 2);

    final output = File(
      '${Directory.systemTemp.path}/insta360-native-custom-crop.jpg',
    );
    await output.writeAsBytes(prepared.mainJpeg);
    // ignore: avoid_print
    print(
      'NATIVE-CUSTOM-CROP main=${prepared.mainJpeg.length}B out=${output.path}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('native pipeline supports the pad fit', (tester) async {
    final sourcePath = await _newestPhotoPath();
    final service = CameraImageService();

    final prepared = await service.prepare(
      sourcePath: sourcePath,
      width: 1024,
      height: 768,
      previewWidth: 320,
      previewHeight: 240,
      thumbWidth: 160,
      thumbHeight: 120,
      lumaZigzag: _toZigzag(_lumaNatural),
      chromaZigzag: _toZigzag(_chromaNatural),
      fit: CopyFit.pad,
    );

    expect(jpegDimensions(prepared.mainJpeg), (width: 1024, height: 768));
    expect(jpegDimensions(prepared.previewJpeg), (width: 320, height: 240));
    expect(prepared.nv21.length, 320 * 240 * 3 ~/ 2);

    final output = File('${Directory.systemTemp.path}/insta360-native-pad.jpg');
    await output.writeAsBytes(prepared.mainJpeg);
    // ignore: avoid_print
    print('NATIVE-PAD main=${prepared.mainJpeg.length}B out=${output.path}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
