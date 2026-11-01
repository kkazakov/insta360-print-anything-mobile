import 'dart:math' as math;
import 'dart:typed_data';

import '../../cameras/domain/camera_storage.dart';
import '../../gallery/domain/gallery_repository.dart';
import '../domain/camera_image_pipeline.dart';
import '../domain/copy_engine.dart';
import '../domain/copy_request.dart';
import '../format/exif.dart';
import '../format/jpeg.dart';
import '../format/meta.dart';
import '../format/template.dart';

/// Copies a phone photo onto the connected camera by rebuilding it as a
/// camera-original JPEG and registering it in the camera's own index.
///
/// Pipeline: newest camera photo -> template -> native re-encode with the
/// camera's DQT -> EXIF/trailer/index patches -> write -> verify.
class CameraCopyEngine implements CopyEngine {
  CameraCopyEngine(this._gallery, this._images, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final GalleryRepository _gallery;
  final CameraImagePipeline _images;
  final DateTime Function() _clock;

  static const String _indexPath = CameraStoragePaths.index;
  static const String _editIndexPath = 'DCIM/.editinfo_list.list';
  static const int _smallModeArea = 4096 * 3072;
  static const int _maxTemplateReads = 6;

  @override
  String? get unavailableReason => null;

  @override
  Future<CopyResult> copy(
    CopyRequest request, {
    void Function(CopyProgress progress)? onProgress,
  }) async {
    final storage = request.storage;
    if (storage == null) {
      return const CopyResult.failure(
        'Grant access to the camera storage before copying.',
      );
    }
    try {
      return await _copy(request, storage, onProgress);
    } on _CopyFailure catch (failure) {
      return CopyResult.failure(failure.message);
    } on CameraStorageException catch (error) {
      return CopyResult.failure(error.message);
    } on CameraImageException catch (error) {
      return CopyResult.failure(error.message);
    } catch (error) {
      return CopyResult.failure('Copy failed: $error');
    }
  }

  Future<CopyResult> _copy(
    CopyRequest request,
    CameraStorage storage,
    void Function(CopyProgress progress)? progress,
  ) async {
    _report(progress, CopyPhase.readingCamera, 'Reading the camera\'s photos…');

    final files = await storage.list(CameraStoragePaths.cameraDir);
    final candidates =
        files
            .where(
              (file) =>
                  !file.isDirectory && cameraNamePattern.hasMatch(file.name),
            )
            .toList()
          ..sort((a, b) => b.name.compareTo(a.name));
    if (candidates.isEmpty) {
      throw const _CopyFailure(
        'The camera has no photos yet. Take one photo with the camera, then '
        'copy again — the new file borrows the camera\'s identity from it.',
      );
    }

    final found = await _findTemplate(storage, candidates);
    final template = found.template;
    final width = template.width;
    final height = template.height;
    final previewWidth = template.previewWidth ?? 0;
    final previewHeight = template.previewHeight ?? 0;
    final thumbWidth = template.thumbnailWidth ?? 0;
    final thumbHeight = template.thumbnailHeight ?? 0;
    if (previewWidth <= 0 ||
        previewHeight <= 0 ||
        thumbWidth <= 0 ||
        thumbHeight <= 0) {
      throw const _CopyFailure(
        'The camera photo is missing its preview or thumbnail sizes.',
      );
    }

    final capture = _nextCaptureTime(found.newestCapture ?? template.captured);
    final sequence = _nextSequence(files, capture);
    if (sequence > 999) {
      throw const _CopyFailure(
        'This camera has used all 999 file numbers for today.',
      );
    }
    var name = cameraFileName(capture, sequence);
    var destination = '${CameraStoragePaths.cameraDir}/$name';
    var attempts = 0;
    while (await storage.exists(destination)) {
      attempts++;
      if (attempts > 20) {
        throw const _CopyFailure('Could not pick a free camera file name.');
      }
      name = cameraFileName(capture, sequence + attempts);
      destination = '${CameraStoragePaths.cameraDir}/$name';
    }

    _report(progress, CopyPhase.rebuilding, 'Rebuilding your photo…');

    final sourcePath = await _gallery.originalPath(request.photo);
    if (sourcePath == null) {
      throw const _CopyFailure(
        'The selected photo cannot be read from this device.',
      );
    }
    if (template.qtables.length < 2) {
      throw const _CopyFailure('The camera photo has no quantisation tables.');
    }
    final luma = _naturalToZigzag(template.qtables[0]);
    final chroma = _naturalToZigzag(template.qtables[1]);

    final prepared = await _images.prepare(
      sourcePath: sourcePath,
      width: width,
      height: height,
      previewWidth: previewWidth,
      previewHeight: previewHeight,
      thumbWidth: thumbWidth,
      thumbHeight: thumbHeight,
      lumaZigzag: luma,
      chromaZigzag: chroma,
      fit: request.fit,
    );
    if (prepared.width != width || prepared.height != height) {
      throw _CopyFailure(
        'The rebuilt image is ${prepared.width}×${prepared.height}, expected '
        '$width×$height.',
      );
    }

    // ---- assemble the camera container --------------------------------
    final app1 = template.app1;
    final trailerBase = template.trailer;
    if (app1 == null || trailerBase.isEmpty) {
      throw const _CopyFailure(
        'The camera photo has no EXIF or metadata trailer to borrow.',
      );
    }

    final patchedApp1 = patchExif(
      app1,
      filename: name,
      dateTime: capture,
      width: prepared.width,
      height: prepared.height,
      thumbnail: prepared.thumbnailJpeg,
    );
    final body = rebuildJpeg(
      encoded: prepared.mainJpeg,
      app1: patchedApp1,
      app2Chunks: chunkApp2(prepared.previewJpeg),
    );

    var trailer = patchPath(trailerBase, name);
    final info = metaInfo(trailer);
    if (info == null) {
      throw const _CopyFailure('The camera trailer has no metadata block.');
    }
    final bulk = bulkInfo(trailer, serial: info.serial);
    if (bulk == null) {
      throw const _CopyFailure(
        'The camera trailer has no raw gallery thumbnail.',
      );
    }
    if (bulk.width != previewWidth || bulk.height != previewHeight) {
      throw _CopyFailure(
        'The camera preview is ${bulk.width}×${bulk.height}, expected '
        '$previewWidth×$previewHeight.',
      );
    }
    final expectedBulk = prepared.nv21.length;
    if (bulk.size != expectedBulk) {
      throw _CopyFailure(
        'The rebuilt thumbnail is $expectedBulk bytes, the trailer wants '
        '${bulk.size}.',
      );
    }

    trailer = patchBulk(trailer, bulk, prepared.nv21);
    final fileOffset = body.length + info.blobOffset;
    trailer = patchMeta(
      trailer,
      serial: info.serial,
      fileOffset: fileOffset,
      capture: capture,
    );

    final bytes = Uint8List(body.length + trailer.length)
      ..setRange(0, body.length, body)
      ..setRange(body.length, body.length + trailer.length, trailer);

    _report(progress, CopyPhase.verifying, 'Verifying the new file…');
    final verification = _verifyFile(bytes, template, name, capture, prepared);
    if (verification != null) {
      throw _CopyFailure(verification);
    }
    final decoded = await _images.jpegInfo(bytes);
    if (decoded.width != prepared.width || decoded.height != prepared.height) {
      throw const _CopyFailure(
        'The rebuilt JPEG does not decode to the expected size.',
      );
    }

    // ---- write the file and update both indexes -----------------------
    _report(progress, CopyPhase.writing, 'Writing to the camera…');
    final oldIndex = await storage.read(_indexPath);
    final oldEditIndex = await storage.read(_editIndexPath);

    try {
      await storage.write(destination, bytes);
      final written = await storage.read(destination);
      if (written == null || written.length != bytes.length) {
        throw const _CopyFailure('The camera did not store the complete file.');
      }

      _report(progress, CopyPhase.indexing, 'Updating the camera index…');
      final blobInfo = metaInfo(trailer);
      if (blobInfo == null) {
        throw const _CopyFailure('The rebuilt trailer lost its metadata.');
      }
      final blob = Uint8List.fromList(
        trailer.sublist(
          blobInfo.blobOffset,
          blobInfo.blobOffset + blobInfo.blobLength,
        ),
      );
      final relativePath = '/$destination';
      final indexRecord = buildIndexRecord(relativePath, blob);
      final editRecord = buildEditRecord(relativePath);

      final newIndex = upsertRecords(
        oldIndex ?? Uint8List(0),
        relativePath,
        indexRecord,
        prepend: true,
      );
      final newEditIndex = upsertRecords(
        oldEditIndex ?? Uint8List(0),
        relativePath,
        editRecord,
        prepend: true,
      );
      await storage.write(_indexPath, newIndex);
      await storage.write(_editIndexPath, newEditIndex);

      final readBackIndex = await storage.read(_indexPath);
      IndexRecord? record;
      if (readBackIndex != null) {
        for (final entry in indexRecords(readBackIndex)) {
          if (entry.path == relativePath) {
            record = entry;
            break;
          }
        }
      }
      if (record == null || !_bytesEqual(record.blob, blob)) {
        throw const _CopyFailure(
          'The camera index did not accept the new record.',
        );
      }
      final readBackEdit = await storage.read(_editIndexPath);
      final editPresent =
          readBackEdit != null &&
          indexRecords(readBackEdit).any((entry) => entry.path == relativePath);
      if (!editPresent) {
        throw const _CopyFailure(
          'The camera edit index did not accept the new record.',
        );
      }
    } catch (_) {
      await _rollback(storage, destination, oldIndex, oldEditIndex);
      rethrow;
    }

    return CopyResult.success(
      message:
          'Copied “$name” (${prepared.width}×${prepared.height}). It should '
          'appear first in the camera gallery.',
    );
  }

  Future<({CameraTemplate template, DateTime? newestCapture})> _findTemplate(
    CameraStorage storage,
    List<RemoteFile> candidates,
  ) async {
    CameraTemplate? best;
    DateTime? newestCapture;

    for (final file in candidates.take(_maxTemplateReads)) {
      final bytes = await storage.read(file.path);
      if (bytes == null) continue;

      CameraTemplate template;
      try {
        template = analyseTemplate(bytes, fileName: file.name);
      } catch (_) {
        continue;
      }
      if (!_isUsableTemplate(template)) continue;

      final captured = template.captured;
      if (captured != null &&
          (newestCapture == null || captured.isAfter(newestCapture))) {
        newestCapture = captured;
      }
      if (best == null || _area(template) < _area(best)) {
        best = template;
      }
      if (_area(template) <= _smallModeArea * 1.01) {
        break; // prefer the camera's smallest mode for a fast, safe encode
      }
    }

    if (best == null) {
      throw const _CopyFailure(
        'No photo on the camera carries the metadata needed to build a '
        'camera original. Take a photo with the camera and try again.',
      );
    }
    return (template: best, newestCapture: newestCapture);
  }

  bool _isUsableTemplate(CameraTemplate template) {
    return template.isCameraPhoto &&
        template.app1 != null &&
        template.qtables.length >= 2 &&
        template.preview != null &&
        (template.previewWidth ?? 0) > 0 &&
        (template.previewHeight ?? 0) > 0 &&
        template.thumbnail != null &&
        (template.thumbnailWidth ?? 0) > 0 &&
        (template.thumbnailHeight ?? 0) > 0 &&
        template.trailer.isNotEmpty;
  }

  int _area(CameraTemplate template) => template.width * template.height;

  DateTime _nextCaptureTime(DateTime? newestCameraCapture) {
    final now = _clock().toLocal();
    final stamp = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
      now.second,
    );
    if (newestCameraCapture == null) return stamp;
    final floor = newestCameraCapture.add(const Duration(minutes: 1));
    return floor.isAfter(stamp) ? floor : stamp;
  }

  int _nextSequence(List<RemoteFile> files, DateTime capture) {
    final day =
        '${capture.year.toString().padLeft(4, '0')}'
        '${capture.month.toString().padLeft(2, '0')}'
        '${capture.day.toString().padLeft(2, '0')}';
    var highest = 0;
    for (final file in files) {
      final match = cameraNamePattern.firstMatch(file.name);
      if (match == null || match.group(1) != day) continue;
      final sequence = int.tryParse(match.group(3) ?? '');
      if (sequence != null) highest = math.max(highest, sequence);
    }
    return highest + 1;
  }

  String? _verifyFile(
    Uint8List bytes,
    CameraTemplate template,
    String name,
    DateTime capture,
    PreparedCameraImages prepared,
  ) {
    try {
      final layout = splitMarkers(bytes);
      if (layout.segments.isEmpty || layout.segments.first.marker != 0xE1) {
        return 'The rebuilt file does not start with APP1/EXIF.';
      }
      final app1 = layout.segments.first.payload;
      final summary = readExifSummary(app1);
      if (summary?.imageDescription != name) {
        return 'The rebuilt EXIF does not carry the new file name.';
      }
      if (summary?.model != template.model) {
        return 'The rebuilt EXIF does not name the camera model.';
      }
      final size = jpegDimensions(bytes);
      if (size.width != template.width || size.height != template.height) {
        return 'The rebuilt frame is ${size.width}×${size.height}, expected '
            '${template.width}×${template.height}.';
      }
      if (!_nestedIntListsEqual(jpegQTables(bytes), template.qtables)) {
        return 'The rebuilt quantisation tables do not match the template.';
      }
      if (embeddedPreview(bytes) == null) {
        return 'The rebuilt file has no hidden preview.';
      }
      final exifThumb = extractExifThumbnail(app1);
      if (exifThumb == null ||
          !_bytesEqual(exifThumb.jpeg, prepared.thumbnailJpeg)) {
        return 'The EXIF thumbnail was not replaced with the new photo.';
      }
      final end = bodyEnd(bytes);
      final trailer = Uint8List.sublistView(bytes, end);
      final info = metaInfo(trailer);
      if (info == null) {
        return 'The rebuilt trailer has no metadata block.';
      }
      if (info.fileOffset != end + info.blobOffset) {
        return 'The metadata pointer (field 9) does not point at the blob.';
      }
      final expectedTimestamp =
          '${capture.year.toString().padLeft(4, '0')}'
          '${capture.month.toString().padLeft(2, '0')}'
          '${capture.day.toString().padLeft(2, '0')}'
          '${capture.hour.toString().padLeft(2, '0')}'
          '${capture.minute.toString().padLeft(2, '0')}'
          '${capture.second.toString().padLeft(2, '0')}';
      if (info.timestamp?.toString() != expectedTimestamp) {
        return 'The metadata timestamp (field 7) does not match the name.';
      }
      if (template.serial != null && info.serial != template.serial) {
        return 'The rebuilt trailer lost the camera serial.';
      }
      if (uidOf(trailer) == null) {
        return 'The rebuilt trailer lost the device UID.';
      }
      final patchedBulk = bulkInfo(trailer, serial: info.serial);
      if (patchedBulk == null || patchedBulk.size != prepared.nv21.length) {
        return 'The rebuilt trailer lost its gallery thumbnail buffer.';
      }
      final actualBulk = Uint8List.sublistView(
        bytes,
        end + patchedBulk.offset,
        end + patchedBulk.offset + patchedBulk.size,
      );
      if (!_bytesEqual(actualBulk, prepared.nv21)) {
        return 'The gallery thumbnail buffer does not match the new photo.';
      }
      return null;
    } catch (error) {
      return 'The rebuilt file failed verification: $error';
    }
  }

  Future<void> _rollback(
    CameraStorage storage,
    String destination,
    Uint8List? oldIndex,
    Uint8List? oldEditIndex,
  ) async {
    if (oldIndex != null) {
      try {
        await storage.write(_indexPath, oldIndex);
      } catch (_) {}
    }
    if (oldEditIndex != null) {
      try {
        await storage.write(_editIndexPath, oldEditIndex);
      } catch (_) {}
    }
    try {
      await storage.delete(destination);
    } catch (_) {}
  }

  void _report(
    void Function(CopyProgress progress)? callback,
    CopyPhase phase,
    String message,
  ) {
    if (callback == null) return;
    try {
      callback(CopyProgress(phase, message));
    } catch (_) {
      // A disposed UI must not fail the copy.
    }
  }

  static const List<int> _zigzag = <int>[
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

  List<int> _naturalToZigzag(List<int> natural) {
    if (natural.length != 64) {
      throw const _CopyFailure('The camera quantisation table is not 64 long.');
    }
    final zigzag = List<int>.generate(64, (index) => natural[_zigzag[index]]);
    for (final value in zigzag) {
      if (value < 1 || value > 255) {
        throw _CopyFailure(
          'Unsupported quantisation value $value (the camera uses 8-bit '
          'tables).',
        );
      }
    }
    return zigzag;
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _nestedIntListsEqual(List<List<int>> a, List<List<int>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }
}

class _CopyFailure implements Exception {
  const _CopyFailure(this.message);

  final String message;
}
