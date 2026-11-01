/// The app's level of access to the device photo library.
///
/// Mirrors the platform permission states but keeps the presentation layer
/// independent of the gallery plugin.
enum GalleryAccess {
  /// Not asked yet, or the platform could not tell.
  unknown,

  /// Full read access to photos.
  granted,

  /// Partial access (iOS "Limited", Android 14 "Select photos").
  limited,

  /// The user declined.
  denied,

  /// Blocked by parental controls, device policy, or the platform.
  restricted;

  /// Whether the app may list photos with this level of access.
  bool get canBrowse =>
      this == GalleryAccess.granted || this == GalleryAccess.limited;

  /// Whether the user only exposed a subset of the library.
  bool get isLimited => this == GalleryAccess.limited;

  /// Whether a permission prompt can still change the outcome.
  ///
  /// A restricted state cannot be granted from inside the app; the user has to
  /// change it in the system settings.
  bool get needsSettings => this == GalleryAccess.restricted;
}
