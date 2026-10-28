import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path_provider/path_provider.dart';

/// Disk store for [InternalDatabaseService] frame blobs and non-Android JSON
/// fallback persistence.
class DbFileStore {
  Directory? _dir;

  String get basePath => _dir?.path ?? '';

  Future<void> init({String? overrideDir}) async {
    if (overrideDir != null && overrideDir.isNotEmpty) {
      final d = Directory(overrideDir);
      if (!d.existsSync()) d.createSync(recursive: true);
      _dir = d;
      return;
    }
    if (_dir != null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final sub = Directory('${docs.path}/spectrulenpor_db');
      if (!sub.existsSync()) sub.createSync(recursive: true);
      _dir = sub;
    } on MissingPluginException {
      final fallback =
          Directory('${Directory.systemTemp.path}/spectrulenpor_db_test');
      if (!fallback.existsSync()) fallback.createSync(recursive: true);
      _dir = fallback;
    } catch (_) {
      final fallback =
          Directory('${Directory.systemTemp.path}/spectrulenpor_db_fallback');
      if (!fallback.existsSync()) fallback.createSync(recursive: true);
      _dir = fallback;
    }
  }

  Future<String?> readText(String relativeName) async {
    await init();
    final f = File('${_dir!.path}/$relativeName');
    if (!f.existsSync()) return null;
    try {
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> writeText(String relativeName, String content) async {
    await init();
    final target = File('${_dir!.path}/$relativeName');
    if (!target.parent.existsSync()) {
      target.parent.createSync(recursive: true);
    }
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (target.existsSync()) {
      try {
        await target.delete();
      } catch (_) {}
    }
    await tmp.rename(target.path);
  }

  Future<String> writeBinary(String relativeName, Uint8List bytes) async {
    await init();
    final target = File('${_dir!.path}/$relativeName');
    if (!target.parent.existsSync()) {
      target.parent.createSync(recursive: true);
    }
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  Future<Uint8List?> readBinaryByPath(String path) async {
    if (path.isEmpty) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteByPath(String path) async {
    if (path.isEmpty) return;
    final f = File(path);
    if (f.existsSync()) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  Future<int> sizeBytes(String relativeName) async {
    await init();
    final f = File('${_dir!.path}/$relativeName');
    return f.existsSync() ? f.lengthSync() : 0;
  }
}
