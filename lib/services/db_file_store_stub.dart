import 'dart:typed_data';

/// Web / non-IO fallback store for [InternalDatabaseService].
class DbFileStore {
  final Map<String, String> _textFiles = {};
  final Map<String, Uint8List> _binaryFiles = {};

  String get basePath => 'memory://spectrulenpor_db';

  Future<void> init({String? overrideDir}) async {}

  Future<String?> readText(String relativeName) async =>
      _textFiles[relativeName];

  Future<void> writeText(String relativeName, String content) async {
    _textFiles[relativeName] = content;
  }

  Future<String> writeBinary(String relativeName, Uint8List bytes) async {
    final key = '$basePath/$relativeName';
    _binaryFiles[key] = Uint8List.fromList(bytes);
    return key;
  }

  Future<Uint8List?> readBinaryByPath(String path) async => _binaryFiles[path];

  Future<void> deleteByPath(String path) async {
    _binaryFiles.remove(path);
  }

  Future<int> sizeBytes(String relativeName) async =>
      (_textFiles[relativeName]?.length ?? 0);
}
