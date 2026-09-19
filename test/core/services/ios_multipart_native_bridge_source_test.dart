import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'iOS native bridge forwards multipart URLSession bytes to Dart',
    () async {
      final swift = await File('ios/Runner/DownloadNativeWaitingQueue.swift')
          .readAsString();
      final appDelegate = await File('ios/Runner/AppDelegate.swift')
          .readAsString();

      expect(swift, contains('postMultipartChunkUpdate('));
      expect(swift, contains('AnimeWitcherBackgroundDownloaderChunkUpdate'));
      expect(swift, contains('"writtenBytes"'));
      expect(swift, contains('"completed"'));
      expect(appDelegate, contains('arguments["writtenBytes"]'));
      expect(appDelegate, contains('arguments["completed"]'));
    },
  );

  }
