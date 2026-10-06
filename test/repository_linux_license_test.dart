import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('repository is licensed as GPL-3.0-only', () {
    final license = File('LICENSE');
    expect(license.existsSync(), isTrue);

    final text = license.readAsStringSync();
    expect(text, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(text, contains('Version 3, 29 June 2007'));

    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('[GPL-3.0-only](LICENSE)'));
  });

  test('Linux desktop scaffold uses AnimeWitcher identity', () {
    final cmake = File('linux/CMakeLists.txt');
    final runner = File('linux/runner/my_application.cc');

    expect(cmake.existsSync(), isTrue);
    expect(runner.existsSync(), isTrue);

    final cmakeText = cmake.readAsStringSync();
    expect(cmakeText, contains('set(BINARY_NAME "animewitcher")'));
    expect(cmakeText, contains('set(APPLICATION_ID "com.animewitcher.app")'));

    final runnerText = runner.readAsStringSync();
    expect(runnerText, contains('"AnimeWitcher"'));
  });

  test('release and preview workflows build Linux packages', () {
    final release = File('.github/workflows/release.yml').readAsStringSync();
    final preview = File('.github/workflows/preview.yml').readAsStringSync();

    for (final workflow in <String>[release, preview]) {
      expect(workflow, contains('build_linux:'));
      expect(workflow, contains('  linux:'));
      expect(workflow, contains('flutter build linux --release'));
      expect(workflow, contains(r'animewitcher-linux-${{ matrix.arch }}'));
      expect(workflow, contains('.deb'));
      expect(workflow, contains('.tar.gz'));
    }

    expect(
      release,
      contains(
        'needs: [version, create_release, android, ios, macos, windows, linux]',
      ),
    );
  });

  test('README advertises Linux and AnimeWitcher website', () {
    final readme = File('README.md').readAsStringSync();

    expect(readme, contains('**لينكس**'));
    expect(readme, contains('https://animewitcher.com'));
    expect(readme, isNot(contains('skystream.site')));
  });
}
