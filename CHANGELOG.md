# Changelog

All notable changes to Insta360 Print (mobile). The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/).

## [1.0.0] — 2026-11-01

First public release. Android 9+ (minSdk 28).

### Added

- Recent-photos gallery over `photo_manager`: newest first, paged, with
  Android 13/14 photo permissions (including "Select photos" partial access),
  a re-ask button when permission is missing, and a settings escape hatch.
- Responsive photo grid for phones and tablets, portrait and landscape, using
  one max-extent grid delegate.
- USB host discovery of Insta360 cameras, per-device USB permission, and a
  bottom-sheet picker. Cameras are classified by VID/PID.
- Persisted SAF (`ACTION_OPEN_DOCUMENT_TREE`) grant for the camera drive, stored
  per camera VID:PID and validated against `DCIM/fileinfo_list.list`.
- Camera-original rebuild on device: native `ImageDecoder` decode/orientation/
  fit, custom baseline 4:2:0 JPEG encoder using the camera's DQT, APP2 preview,
  EXIF thumbnail, and the raw Y+U,V gallery buffer the camera draws.
- Complete camera container: EXIF identity/name/date/dimensions, trailer fields
  7 and 9, file name and sequence, then a prepended record in both
  `DCIM/fileinfo_list.list` and `.editinfo_list.list` with read-back
  verification and rollback.
- Crop and Fit choices for non-4:3 sources.
- Branded adaptive launcher icon, generated from a single SVG.

### Verified

- On a vivo V2515 (Android 16) with an Insta360 GO Ultra over USB-C.
- The Python reference analyzer reports 8/8 camera fingerprints, correct field
  7/9 pointers, an index blob byte-identical to the trailer, and NV21↔preview
  mean RGB difference 1.9–2.1.
- The author confirmed the camera lists the copied photo first and displays it.
- 124 Dart tests, 10 Kotlin JVM tests, 2 on-device integration tests.

### Known limitations

- The copy always uses the camera's smallest 4:3 mode (4096×3072 on the tested
  GO Ultra); 16:9 and portrait sources are cropped or letterboxed rather than
  matched to a 16:9 camera mode.
- Android only; iOS is future work.
