import 'package:flutter/foundation.dart';

import 'copy_request.dart';

/// Stages reported while a copy is running, for the progress line.
enum CopyPhase { readingCamera, rebuilding, writing, indexing, verifying }

/// One progress update from the copy engine.
@immutable
class CopyProgress {
  const CopyProgress(this.phase, this.message, {this.fraction});

  final CopyPhase phase;
  final String message;

  /// 0..1 when the phase can estimate its progress.
  final double? fraction;
}

/// Outcome of a copy attempt.
@immutable
class CopyResult {
  const CopyResult.success({this.message}) : success = true;

  const CopyResult.failure(this.message) : success = false;

  final bool success;

  /// Human-readable detail: what was written, or why it failed.
  final String? message;
}

/// Copies a phone photo onto a connected camera.
///
/// The implementation rebuilds the photo as a camera original (template
/// EXIF/DQT/trailer), writes it to the camera through the SAF grant and
/// registers it in the camera's index.
abstract interface class CopyEngine {
  /// Non-null when this build cannot copy at all, so the review screen can say
  /// so before the user presses the button.
  String? get unavailableReason;

  Future<CopyResult> copy(
    CopyRequest request, {
    void Function(CopyProgress progress)? onProgress,
  });
}
