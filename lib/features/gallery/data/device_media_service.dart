import 'package:photo_manager/photo_manager.dart';

/// Thin, stateless wrapper around the gallery plugin.
///
/// Everything here is a direct platform call; caching, mapping and error
/// translation belong to the repository.
class DeviceMediaService {
  const DeviceMediaService();

  /// Ask for images only: the app never needs video or audio access.
  static const PermissionRequestOption _requestOption = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.image,
      mediaLocation: false,
    ),
  );

  /// Current state without prompting.
  Future<PermissionState> permissionState() =>
      PhotoManager.getPermissionState(requestOption: _requestOption);

  /// Prompts when the platform still allows a prompt.
  Future<PermissionState> requestPermission() =>
      PhotoManager.requestPermissionExtend(requestOption: _requestOption);

  Future<void> openSettings() => PhotoManager.openSetting();

  Future<void> presentLimitedSelection() =>
      PhotoManager.presentLimited(type: RequestType.image);

  /// The synthetic "all photos" album, newest first, or null when the library
  /// is empty/inaccessible.
  Future<AssetPathEntity?> recentPhotosPath() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: const <OrderOption>[
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    return paths.isEmpty ? null : paths.first;
  }

  Future<int> assetCount(AssetPathEntity path) => path.assetCountAsync;

  Future<List<AssetEntity>> assets(
    AssetPathEntity path, {
    required int offset,
    required int limit,
  }) {
    return path.getAssetListRange(start: offset, end: offset + limit);
  }
}
