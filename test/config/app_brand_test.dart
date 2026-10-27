import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';
import 'package:z_pill/config/app_brand.dart';

void main() {
  test('默认构建身份与 ZPill 配置一致', () {
    final config = loadYaml(
      File('branding/zpill/brand.yaml').readAsStringSync(),
    ) as YamlMap;
    final bundleIds = config['bundleId'] as YamlMap;

    expect(AppBrand.id, 'zpill');
    expect(AppBrand.displayName, 'ZPill');
    expect(AppBrand.description, isNotEmpty);
    expect(config['id'], AppBrand.id);
    expect(config['displayName'], AppBrand.displayName);
    expect(bundleIds['android'], 'com.jaminxx.zpill');
    expect(bundleIds['ios'], 'com.jaminxx.zpill');
    expect(bundleIds['ohos'], 'com.jaminxx.z_pill');
  });
}
