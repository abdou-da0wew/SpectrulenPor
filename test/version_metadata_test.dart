import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('checked-in version asset contains package version only', () {
    final metadata = jsonDecode(
      File('assets/version.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    expect(metadata['version'], '5.5.1');
    expect(metadata['versionCode'], 16);
    expect(metadata.keys, isNot(contains('gitSha')));
    expect(metadata.keys, isNot(contains('gitShaFull')));
    expect(metadata.keys, isNot(contains('gitBranch')));
    expect(metadata.keys, isNot(contains('gitDirty')));
    expect(metadata.keys, isNot(contains('buildDate')));
  });

  test('metadata-aware Flutter wrapper injects live source metadata', () {
    final wrapper = File('tooling/flutter_with_metadata.sh').readAsStringSync();

    expect(wrapper, contains('git rev-parse --short=7 HEAD'));
    expect(wrapper, contains('git rev-parse HEAD'));
    expect(wrapper, contains('git symbolic-ref'));
    expect(wrapper, contains('git status --porcelain'));
    expect(wrapper, contains('--dart-define="GIT_SHA='));
    expect(wrapper, contains('--dart-define="GIT_SHA_FULL='));
    expect(wrapper, contains('--dart-define="GIT_BRANCH='));
    expect(wrapper, contains('--dart-define="GIT_DIRTY='));
    expect(wrapper, contains('--dart-define="BUILD_DATE='));
  });
}
