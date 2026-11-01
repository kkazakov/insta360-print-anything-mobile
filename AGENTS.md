# AGENTS.md

## Project Overview

`insta360-print-anything-mobile` is the Android-first Flutter front end for
[`insta360-print-anything`](https://github.com/kkazakov/insta360-print-anything):
it lists the phone's recent photos, lets the user pick one, and copies it onto a USB-connected
Insta360 camera as a file the camera itself lists.

Both stages are implemented and released as **1.0.0**: the gallery/permissions/
USB discovery UI (stage 1) and the camera-original rebuild + SAF write + index
update (stage 2). The interactive crop editor is post-1.0.0 work in this
checkout, pending the next release. The whole pipeline was run against the real GO Ultra on
2026-11-01, the Python analyzer reports 8/8 fingerprints, and the author
confirmed the camera lists and displays the copied photo. Repository:
<https://github.com/kkazakov/insta360-print-anything-mobile>.

Canary: this project is `insta360-print-anything-mobile` (hyphens; Flutter
package `insta360_print_anything_mobile`, application id
`com.wasp.insta360_print_anything_mobile`).

## Commands

```bash
flutter pub get
flutter analyze                      # must stay at zero issues
flutter test                         # 135 with .dev-samples; 26 skip on a clean clone
JAVA_HOME=/usr/lib/jvm/java-21-openjdk flutter build apk --debug
JAVA_HOME=/usr/lib/jvm/java-21-openjdk flutter build apk --release
JAVA_HOME=/usr/lib/jvm/java-21-openjdk flutter build appbundle --release
JAVA_HOME=/usr/lib/jvm/java-21-openjdk flutter run

# native encoder (pure Kotlin, JVM tests, no device):
cd android && JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
  ./gradlew :app:testDebugUnitTest --tests 'com.wasp.insta360_print_anything_mobile.camera.*'

# on-device pixel pipeline (needs photo access; writes to the app cache):
JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
  flutter test integration_test/native_pipeline_test.dart -d 192.168.88.10:44045

adb devices
adb -s 192.168.88.10:44045 install -r build/app/outputs/flutter-apk/app-debug.apk
```

Gradle 9.3.1 cannot run on the machine-default JDK 27 (`Unsupported class file
major version 71`); always pass JDK 21 for Android builds. Unit-test compilation
also needs `compilerOptions.noJdk.set(false)` (already in `android/app/build.gradle.kts`)
so ImageIO resolves.

## Architecture

Layers, inner to outer: domain → data → presentation. Presentation talks to
repositories only through domain interfaces; `main.dart` wires the real
implementations.

```
lib/features/gallery/{domain,data,presentation}
lib/features/cameras/{domain,data,presentation}     USB + SAF camera access
lib/features/copy/domain/                           CopyEngine, CopyRequest, pipeline contracts
lib/features/copy/data/                             CameraCopyEngine, CameraImageService
lib/features/copy/format/                           jpeg, exif, meta, template (pure Dart)
lib/features/copy/presentation/                     CopyReviewPage, CropEditorPage
lib/features/copy/presentation/widgets/             CropPreview
lib/core/{theme,ui}
android/.../{MainActivity,UsbCameraChannel,CameraStorageChannel,CameraImageChannel}.kt
android/.../camera/{CameraJpegEncoder,CameraNv21,CameraImagePipeline}.kt
lib/features/copy/domain/crop_window.dart            normalized 4:3 crop window
android/app/src/test/kotlin/.../camera/             encoder + NV21 JVM tests
test/support/fakes.dart                             fake repos/storage/pipeline
```

- `GalleryRepository` (photos, permission, thumbnails, original path) — photo_manager.
- `CameraRepository` (USB list + per-device permission) — USB channel.
- `CameraStorageRepository` (SAF grant/list/read/write) — storage channel.
- `CameraImagePipeline` (decode/fit/encode main+preview+thumb, NV21) — image channel;
  accepts a normalized `CropWindow` for `CopyFit.crop`.
- `CameraCopyEngine` orchestrates template → build → verify → write → index.
- `CopyEngine` also exposes optional progress updates (`CopyProgress`).
- `lib/core/debug/demo_camera.dart` adds a compile-time demo camera
  (`--dart-define=INSTA360_DEMO_CAMERA=true`) for exercising SAF/copy without
  hardware. Normal builds default false; do not enable it in release builds.

State: `ChangeNotifier` view models with immutable-ish getters, consumed via
`ListenableBuilder`. No provider/riverpod/bloc — do not add a state-management
package.

## Copy invariants

These are the things that make the file accepted as a camera original:

- The template always comes from a photo on the **connected camera**, never from
  bundled samples. It supplies EXIF, DQT, APP2 preview size, EXIF thumbnail size,
  model/serial/UID and the trailer.
- The engine picks the **smallest** camera mode among the newest usable photos
  (12.6 MP / 4096×3072 on the tested GO Ultra) for speed and memory.
- Output marker order is `SOI → APP1(Exif) → APP2×N → DQT → SOF0 → DHT → SOS …
  EOI → trailer`. No APP0 and, deliberately, no DRI/RST markers.
- DQT is one segment with both 8-bit tables in the template's order; DHT is one
  segment with the four standard Annex K tables (416-byte payload); 4:2:0 with
  sampling `0x22/0x11/0x11`.
- `CameraTemplate.qtables` is in **natural** order; the native encoder takes
  **zigzag** order, so `CameraCopyEngine._naturalToZigzag` converts before the
  call. Never pass natural-order values to the encoder.
- EXIF is patched in place: ImageDescription, DateTime, DateTimeOriginal,
  DateTimeDigitized, PixelX/YDimension, and the thumbnail when it sits at the end
  of the TIFF block. Everything else (MakerNote, ABMA, calibration strings) is
  preserved byte-for-byte.
- Trailer: replace the 27-char name after `/DCIM/Camera01/`; overwrite the raw
  gallery buffer; set field 7 to `YYYYMMDDHHMMSS`; set field 9 to
  `body.length + blobOffset` (431 on the tested samples).
- The raw gallery buffer is **Y plane then interleaved U,V** (video-range BT.601).
  The camera draws this, not the JPEG. Do not "fix" it to V,U.
- Index records are **prepended**, not appended. The `fileinfo_list.list` blob is
  exactly the 1151-byte metadata blob from the trailer. The edit index record for
  new files is `12 00` (0-byte blob), like the reference tool — the camera's own
  JPEG records carry a 2-byte blob, but accepts the empty one.
- A custom crop is a normalized [CropWindow] in oriented source coordinates. The
  editor returns the exact 4:3 window; the native decoder adjusts a mismatched
  aspect defensively, decodes at the crop's needed scale, and caps the ARGB
  working set at 20 MP. Never crop after the encode.
- The copy date is `max(now, newest camera photo + 1 min)`, second precision.
  File name is `IMG_YYYYMMDD_HHMMSS_NNN.jpg`, exactly 27 chars; `_NNN` is the
  next unused number that day.
- Write, then re-read and verify both index files; on any failure restore both
  index buffers and delete the new JPEG.

## Conventions

- `flutter analyze` must stay at zero issues; run `dart format` first.
- `lib/features/copy/format/` is **pure Dart** (`dart:typed_data`, no Flutter
  imports, no image packages) and is the byte-level port of the Python modules.
  Changes there must keep parity with `../insta360-print-anything/insta360_print/`
  (public: <https://github.com/kkazakov/insta360-print-anything>).
- `CameraJpegEncoder`/`CameraNv21` are pure Kotlin (no Android imports) so the
  JVM tests can decode with `javax.imageio`. `CameraImagePipeline` is the only
  Android-pixel class.
- Every native encoder change needs a JVM test (marker layout, DQT bytes,
  ImageIO round-trip, odd sizes).
- Every format change needs a sample-backed test in
  `test/features/copy/format/`; `.dev-samples/` is gitignored and tests skip
  cleanly when it is absent.
- Copy-engine tests use `FakeCameraStorage` + a fake `CameraImagePipeline`; the
  real encoder is exercised by the Kotlin tests and on-device.
- New tests go next to the feature; use `test/support/fakes.dart`, never a real
  plugin. Widget tests must end with no pending timers.
- Keep user-facing copy in English.
- Versioning: bump `version:` in `pubspec.yaml`, add a `CHANGELOG.md` entry,
  then tag `vX.Y.Z` and attach the signed APK/AAB plus `SHA256SUMS` to the GitHub
  release. `versionCode` must increase for every public release.
- Release signing uses `android/key.properties` (gitignored) pointing at a
  keystore outside the repo. Never commit either. The official 1.0.0 certificate
  is `CN=Krasimir Kazakov` with SHA-256
  `D8:45:6B:04:0A:64:06:31:61:58:F2:00:1A:33:BA:91:AA:66:BF:64:7D:87:AA:E7:60:B1:3F:4D:F2:B0:96:54`;
  future releases must keep the same key.
- Launcher icons are generated, not hand-edited: change
  `tool/icon/app_icon.svg` and run `python3 tool/icon/generate_icons.py`
  (Pillow + CairoSVG) to regenerate the mipmaps, round icons, adaptive
  foregrounds and `tool/icon/app_icon-512.png`. Do not edit the PNGs in
  `android/app/src/main/res/mipmap-*` directly.

## Boundaries

- Do not add `permission_handler`, an image-processing plugin, or a
  state-management package. Photo permission belongs to photo_manager; pixel work
  is native; the format core is hand-rolled.
- Do not remove the custom DQT/APP1-first/4:2:0 layout or add APP0 to make another
  output look simpler. The whole point is structural fidelity.
- Do not re-enable the `DRI` marker without emitting matching `RSTn` markers; the
  reference drops it on purpose.
- Do not swap the trailer chroma order to V,U "because it says NV21". It is U,V.
- Do not write to the camera without a persisted SAF grant; never fall back to
  arbitrary paths or `MANAGE_EXTERNAL_STORAGE`.
- Do not commit personal media. The only images in the repo are the curated,
  status-bar-cropped app screenshots under `docs/screenshots/` (safe sunset-only
  set). Keep `.dev-samples/`, APKs, `build/` and any user photos out.
- Do not write the camera index from a template that was not read from this
  camera body.

## Gotchas

- The GO Ultra volume is auto-mounted (vivo V2515: `/storage/4A21-0000`, exFAT,
  SAF label "disk"). One persisted `ACTION_OPEN_DOCUMENT_TREE` grant for the
  drive root is enough. The picker's `EXTRA_INITIAL_URI` hint is ignored by this
  device's DocumentsUI; the user must choose "disk" from the drawer.
- SAF has no atomic replace. The JPEG is written with `openOutputStream(uri,
  "wt")`, parent folders are created on demand, and size is verified by querying
  the document. The index rollback re-writes the previous buffers.
- A remembered grant is keyed by camera VID:PID and only accepted if
  `DCIM/fileinfo_list.list` is still visible. Swapping bodies or reformatting the
  card invalidates it; the review screen re-prompts.
- `minSdk = 28` because `ImageDecoder` is used for decode + target-size
  downscale (and HEIC support). `largeHeap` is on because a 37 MP encode uses
  large ARGB buffers.
- `ImageDecoder` applies EXIF orientation; verify that `ImageInfo.size` matches
  the oriented bitmap on a portrait source before trusting the fit math.
- Native prepare returns the main/preview/thumbnail JPEGs and the NV21 buffer in
  one channel call. Do not move the huge ARGB arrays across the channel.
- `CameraStorage` paths are relative to the granted tree
  (`DCIM/Camera01/IMG_….jpg`); the index record path needs a leading `/`.
- Do not assume `.editinfo_list.list` exists; create it when missing.
- Photo permission can be revoked in the background: the repository throws
  `GalleryAccessException` rather than pretending the library is empty.
- `AssetEntityImageProvider` must use `isOriginal: false` with a thumbnail size;
  the default decodes the full original.
- Screenshots: use only a user-prepared gallery screen with safe photos, never
  scroll past it, and crop the status bar before saving. The current set is
  `docs/screenshots/overview.jpg` plus the numbered PNGs; regenerate the montage
  from `01-gallery`, `04-crop-editor`, `07-copy-success`.
- The device is paired over wireless adb at `192.168.88.10:44045`; it drops when
  the phone sleeps or the camera is unplugged. The normal debug build is
  installed. On 2026-11-01 the GO Ultra was attached, the persisted "disk" grant
  was reused, and the first real copy landed in `DCIM/Camera01` with both indexes
  updated; the camera was still attached at the end of the run.
- `run-as` is broken on the vivo ROM (`packagelist_parse failed`), so the
  integration test's cached outputs cannot be pulled that way; its assertions
  are the verification.

## Release process

1. Set `version:` in `pubspec.yaml` (bump the build number too).
2. Add a `CHANGELOG.md` section.
3. `flutter analyze && flutter test` and the Kotlin tests.
4. Build `app-release.apk` + `app-release.aab` with `android/key.properties`
   present; verify with `apksigner verify --print-certs` and check
   `aapt2 dump badging` shows the new `versionName`.
5. Commit, tag `vX.Y.Z`, push, then create the GitHub release with the renamed
   `insta360-print-X.Y.Z.apk`, the AAB and `SHA256SUMS`.

## Future work

- Portrait/16:9 sources use the smallest 4:3 camera mode; the crop editor makes
  the kept window explicit, but matching the source aspect to a 37 MP 16:9 mode
  is still future work.
- Open the folder picker at the USB drive (`EXTRA_INITIAL_URI` is ignored on the
  tested vivo) and remember the grant per physical body rather than per VID:PID.
- iOS transport; the format/domain layers are platform-independent Dart.

Historical note: a simulated-folder run on 2026-11-01 (no camera attached)
verified SAF grant, native encode, write, both index updates and read-back with
8/8 Python fingerprints and NV21↔preview mean RGB difference 1.9–2.1. The real
GO Ultra run superseded it.
