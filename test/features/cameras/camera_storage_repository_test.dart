import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta360_print_anything_mobile/features/cameras/data/camera_storage_service.dart';
import 'package:insta360_print_anything_mobile/features/cameras/data/saf_camera_storage_repository.dart';
import 'package:insta360_print_anything_mobile/features/cameras/domain/camera_storage.dart';

import '../../support/fakes.dart';

class _FakeStorageService implements CameraStorageService {
  String? remembered;
  String? pickResult;
  Map<Object?, Object?> info = <Object?, Object?>{
    'label': 'disk',
    'writable': true,
  };
  Set<String> files = <String>{CameraStoragePaths.index};

  int rememberCalls = 0;
  bool forgot = false;
  String? lastInitialUri;

  @override
  Future<String?> pickTree({String? initialUri}) async {
    lastInitialUri = initialUri;
    return pickResult;
  }

  @override
  Future<String?> rememberedTree(String cameraKey) async => remembered;

  @override
  Future<bool> rememberTree(String cameraKey, String treeUri) async {
    rememberCalls++;
    remembered = treeUri;
    return true;
  }

  @override
  Future<void> forgetTree(String cameraKey) async {
    forgot = true;
    remembered = null;
  }

  @override
  Future<Map<Object?, Object?>> treeInfo(String treeUri) async => info;

  @override
  Future<List<Map<Object?, Object?>>> list(
    String treeUri,
    String relativeDir,
  ) async => const <Map<Object?, Object?>>[];

  @override
  Future<Uint8List?> read(String treeUri, String relativePath) async => null;

  @override
  Future<void> write(
    String treeUri,
    String relativePath,
    Uint8List bytes,
  ) async {
    files.add(relativePath);
  }

  @override
  Future<void> delete(String treeUri, String relativePath) async {
    files.remove(relativePath);
  }

  @override
  Future<bool> exists(String treeUri, String relativePath) async =>
      files.contains(relativePath);
}

void main() {
  test('a valid camera folder is remembered and returned', () async {
    final service = _FakeStorageService()
      ..pickResult =
          'content://com.android.externalstorage.documents/tree/4A21-0000%3A';
    final repository = SafCameraStorageRepository(service: service);

    final storage = await repository.requestStorageFor(makeCamera());

    expect(storage, isNotNull);
    expect(storage!.label, 'disk');
    expect(storage.treeUri, service.pickResult);
    expect(service.rememberCalls, 1);
    expect(service.forgot, isFalse);
  });

  test('cancelling the picker returns null and remembers nothing', () async {
    final service = _FakeStorageService();
    final repository = SafCameraStorageRepository(service: service);

    final storage = await repository.requestStorageFor(makeCamera());

    expect(storage, isNull);
    expect(service.rememberCalls, 0);
  });

  test('a folder without the camera index is rejected and forgotten', () async {
    final service = _FakeStorageService()
      ..pickResult = 'content://tree/phone'
      ..files = <String>{};
    final repository = SafCameraStorageRepository(service: service);

    await expectLater(
      repository.requestStorageFor(makeCamera()),
      throwsA(
        isA<CameraStorageException>().having(
          (error) => error.code,
          'code',
          'not_camera',
        ),
      ),
    );
    expect(service.forgot, isTrue);
  });

  test('a read-only grant is rejected', () async {
    final service = _FakeStorageService()
      ..pickResult = 'content://tree/disk'
      ..info = <Object?, Object?>{'label': 'disk', 'writable': false};
    final repository = SafCameraStorageRepository(service: service);

    await expectLater(
      repository.requestStorageFor(makeCamera()),
      throwsA(
        isA<CameraStorageException>().having(
          (error) => error.code,
          'code',
          'read_only',
        ),
      ),
    );
    expect(service.forgot, isTrue);
  });

  test(
    'a remembered grant is reused when the index is still visible',
    () async {
      final service = _FakeStorageService()
        ..remembered = 'content://tree/disk'
        ..info = <Object?, Object?>{'label': 'disk', 'writable': true};
      final repository = SafCameraStorageRepository(service: service);

      final storage = await repository.grantedStorageFor(makeCamera());

      expect(storage, isNotNull);
      expect(storage!.label, 'disk');
    },
  );

  test('a remembered grant pointing at a different drive is ignored', () async {
    final service = _FakeStorageService()
      ..remembered = 'content://tree/old'
      ..files = <String>{};
    final repository = SafCameraStorageRepository(service: service);

    final storage = await repository.grantedStorageFor(makeCamera());

    expect(storage, isNull);
  });

  test('the previous grant is offered as the picker starting point', () async {
    final service = _FakeStorageService()
      ..remembered = 'content://tree/disk'
      ..pickResult = 'content://tree/disk';
    final repository = SafCameraStorageRepository(service: service);

    await repository.requestStorageFor(makeCamera());

    expect(service.lastInitialUri, 'content://tree/disk');
  });
}
