import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Shared storage folder for both application and Download V2 diagnostics.
/// Individual log files remain separate inside this directory.
Future<Directory> applicationLogDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory(p.join(documents.path, 'log'));
}
