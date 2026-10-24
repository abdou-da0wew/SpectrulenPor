import 'dart:typed_data';

/// Web stub — ML Kit is Android/iOS-only; the vision cascade treats a null
/// result as "tier unavailable" and falls through gracefully.
class MlKitAnalyzer {
  Future<void> init() async {}

  /// Always null on web.
  Future<String?> describe(Uint8List jpegBytes, {required bool isAr}) async =>
      null;

  void dispose() {}
}
