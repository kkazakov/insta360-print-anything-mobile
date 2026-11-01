import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/cameras/domain/camera_storage.dart';
import 'package:insta360_print_anything_mobile/features/copy/data/camera_copy_engine.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/camera_image_pipeline.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/copy_engine.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/copy_request.dart';
import 'package:insta360_print_anything_mobile/features/copy/domain/crop_window.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/exif.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/jpeg.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/meta.dart';
import 'package:insta360_print_anything_mobile/features/copy/format/template.dart';

import '../../support/fakes.dart';

class _FakeImagePipeline implements CameraImagePipeline {
  _FakeImagePipeline({
    required this.mainJpeg,
    required this.previewJpeg,
    required this.thumbnailJpeg,
    required this.nv21,
    required this.width,
    required this.height,
  });

  final Uint8List mainJpeg;
  final Uint8List previewJpeg;
  final Uint8List thumbnailJpeg;
  final Uint8List nv21;
  final int width;
  final int height;

  CopyFit? lastFit;
  CropWindow? lastCrop;

  @override
  Future<PreparedCameraImages> prepare({
    required String sourcePath,
    required int width,
    required int height,
    required int previewWidth,
    required int previewHeight,
    required int thumbWidth,
    required int thumbHeight,
    required List<int> lumaZigzag,
    required List<int> chromaZigzag,
    required CopyFit fit,
    CropWindow? crop,
  }) async {
    lastFit = fit;
    lastCrop = crop;
    return PreparedCameraImages(
      mainJpeg: mainJpeg,
      previewJpeg: previewJpeg,
      thumbnailJpeg: thumbnailJpeg,
      nv21: nv21,
      width: this.width,
      height: this.height,
    );
  }

  @override
  Future<({int width, int height})> jpegInfo(Uint8List bytes) async =>
      (width: width, height: height);
}

const String _samplePath = '.dev-samples/IMG_20261101_085513_004.jpg';
const String _indexPath = '.dev-samples/fileinfo_list.list';
const String _editPath = '.dev-samples/.editinfo_list.list';

bool get _hasSamples =>
    File(_samplePath).existsSync() &&
    File(_indexPath).existsSync() &&
    File(_editPath).existsSync();

void main() {
  if (!_hasSamples) {
    test('camera copy engine tests need .dev-samples', () {}, skip: true);
    return;
  }

  late Uint8List sample;
  late CameraTemplate template;
  late Uint8List preview;
  late Uint8List thumbnail;
  late Uint8List nv21;
  late Uint8List indexBytes;
  late Uint8List editBytes;

  setUpAll(() {
    sample = File(_samplePath).readAsBytesSync();
    indexBytes = File(_indexPath).readAsBytesSync();
    editBytes = File(_editPath).readAsBytesSync();
    template = analyseTemplate(sample, fileName: 'IMG_20261101_085513_004.jpg');
    preview = template.preview!;
    thumbnail = template.thumbnail!;
    final end = bodyEnd(sample);
    final trailer = Uint8List.sublistView(sample, end);
    final bulk = bulkInfo(trailer)!;
    nv21 = Uint8List.fromList(
      sample.sublist(end + bulk.offset, end + bulk.offset + bulk.size),
    );
  });

  late FakeGalleryRepository gallery;
  late FakeCameraStorage storage;
  late _FakeImagePipeline pipeline;
  late CameraCopyEngine engine;

  setUp(() {
    gallery = FakeGalleryRepository(photos: makePhotos(1))
      ..sourcePath = '/tmp/phone-photo.jpg';
    storage = FakeCameraStorage(
      files: <String, Uint8List>{
        'DCIM/Camera01/IMG_20261101_085513_004.jpg': sample,
        CameraStoragePaths.index: indexBytes,
        'DCIM/.editinfo_list.list': editBytes,
      },
    );
    pipeline = _FakeImagePipeline(
      mainJpeg: sample,
      previewJpeg: preview,
      thumbnailJpeg: thumbnail,
      nv21: nv21,
      width: template.width,
      height: template.height,
    );
    engine = CameraCopyEngine(
      gallery,
      pipeline,
      clock: () => DateTime(2020, 1, 1, 12),
    );
  });

  CopyRequest requestFor({CopyFit fit = CopyFit.crop, CropWindow? crop}) {
    return CopyRequest(
      photo: makePhotos(1).first,
      camera: makeCamera(),
      storage: storage,
      fit: fit,
      crop: crop,
    );
  }

  test('builds, writes and indexes a camera original', () async {
    final progress = <CopyPhase>[];
    final result = await engine.copy(
      requestFor(),
      onProgress: (update) => progress.add(update.phase),
    );

    expect(result.success, isTrue, reason: result.message);

    const destination = 'DCIM/Camera01/IMG_20261101_085613_005.jpg';
    final bytes = storage.files[destination];
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(3 * 1024 * 1024));

    final layout = splitMarkers(bytes);
    expect(layout.segments.first.marker, 0xE1);
    expect(
      layout.segments.first.payload.sublist(0, 6),
      'Exif\x00\x00'.codeUnits,
    );
    expect(jpegDimensions(bytes), (width: 4096, height: 3072));
    expect(jpegQTables(bytes), template.qtables);
    expect(embeddedPreview(bytes), isNotNull);

    final summary = readExifSummary(layout.segments.first.payload)!;
    expect(summary.imageDescription, 'IMG_20261101_085613_005.jpg');
    expect(summary.model, 'Insta360 GO Ultra');
    expect(summary.pixelXDimension, 4096);
    expect(summary.pixelYDimension, 3072);
    expect(summary.dateTime, '2026:11:01 08:56:13');

    final end = bodyEnd(bytes);
    final trailer = Uint8List.sublistView(bytes, end);
    final info = metaInfo(trailer)!;
    expect(info.fileOffset, end + info.blobOffset);
    expect(info.timestamp.toString(), '20261101085613');
    expect(info.serial, template.serial);
    expect(uidOf(trailer), template.uid);

    final records = indexRecords(storage.files[CameraStoragePaths.index]!);
    expect(records, hasLength(6));
    expect(records.first.path, '/$destination');
    expect(
      records.first.blob,
      Uint8List.sublistView(
        trailer,
        info.blobOffset,
        info.blobOffset + info.blobLength,
      ),
    );

    final editRecords = indexRecords(
      storage.files['DCIM/.editinfo_list.list']!,
    );
    expect(editRecords, hasLength(6));
    expect(editRecords.first.path, '/$destination');

    expect(pipeline.lastFit, CopyFit.crop);
    expect(
      progress,
      containsAll(<CopyPhase>[
        CopyPhase.readingCamera,
        CopyPhase.rebuilding,
        CopyPhase.verifying,
        CopyPhase.writing,
        CopyPhase.indexing,
      ]),
    );
    expect(result.message, contains('IMG_20261101_085613_005.jpg'));
  });

  test('passes the pad fit through to the native pipeline', () async {
    final result = await engine.copy(requestFor(fit: CopyFit.pad));

    expect(result.success, isTrue, reason: result.message);
    expect(pipeline.lastFit, CopyFit.pad);
    expect(pipeline.lastCrop, isNull);
  });

  test('passes a custom crop through to the native pipeline', () async {
    const crop = CropWindow(left: 0.1, top: 0.2, width: 0.5, height: 0.4);
    final result = await engine.copy(requestFor(crop: crop));

    expect(result.success, isTrue, reason: result.message);
    expect(pipeline.lastFit, CopyFit.crop);
    expect(pipeline.lastCrop, crop);
  });

  test('requires storage access', () async {
    final result = await engine.copy(
      CopyRequest(photo: makePhotos(1).first, camera: makeCamera()),
    );

    expect(result.success, isFalse);
    expect(result.message, contains('Grant access'));
  });

  test('explains when the camera has no photos yet', () async {
    storage.files.remove('DCIM/Camera01/IMG_20261101_085513_004.jpg');

    final result = await engine.copy(requestFor());

    expect(result.success, isFalse);
    expect(result.message, contains('no photos yet'));
  });

  test('fails cleanly when the phone photo cannot be read', () async {
    gallery.sourcePath = null;

    final result = await engine.copy(requestFor());

    expect(result.success, isFalse);
    expect(result.message, contains('cannot be read'));
  });

  test('rolls back the file when the index update fails', () async {
    storage.failingWrites.add(CameraStoragePaths.index);
    final oldIndex = storage.files[CameraStoragePaths.index];

    final result = await engine.copy(requestFor());

    expect(result.success, isFalse);
    expect(
      storage.files.containsKey('DCIM/Camera01/IMG_20261101_085613_005.jpg'),
      isFalse,
      reason: 'the unindexed file is removed again',
    );
    expect(storage.files[CameraStoragePaths.index], oldIndex);
  });
}
