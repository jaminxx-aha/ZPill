import 'dart:io';

const _largeFileThreshold = 2000;
const _budgetFile = 'tools/file_size_budget.txt';

const _frameworkExceptions = <String, Set<String>>{
  'lib/core/remote/frame_analyzer.dart': {
    'package:flutter/foundation.dart',
  },
  'lib/core/remote/intervalometer.dart': {
    'package:flutter/foundation.dart',
  },
  'lib/core/remote/live_view_engine.dart': {
    'package:flutter/foundation.dart',
  },
  'lib/core/media/image_edit.dart': {
    'dart:ui',
  },
  'lib/core/media/letterbox.dart': {
    'dart:ui',
  },
  'lib/core/media/watermark.dart': {
    'dart:ui',
    'package:flutter/painting.dart',
  },
};

const _platformContractExceptions = <String, Set<String>>{
  'lib/core/ble/ble_camera_session.dart': {
    'lib/platform/ble_scanner.dart',
  },
  'lib/core/browser/thumbnail_cache.dart': {
    'lib/platform/gallery_saver.dart',
    'lib/platform/raw_decoder.dart',
  },
  'lib/core/camera/camera_connection.dart': {
    'lib/platform/usb/usb_host.dart',
  },
  'lib/core/transfer/transfer_engine.dart': {
    'lib/platform/gallery_saver.dart',
  },
};

final _importDirective = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
);

void main() {
  final root = File.fromUri(Platform.script).absolute.parent.parent;
  final violations = <String>[];

  _checkCoreImports(root, violations);
  _checkFileBudgets(root, violations);

  if (violations.isNotEmpty) {
    stderr.writeln('architecture: FAILED');
    for (final violation in violations) {
      stderr.writeln('  - $violation');
    }
    exitCode = 1;
    return;
  }

  final frameworkEdges = _frameworkExceptions.values
      .fold(0, (sum, imports) => sum + imports.length);
  final contractEdges = _platformContractExceptions.values
      .fold(0, (sum, imports) => sum + imports.length);
  stdout.writeln(
    'architecture: OK '
    '($frameworkEdges framework exceptions, '
    '$contractEdges platform contracts, '
    '$_largeFileThreshold-line budget)',
  );
}

void _checkCoreImports(Directory root, List<String> violations) {
  final coreDirectory = Directory('${root.path}/lib/core');
  if (!coreDirectory.existsSync()) {
    violations.add('missing lib/core directory');
    return;
  }

  final files = coreDirectory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final source = _relative(root, file.path);
    final lines = file.readAsLinesSync();
    for (var index = 0; index < lines.length; index++) {
      final match = _importDirective.firstMatch(lines[index]);
      if (match == null) continue;
      final importUri = match.group(1)!;
      final line = index + 1;

      if (_isFrameworkImport(importUri)) {
        final allowed =
            _frameworkExceptions[source]?.contains(importUri) ?? false;
        if (!allowed) {
          violations.add(
            '$source:$line imports $importUri outside the framework allowlist',
          );
        }
        continue;
      }

      final target = _resolveImport(root, source, importUri);
      if (target == null) continue;

      if (_isForbiddenLayer(target)) {
        violations.add('$source:$line imports upward into $target');
      }

      if (target.startsWith('lib/platform/')) {
        final allowed =
            _platformContractExceptions[source]?.contains(target) ?? false;
        if (!allowed) {
          violations.add(
            '$source:$line imports unapproved platform target $target',
          );
        }
      }
    }
  }
}

void _checkFileBudgets(Directory root, List<String> violations) {
  final budgetFile = File('${root.path}/$_budgetFile');
  if (!budgetFile.existsSync()) {
    violations.add('missing $_budgetFile');
    return;
  }

  final budgets = <String, int>{};
  final budgetLines = budgetFile.readAsLinesSync();
  for (var index = 0; index < budgetLines.length; index++) {
    final raw = budgetLines[index].trim();
    if (raw.isEmpty || raw.startsWith('#')) continue;
    final parts = raw.split(RegExp(r'\s+'));
    if (parts.length != 2) {
      violations.add(
        '$_budgetFile:${index + 1} must be "<max-lines> <path>"',
      );
      continue;
    }
    final budget = int.tryParse(parts[0]);
    if (budget == null || budget < _largeFileThreshold) {
      violations.add(
        '$_budgetFile:${index + 1} has invalid budget "${parts[0]}"',
      );
      continue;
    }
    final path = parts[1];
    if (budgets.containsKey(path)) {
      violations.add('$_budgetFile:${index + 1} duplicates $path');
      continue;
    }
    if (!File('${root.path}/$path').existsSync()) {
      violations.add('$_budgetFile:${index + 1} references missing $path');
      continue;
    }
    budgets[path] = budget;
  }

  final dartFiles = <File>[];
  for (final directoryName in const ['lib', 'test']) {
    final directory = Directory('${root.path}/$directoryName');
    if (!directory.existsSync()) continue;
    dartFiles.addAll(
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    );
  }
  dartFiles.sort((a, b) => a.path.compareTo(b.path));

  for (final file in dartFiles) {
    final path = _relative(root, file.path);
    final lines = _lineCount(file);
    final budget = budgets[path];
    if (budget != null && lines > budget) {
      violations.add(
        '$path has $lines lines, over its $budget-line ceiling',
      );
    } else if (budget == null && lines >= _largeFileThreshold) {
      violations.add(
        '$path has $lines lines and needs an explicit size budget',
      );
    }
  }
}

bool _isFrameworkImport(String importUri) =>
    importUri.startsWith('package:flutter/') || importUri.startsWith('dart:ui');

bool _isForbiddenLayer(String path) {
  if (path.startsWith('lib/features/') ||
      path.startsWith('lib/data/') ||
      path.startsWith('lib/design/') ||
      path.startsWith('lib/debug/')) {
    return true;
  }
  return path == 'lib/app.dart' ||
      path == 'lib/app_services.dart' ||
      path.startsWith('lib/app_');
}

String? _resolveImport(Directory root, String source, String importUri) {
  const packagePrefix = 'package:nikon_pill/';
  if (importUri.startsWith(packagePrefix)) {
    return 'lib/${importUri.substring(packagePrefix.length)}';
  }
  if (importUri.contains(':')) return null;
  final target =
      File('${root.path}/$source').absolute.uri.resolve(importUri).toFilePath();
  return _relative(root, target);
}

String _relative(Directory root, String path) {
  final rootPath = root.absolute.path.endsWith(Platform.pathSeparator)
      ? root.absolute.path
      : '${root.absolute.path}${Platform.pathSeparator}';
  final absolute = File(path).absolute.path;
  return absolute.startsWith(rootPath)
      ? absolute.substring(rootPath.length)
      : absolute;
}

int _lineCount(File file) =>
    file.readAsBytesSync().where((byte) => byte == 0x0A).length;
