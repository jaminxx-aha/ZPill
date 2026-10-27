/// Build-time brand metadata shared by the Flutter UI.
///
/// Native launch names and bundle identifiers are applied by
/// `tool/apply_brand.dart`. The same brand metadata is passed to Flutter with
/// `--dart-define` when a custom brand is built.
abstract final class AppBrand {
  static const id = String.fromEnvironment(
    'APP_BRAND_ID',
    defaultValue: 'zpill',
  );

  static const displayName = String.fromEnvironment(
    'APP_BRAND_NAME',
    defaultValue: 'ZPill',
  );

  static const description = String.fromEnvironment(
    'APP_BRAND_DESCRIPTION',
    defaultValue: 'Camera remote control and media transfer',
  );
}
