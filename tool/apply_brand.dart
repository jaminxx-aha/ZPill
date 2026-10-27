#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

const _officialBrandId = 'zpill';
const _officialAndroidId = 'com.jaminxx.zpill';
const _officialIosId = 'com.jaminxx.zpill';
const _officialOhosId = 'com.jaminxx.z_pill';

const _officialIds = [
  _officialAndroidId,
  _officialIosId,
  _officialOhosId,
];

Future<void> main(List<String> arguments) async {
  final root = _findRepositoryRoot();
  final configPath = _configPathFromArguments(arguments);
  final configFile = _resolvePath(root, configPath);
  final brand = BrandConfig.load(configFile);
  _validate(brand);

  _writeAndroidOverrides(root, brand);
  _writeIosOverrides(root, brand);
  final dartDefines = _writeDartDefines(root, brand);
  _applyOhosIdentity(root, brand);
  await _generateIcons(root, brand.icon);

  stdout
    ..writeln('Applied brand "${brand.displayName}" (${brand.id}).')
    ..writeln('  Android: ${brand.bundleId.android}')
    ..writeln('  iOS:     ${brand.bundleId.ios}')
    ..writeln('  OHOS:    ${brand.bundleId.ohos}')
    ..writeln();
  if (dartDefines != null) {
    stdout
      ..writeln('For Flutter UI metadata, pass:')
      ..writeln(
        '  --dart-define-from-file='
        'branding/local/generated/dart-defines.json',
      );
  }
}

String _configPathFromArguments(List<String> arguments) {
  var index = 0;
  while (index < arguments.length) {
    final argument = arguments[index];
    if (argument == '--config') {
      if (index + 1 >= arguments.length) {
        _fail('--config requires a YAML file path');
      }
      return arguments[index + 1];
    }
    if (argument.startsWith('--config=')) {
      return argument.substring('--config='.length);
    }
    if (argument == '--help' || argument == '-h') {
      stdout.writeln(
        'Usage: dart run tool/apply_brand.dart [--config path/to/brand.yaml]',
      );
      exit(0);
    }
    _fail('Unknown argument: $argument');
  }
  return 'branding/zpill/brand.yaml';
}

Directory _findRepositoryRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        File('${directory.path}/tool/apply_brand.dart').existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      _fail('Unable to locate the repository root');
    }
    directory = parent;
  }
}

File _resolvePath(Directory root, String path) {
  final file = File(path);
  return file.isAbsolute ? file : File('${root.path}/$path');
}

void _validate(BrandConfig brand) {
  final ids = [brand.bundleId.android, brand.bundleId.ios, brand.bundleId.ohos];
  if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(brand.id)) {
    _fail('Brand id must match [a-z0-9][a-z0-9_-]*');
  }
  for (final value in [brand.displayName, brand.description]) {
    if (value.trim().isEmpty || value.contains('\n') || value.contains('\r')) {
      _fail('Brand names and descriptions must be non-empty single lines');
    }
  }
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
      .hasMatch(brand.bundleId.android)) {
    _fail('Invalid Android application id: ${brand.bundleId.android}');
  }
  if (!RegExp(r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$')
      .hasMatch(brand.bundleId.ios)) {
    _fail('Invalid iOS bundle id: ${brand.bundleId.ios}');
  }
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
      .hasMatch(brand.bundleId.ohos)) {
    _fail('Invalid OHOS bundle name: ${brand.bundleId.ohos}');
  }

  if (brand.id == _officialBrandId) {
    if (brand.allowBundleIdOverride) {
      _fail('The official zpill profile must not allow identity overrides');
    }
    if (brand.bundleId.android != _officialAndroidId ||
        brand.bundleId.ios != _officialIosId ||
        brand.bundleId.ohos != _officialOhosId) {
      _fail('The official zpill profile must keep the official bundle ids');
    }
    return;
  }

  if (!brand.allowBundleIdOverride) {
    _fail('Custom brands must set allowBundleIdOverride: true');
  }
  if (ids.any(_officialIds.contains)) {
    _fail('Custom brands must not reuse an official zpill bundle id');
  }
}

void _writeAndroidOverrides(Directory root, BrandConfig brand) {
  final output = File('${root.path}/android/brand.local.properties');
  if (brand.id == _officialBrandId) {
    if (output.existsSync()) {
      output.deleteSync();
    }
    return;
  }
  output.writeAsStringSync(
    'brandId=${_propertiesValue(brand.id)}\n'
    'applicationId=${_propertiesValue(brand.bundleId.android)}\n'
    'appName=${_propertiesValue(brand.displayName)}\n',
  );
}

void _writeIosOverrides(Directory root, BrandConfig brand) {
  final output = File('${root.path}/ios/Flutter/Brand.local.xcconfig');
  if (brand.id == _officialBrandId) {
    if (output.existsSync()) {
      output.deleteSync();
    }
    return;
  }
  output.writeAsStringSync(
    'BRAND_BUNDLE_ID = ${brand.bundleId.ios}\n'
    'BRAND_DISPLAY_NAME = ${brand.displayName}\n'
    'BRAND_BUNDLE_NAME = ${brand.id}\n',
  );
}

File? _writeDartDefines(Directory root, BrandConfig brand) {
  final output = File(
    '${root.path}/branding/local/generated/dart-defines.json',
  );
  if (brand.id == _officialBrandId) {
    if (output.existsSync()) {
      output.deleteSync();
    }
    return null;
  }
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
          'APP_BRAND_ID': brand.id,
          'APP_BRAND_NAME': brand.displayName,
          'APP_BRAND_DESCRIPTION': brand.description,
        })}\n',
  );
  return output;
}

void _applyOhosIdentity(Directory root, BrandConfig brand) {
  final appConfig = File('${root.path}/ohos/AppScope/app.json5');
  var appSource = appConfig.readAsStringSync();
  appSource = _replaceJsonString(
    appSource,
    'bundleName',
    brand.bundleId.ohos,
    appConfig.path,
  );
  appConfig.writeAsStringSync(appSource);

  _setNamedString(
    File('${root.path}/ohos/AppScope/resources/base/element/string.json'),
    'app_name',
    brand.displayName,
  );
  for (final locale in const ['base', 'en_US', 'zh_CN']) {
    _setNamedString(
      File(
        '${root.path}/ohos/entry/src/main/resources/'
        '$locale/element/string.json',
      ),
      'EntryAbility_label',
      brand.displayName,
    );
  }
}

String _replaceJsonString(
  String source,
  String key,
  String value,
  String path,
) {
  final expression = RegExp(
    '"${RegExp.escape(key)}"\\s*:\\s*"[^"]*"',
  );
  if (!expression.hasMatch(source)) {
    _fail('Unable to find "$key" in $path');
  }
  return source.replaceFirst(
    expression,
    '"$key": ${jsonEncode(value)}',
  );
}

void _setNamedString(File file, String name, String value) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    _fail('Expected a JSON object in ${file.path}');
  }
  final entries = decoded['string'];
  if (entries is! List) {
    _fail('Expected a string array in ${file.path}');
  }
  var found = false;
  for (final entry in entries) {
    if (entry is Map && entry['name'] == name) {
      entry['value'] = value;
      found = true;
      break;
    }
  }
  if (!found) {
    _fail('Unable to find string "$name" in ${file.path}');
  }
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(decoded)}\n',
  );
}

Future<void> _generateIcons(Directory root, File icon) async {
  final result = await Process.run(
    'python3',
    ['${root.path}/tools/make_icons.py', icon.path],
    workingDirectory: root.path,
  );
  if (result.exitCode != 0) {
    stderr
      ..writeln(result.stdout)
      ..writeln(result.stderr);
    _fail('Icon generation failed');
  }
}

String _propertiesValue(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('\n', r'\n');

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(64);
}

final class BrandConfig {
  const BrandConfig({
    required this.id,
    required this.displayName,
    required this.description,
    required this.bundleId,
    required this.icon,
    required this.allowBundleIdOverride,
  });

  factory BrandConfig.load(File file) {
    if (!file.existsSync()) {
      _fail('Brand config not found: ${file.path}');
    }
    final source = loadYaml(file.readAsStringSync());
    if (source is! YamlMap) {
      _fail('Brand config must be a YAML map: ${file.path}');
    }
    final bundle = source['bundleId'];
    if (bundle is! YamlMap) {
      _fail('Missing bundleId map in ${file.path}');
    }
    final iconValue = _requiredString(source, 'icon', file.path);
    final iconFile = File.fromUri(file.parent.uri.resolve(iconValue));
    if (!iconFile.existsSync()) {
      _fail('Brand icon not found: ${iconFile.path}');
    }
    return BrandConfig(
      id: _requiredString(source, 'id', file.path),
      displayName: _requiredString(source, 'displayName', file.path),
      description: _requiredString(source, 'description', file.path),
      bundleId: BrandBundleIds(
        android: _requiredString(bundle, 'android', file.path),
        ios: _requiredString(bundle, 'ios', file.path),
        ohos: _requiredString(bundle, 'ohos', file.path),
      ),
      icon: iconFile.absolute,
      allowBundleIdOverride: source['allowBundleIdOverride'] as bool? ?? false,
    );
  }

  final String id;
  final String displayName;
  final String description;
  final BrandBundleIds bundleId;
  final File icon;
  final bool allowBundleIdOverride;
}

final class BrandBundleIds {
  const BrandBundleIds({
    required this.android,
    required this.ios,
    required this.ohos,
  });

  final String android;
  final String ios;
  final String ohos;
}

String _requiredString(YamlMap map, String key, String path) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    _fail('Missing non-empty "$key" in $path');
  }
  return value.trim();
}
