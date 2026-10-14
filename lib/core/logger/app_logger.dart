import 'package:talker_flutter/talker_flutter.dart';

import 'app_diagnostic_observers.dart';

/// Global Talker instance for logging across the app.
final talker = TalkerFlutter.init(
  observer: AppDiagnosticTalkerObserver(),
  // Keep provider and JavaScript plugin diagnostics available
  // in release builds.
  settings: TalkerSettings(enabled: true),
);
