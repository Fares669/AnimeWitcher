from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one replacement, found {count}: {old[:80]!r}")
    file.write_text(text.replace(old, new, 1))


logger = r'''import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'anime4k.dart';
import 'anime4k_performance.dart';

typedef Anime4kDocumentsDirectoryResolver = Future<Directory> Function();
typedef Anime4kDeviceInfoResolver = Future<Map<String, Object?>> Function();
typedef Anime4kClock = DateTime Function();

/// Device-local JSONL benchmark log for the Apple Anime4K performance work.
///
/// Nothing is uploaded. A new `anime4k-*` file is created under Documents/log
/// for each service lifetime so a physical-device preview run can be inspected
/// from the settings UI and attached to benchmark evidence later.
class Anime4kPerformanceLog {
  Anime4kPerformanceLog({
    Anime4kDocumentsDirectoryResolver? documentsDirectory,
    Anime4kDeviceInfoResolver? deviceInfo,
    Anime4kClock? now,
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _deviceInfo = deviceInfo ?? _readDeviceInfo,
       _now = now ?? DateTime.now;

  final Anime4kDocumentsDirectoryResolver _documentsDirectory;
  final Anime4kDeviceInfoResolver _deviceInfo;
  final Anime4kClock _now;

  Future<File>? _sessionFile;
  Future<void> _writeTail = Future<void>.value();

  Future<void> recordRoute({
    required Anime4kBackend backend,
    required Anime4kMode mode,
    required Anime4kQuality requestedQuality,
    required bool ecoEnabled,
    required bool metalFxExperiment,
    String? colorSignal,
    String? reason,
  }) {
    return _append(<String, Object?>{
      'type': 'route',
      'backend': backend.name,
      'mode': mode.name,
      'requestedQuality': requestedQuality.name,
      'ecoEnabled': ecoEnabled,
      'colorSignal': colorSignal,
      'reason': reason,
      'metalFxExperiment': metalFxExperiment,
    });
  }

  Future<void> recordSnapshot(
    Anime4kPerformanceSnapshot snapshot, {
    required bool metalFxExperiment,
  }) {
    return _append(<String, Object?>{
      'type': 'snapshot',
      'backend': snapshot.backend.name,
      'requestedMode': snapshot.requestedMode.name,
      'requestedQuality': snapshot.requestedQuality.name,
      'effectiveQuality': snapshot.effectiveQuality.name,
      'inputWidth': snapshot.inputWidth,
      'inputHeight': snapshot.inputHeight,
      'processingWidth': snapshot.processingWidth,
      'processingHeight': snapshot.processingHeight,
      'averageFrameTimeMs': snapshot.averageFrameTimeMs,
      'p95FrameTimeMs': snapshot.p95FrameTimeMs,
      'processedFrames': snapshot.processedFrames,
      'skippedDuplicateFrames': snapshot.skippedDuplicateFrames,
      'droppedOrLateFrames': snapshot.droppedOrLateFrames,
      'thermalLevel': snapshot.thermalLevel.name,
      'lowPowerMode': snapshot.lowPowerMode,
      'metalFxExperiment': metalFxExperiment,
    });
  }

  /// Returns the newest Anime4K log, including logs from a previous app run.
  Future<File?> latestLogFile() async {
    final root = await _documentsDirectory();
    final directory = Directory(p.join(root.path, 'log'));
    if (!await directory.exists()) return null;

    final files = await directory
        .list(followLinks: false)
        .where((entity) {
          return entity is File &&
              p.basename(entity.path).startsWith('anime4k-') &&
              p.extension(entity.path) == '.log';
        })
        .cast<File>()
        .toList();
    if (files.isEmpty) return null;
    files.sort((a, b) => b.path.compareTo(a.path));
    return files.first;
  }

  Future<String?> latestLogPath() async => (await latestLogFile())?.path;

  /// Reads only the tail so a long playback session cannot make the settings
  /// dialog allocate an unbounded string.
  Future<String?> readLatest({int maxBytes = 256 * 1024}) async {
    final file = await latestLogFile();
    if (file == null) return null;
    final length = await file.length();
    final start = length > maxBytes ? length - maxBytes : 0;
    final bytes = await file.openRead(start).fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, data) => builder..add(data),
    );
    final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    return start == 0 ? text : '[... earlier Anime4K log omitted ...]\n$text';
  }

  Future<void> _append(Map<String, Object?> event) {
    final next = _appendAfter(_writeTail, event);
    _writeTail = next;
    return next;
  }

  Future<void> _appendAfter(
    Future<void> previous,
    Map<String, Object?> event,
  ) async {
    try {
      await previous;
    } catch (_) {
      // A logging failure must never poison the next sample or playback.
    }

    try {
      final file = await _ensureSessionFile();
      final entry = <String, Object?>{
        'timestamp': _now().toUtc().toIso8601String(),
        ...event,
      };
      await file.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Anime4K performance log write skipped: $error');
      }
    }
  }

  Future<File> _ensureSessionFile() {
    return _sessionFile ??= _createSessionFile();
  }

  Future<File> _createSessionFile() async {
    final root = await _documentsDirectory();
    final directory = Directory(p.join(root.path, 'log'));
    await directory.create(recursive: true);
    final stamp = _now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(p.join(directory.path, 'anime4k-$stamp.log'));
    final device = await _deviceInfo();
    await file.writeAsString(
      '${jsonEncode(<String, Object?>{
        'timestamp': _now().toUtc().toIso8601String(),
        'type': 'session',
        ...device,
      })}\n',
      mode: FileMode.append,
      flush: true,
    );
    return file;
  }

  static Future<Map<String, Object?>> _readDeviceInfo() async {
    final info = await DeviceInfoPlugin().deviceInfo;
    final data = info.data;
    final nestedUtsname = data['utsname'];
    String? machine;
    if (nestedUtsname is Map) {
      final value = nestedUtsname['machine'];
      if (value != null) machine = '$value';
    }
    machine ??= _firstText(data, const <String>['machine', 'arch']);

    final physicalValue = data['isPhysicalDevice'];
    final isPhysicalDevice = physicalValue is bool ? physicalValue : true;
    return <String, Object?>{
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'deviceModel': _firstText(
        data,
        const <String>['modelName', 'model', 'productName', 'computerName'],
      ),
      'machine': machine,
      'isPhysicalDevice': isPhysicalDevice,
    };
  }

  static String? _firstText(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value == null) continue;
      final text = '$value'.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }
}

final anime4kPerformanceLogProvider = Provider<Anime4kPerformanceLog>((ref) {
  return Anime4kPerformanceLog();
});
'''
Path('lib/features/player/data/anime4k_performance_log.dart').write_text(logger)

replace_once(
    'lib/features/player/presentation/player_controller.dart',
    "import '../data/anime4k_performance.dart';\nimport '../data/anime4k_shader_library.dart';",
    "import '../data/anime4k_performance.dart';\nimport '../data/anime4k_performance_log.dart';\nimport '../data/anime4k_shader_library.dart';",
)
replace_once(
    'lib/features/player/presentation/player_controller.dart',
    "  late Anime4kDiagnosticsController _anime4kDiagnostics;\n  bool _anime4kEcoSampleInFlight = false;",
    "  late Anime4kDiagnosticsController _anime4kDiagnostics;\n  late Anime4kPerformanceLog _anime4kPerformanceLog;\n  bool _anime4kEcoSampleInFlight = false;",
)
replace_once(
    'lib/features/player/presentation/player_controller.dart',
    "    _anime4kDiagnostics = ref.read(anime4kDiagnosticsProvider.notifier);\n\n    ref.listen(playerSettingsProvider,",
    "    _anime4kDiagnostics = ref.read(anime4kDiagnosticsProvider.notifier);\n    _anime4kPerformanceLog = ref.read(anime4kPerformanceLogProvider);\n\n    ref.listen(playerSettingsProvider,",
)
replace_once(
    'lib/features/player/presentation/player_controller.dart',
    "      if (_anime4kForceMpvFallback && _isApplePlatform) {\n        await _applyResolvedMpvFallback();\n        return;\n      }",
    "      if (_anime4kForceMpvFallback && _isApplePlatform) {\n        final fallbackSettings = ref.read(playerSettingsProvider).asData?.value;\n        if (fallbackSettings != null) {\n          unawaited(\n            _anime4kPerformanceLog.recordRoute(\n              backend: Anime4kBackend.mpvGlsl,\n              mode: fallbackSettings.anime4kMode,\n              requestedQuality: fallbackSettings.anime4kQuality,\n              ecoEnabled: fallbackSettings.anime4kEcoEnabled,\n              metalFxExperiment: _anime4kMetalFxExperimentEnabled,\n              reason: 'runtime-fallback',\n            ),\n          );\n        }\n        await _applyResolvedMpvFallback();\n        return;\n      }",
)
replace_once(
    'lib/features/player/presentation/player_controller.dart',
    "          if (colorState == Anime4kNativeMetalState.unsupportedHdr) {\n            await _applyResolvedMpvFallback(platform: platform);\n            return;\n          }",
    "          if (colorState == Anime4kNativeMetalState.unsupportedHdr) {\n            unawaited(\n              _anime4kPerformanceLog.recordRoute(\n                backend: Anime4kBackend.mpvGlsl,\n                mode: settings.anime4kMode,\n                requestedQuality: settings.anime4kQuality,\n                ecoEnabled: settings.anime4kEcoEnabled,\n                metalFxExperiment: _anime4kMetalFxExperimentEnabled,\n                colorSignal: colorSignal.name,\n                reason: colorSignal == Anime4kColorSignal.hdr\n                    ? 'hdr-fallback'\n                    : 'unknown-color-fallback',\n              ),\n            );\n            await _applyResolvedMpvFallback(platform: platform);\n            return;\n          }",
)
replace_once(
    'lib/features/player/presentation/player_controller.dart',
    "      final settings = ref.read(playerSettingsProvider).asData?.value;\n      if (!_isApplePlatform ||",
    "      final settings = ref.read(playerSettingsProvider).asData?.value;\n      if (settings != null) {\n        await _recordAnime4kPostApplyRoute(settings);\n      }\n      if (!_isApplePlatform ||",
)
replace_once(
    'lib/features/player/presentation/player_controller.dart',
    "  Future<void> _sampleAnime4kEco() async {",
    "  bool get _anime4kMetalFxExperimentEnabled {\n    final settings = ref.read(playerSettingsProvider).asData?.value;\n    return bool.fromEnvironment('ANIME4K_METALFX_EXPERIMENT') &&\n        (settings?.anime4kEcoEnabled ?? false);\n  }\n\n  Future<void> _recordAnime4kPostApplyRoute(PlayerSettings settings) async {\n    if (!settings.anime4kEnabled || settings.anime4kMode == Anime4kMode.off) {\n      return;\n    }\n\n    var backend = Anime4kBackend.mpvGlsl;\n    final platform = player.platform;\n    if (_isApplePlatform && platform is NativePlayer) {\n      try {\n        final bridge = _ecoMetalBridge();\n        final handle = await platform.handle;\n        if (bridge != null &&\n            handle > 0 &&\n            bridge.status(handle: handle) == Anime4kNativeMetalState.ready) {\n          backend = settings.anime4kEcoEnabled\n              ? Anime4kBackend.metalEco\n              : Anime4kBackend.metal;\n        }\n      } catch (_) {\n        backend = Anime4kBackend.mpvGlsl;\n      }\n    }\n\n    unawaited(\n      _anime4kPerformanceLog.recordRoute(\n        backend: backend,\n        mode: settings.anime4kMode,\n        requestedQuality: settings.anime4kQuality,\n        ecoEnabled: settings.anime4kEcoEnabled,\n        metalFxExperiment: _anime4kMetalFxExperimentEnabled,\n        reason: 'post-apply',\n      ),\n    );\n  }\n\n  Future<void> _sampleAnime4kEco() async {",
)
replace_once(
    'lib/features/player/presentation/player_controller.dart',
    "    _anime4kPerformanceSnapshot = snapshot;\n    _anime4kDiagnostics.publish(snapshot);",
    "    _anime4kPerformanceSnapshot = snapshot;\n    _anime4kDiagnostics.publish(snapshot);\n    if (snapshot != null) {\n      unawaited(\n        _anime4kPerformanceLog.recordSnapshot(\n          snapshot,\n          metalFxExperiment: _anime4kMetalFxExperimentEnabled,\n        ),\n      );\n    }",
)

replace_once(
    'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
    "import 'package:flutter/material.dart';\nimport 'package:flutter_riverpod/flutter_riverpod.dart';",
    "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';\nimport 'package:flutter_riverpod/flutter_riverpod.dart';",
)
replace_once(
    'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
    "import '../../../player/data/anime4k_download.dart';\nimport '../../../player/data/anime4k_shader_library.dart';",
    "import '../../../player/data/anime4k_download.dart';\nimport '../../../player/data/anime4k_performance_log.dart';\nimport '../../../player/data/anime4k_shader_library.dart';",
)
replace_once(
    'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
    "void showAnime4kDialog(BuildContext context, WidgetRef ref) {\n  showGlassDialog<void>(\n    context: context,\n    builder: (context) => const _Anime4kDialog(),\n  );\n}\n\nclass _Anime4kDialog",
    "void showAnime4kDialog(BuildContext context, WidgetRef ref) {\n  showGlassDialog<void>(\n    context: context,\n    builder: (context) => const _Anime4kDialog(),\n  );\n}\n\nFuture<void> showAnime4kPerformanceLogDialog(\n  BuildContext context,\n  WidgetRef ref,\n) async {\n  final log = ref.read(anime4kPerformanceLogProvider);\n  final text = await log.readLatest();\n  final path = await log.latestLogPath();\n  if (!context.mounted) return;\n\n  await showGlassDialog<void>(\n    context: context,\n    builder: (dialogContext) {\n      final theme = Theme.of(dialogContext);\n      final colors = theme.colorScheme;\n      final displayText = text?.trim().isNotEmpty == true\n          ? text!\n          : appText(\n              dialogContext,\n              english: 'No Anime4K performance log has been recorded yet.',\n              arabic: 'لم يتم تسجيل سجل أداء Anime4K بعد.',\n            );\n      return AlertDialog(\n        surfaceTintColor: Colors.transparent,\n        title: Text(\n          appText(\n            dialogContext,\n            english: 'Anime4K performance log',\n            arabic: 'سجل أداء Anime4K',\n          ),\n        ),\n        content: SizedBox(\n          width: 680,\n          height: 420,\n          child: Column(\n            crossAxisAlignment: CrossAxisAlignment.start,\n            children: [\n              if (path != null) ...[\n                Text(\n                  path,\n                  style: theme.textTheme.bodySmall?.copyWith(\n                    color: colors.onSurfaceVariant,\n                  ),\n                ),\n                const SizedBox(height: 8),\n              ],\n              Expanded(\n                child: DecoratedBox(\n                  decoration: BoxDecoration(\n                    color: colors.surfaceContainerHighest,\n                    borderRadius: BorderRadius.circular(8),\n                  ),\n                  child: SingleChildScrollView(\n                    padding: const EdgeInsets.all(12),\n                    child: SelectableText(\n                      displayText,\n                      style: theme.textTheme.bodySmall,\n                    ),\n                  ),\n                ),\n              ),\n            ],\n          ),\n        ),\n        actions: [\n          if (text != null && text.isNotEmpty)\n            TextButton.icon(\n              onPressed: () async {\n                await Clipboard.setData(ClipboardData(text: text));\n              },\n              icon: const Icon(Icons.copy_rounded),\n              label: Text(\n                appText(dialogContext, english: 'Copy', arabic: 'نسخ'),\n              ),\n            ),\n          TextButton(\n            onPressed: () => Navigator.pop<void>(dialogContext),\n            child: Text(\n              appText(dialogContext, english: 'Close', arabic: 'إغلاق'),\n            ),\n          ),\n        ],\n      );\n    },\n  );\n}\n\nclass _Anime4kDialog",
)
replace_once(
    'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
    "      actions: [\n        TextButton(\n          onPressed: () => Navigator.pop<void>(context),",
    "      actions: [\n        TextButton.icon(\n          onPressed: () => showAnime4kPerformanceLogDialog(context, ref),\n          icon: const Icon(Icons.article_outlined),\n          label: Text(\n            appText(\n              context,\n              english: 'Performance log',\n              arabic: 'سجل الأداء',\n            ),\n          ),\n        ),\n        TextButton(\n          onPressed: () => Navigator.pop<void>(context),",
)

contract_test = r'''import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/data/anime4k_performance.dart';
import 'package:animewitcher/features/player/data/anime4k_performance_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K in-app performance log contract', () {
    test('dedicated Anime4K logger persists device-local benchmark evidence', () {
      final file = File(
        'lib/features/player/data/anime4k_performance_log.dart',
      );
      expect(file.existsSync(), isTrue);
      final source = file.readAsStringSync();

      expect(source, contains('class Anime4kPerformanceLog'));
      expect(source, contains("'anime4k-'"));
      expect(source, contains('getApplicationDocumentsDirectory'));
      expect(source, contains("'log'"));
      expect(source, contains('DeviceInfoPlugin'));
      expect(source, contains('isPhysicalDevice'));
      expect(source, contains('recordRoute'));
      expect(source, contains('recordSnapshot'));
      expect(source, contains('averageFrameTimeMs'));
      expect(source, contains('p95FrameTimeMs'));
      expect(source, contains('processedFrames'));
      expect(source, contains('skippedDuplicateFrames'));
      expect(source, contains('droppedOrLateFrames'));
      expect(source, contains('thermalLevel'));
      expect(source, contains('lowPowerMode'));
      expect(source, contains('metalFxExperiment'));
    });

    test('player samples and route decisions are written to the same log', () {
      final source = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      expect(
        source,
        contains("import '../data/anime4k_performance_log.dart';"),
      );
      expect(source, contains('anime4kPerformanceLogProvider'));
      expect(source, contains('.recordSnapshot('));
      expect(source, contains('.recordRoute('));
    });

    test('Anime4K settings expose the local performance log inside the app', () {
      final source = File(
        'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
      ).readAsStringSync();

      expect(source, contains('Anime4K performance log'));
      expect(source, contains('سجل أداء Anime4K'));
      expect(source, contains('showAnime4kPerformanceLogDialog'));
    });

    test('route and snapshot events share a JSONL session log', () async {
      final root = await Directory.systemTemp.createTemp('anime4k-log-test-');
      addTearDown(() => root.delete(recursive: true));
      final now = DateTime.utc(2026, 9, 12, 18, 0);
      final log = Anime4kPerformanceLog(
        documentsDirectory: () async => root,
        deviceInfo: () async => <String, Object?>{
          'deviceModel': 'iPhone17,1',
          'isPhysicalDevice': true,
        },
        now: () => now,
      );

      await log.recordRoute(
        backend: Anime4kBackend.metalEco,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: true,
        metalFxExperiment: false,
        colorSignal: 'sdr',
        reason: 'post-apply',
      );
      await log.recordSnapshot(
        const Anime4kPerformanceSnapshot(
          backend: Anime4kBackend.metalEco,
          requestedMode: Anime4kMode.a,
          requestedQuality: Anime4kQuality.s,
          effectiveQuality: Anime4kQuality.s,
          inputWidth: 1920,
          inputHeight: 1080,
          processingWidth: 1178,
          processingHeight: 662,
          averageFrameTimeMs: 4.25,
          p95FrameTimeMs: 5.75,
          processedFrames: 120,
          skippedDuplicateFrames: 120,
          droppedOrLateFrames: 1,
          thermalLevel: Anime4kThermalLevel.nominal,
          lowPowerMode: false,
        ),
        metalFxExperiment: false,
      );

      final text = await log.readLatest();
      expect(text, isNotNull);
      expect(text, contains('"type":"session"'));
      expect(text, contains('"isPhysicalDevice":true'));
      expect(text, contains('"type":"route"'));
      expect(text, contains('"backend":"metalEco"'));
      expect(text, contains('"type":"snapshot"'));
      expect(text, contains('"averageFrameTimeMs":4.25'));
      expect(text, contains('"p95FrameTimeMs":5.75'));
      expect(text, contains('"skippedDuplicateFrames":120'));
    });
  });
}
'''
Path('test/features/player/anime4k_performance_log_contract_test.dart').write_text(contract_test)
