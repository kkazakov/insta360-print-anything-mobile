import 'package:flutter/foundation.dart';

import 'photo_asset.dart';

/// One page of photos plus the total number in the library.
@immutable
class PhotoPage {
  const PhotoPage({required this.photos, required this.totalCount});

  final List<PhotoAsset> photos;

  /// Total number of images the app is allowed to see, not the page size.
  final int totalCount;
}
