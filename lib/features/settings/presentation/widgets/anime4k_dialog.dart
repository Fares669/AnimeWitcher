import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

import '../../../../shared/widgets/glass_dialog.dart';
import '../../../player/data/anime4k.dart';
import '../../../player/data/anime4k_download.dart';
import '../../../player/data/anime4k_shader_library.dart';
import '../../../player/presentation/player_controller.dart';
import '../../../player/presentation/widgets/anime4k_sample_preview.dart';
import '../player_settings_provider.dart';

/// Picks an Anime4K pipeline, its network size, and the folder the shaders
/// live in.
///
/// The shaders are not shipped with the app — they are a separate download
/// from the Anime4K project — so the folder comes first here, and the modes
/// are shown against what that folder actually contains rather than as a list
/// of promises.
void showAnime4kDialog(BuildContext context, WidgetRef ref) {
  showGlassDialog<void>(
    context: context,
    builder: (context) => const _Anime4kDialog(),
  );
}

class _Anime4kDialog extends ConsumerStatefulWidget {
  const _Anime4kDialog();

  @override
  ConsumerState<_Anime4kDialog> createState() => _Anime4kDialogState();
}

class _Anime4kDialogState extends ConsumerState<_Anime4kDialog> {
  Anime4kPipeline? _pipeline;
  bool _checking = false;
  bool _downloading = false;
  double? _downloadProgress;
  String? _downloadError;
  int? _downloaded;

  /// The mode to come back to when the switch is turned on again.
  Anime4kMode _lastMode = Anime4kMode.a;

  @override
  void initState() {
    super.initState();
    final saved = _settings.anime4kMode;
    if (saved != Anime4kMode.off) _lastMode = saved;
    _refreshPipeline();
  }

  PlayerSettings get _settings =>
      ref.read(playerSettingsProvider).asData?.value ?? const PlayerSettings();

  /// Resolves the chosen mode against the folder so the dialog can say what
  /// will actually run, instead of leaving it to be discovered mid-episode.
  Future<void> _refreshPipeline() async {
    final settings = _settings;
    if (settings.anime4kShaderDirectory.trim().isEmpty) {
      if (mounted) setState(() => _pipeline = null);
      return;
    }
    setState(() => _checking = true);
    final pipeline = await ref
        .read(anime4kShaderLibraryProvider)
        .pipeline(
          mode: settings.anime4kMode == Anime4kMode.off
              ? Anime4kMode.a
              : settings.anime4kMode,
          quality: settings.anime4kQuality,
          directory: settings.anime4kShaderDirectory,
        );
    if (!mounted) return;
    setState(() {
      _pipeline = pipeline;
      _checking = false;
    });
  }

  /// Fetches the official release and points the setting at it.
  ///
  /// This is the path almost everyone should take. The alternative is
  /// finding a zip on GitHub, unpacking it, and aiming a file picker at the
  /// right folder inside it — three steps in front of a feature whose whole
  /// appeal is that it improves the picture without being thought about.
  Future<void> _downloadShaders() async {
    setState(() {
      _downloading = true;
      _downloadProgress = null;
      _downloadError = null;
      _downloaded = null;
    });
    try {
      final result = await ref
          .read(anime4kDownloaderProvider)
          .download(
            onProgress: (value) {
              if (mounted) setState(() => _downloadProgress = value);
            },
          );
      if (!mounted) return;
      await ref
          .read(playerSettingsProvider.notifier)
          .setAnime4kShaderDirectory(result.directory);
      if (!mounted) return;
      setState(() => _downloaded = result.written);
      await _refreshPipeline();
      await _reapply();
    } catch (error) {
      if (!mounted) return;
      setState(() => _downloadError = '$error');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _chooseFolder() async {
    final chosen = await FilePicker.getDirectoryPath();
    if (chosen == null || !mounted) return;
    await ref
        .read(playerSettingsProvider.notifier)
        .setAnime4kShaderDirectory(chosen);
    if (!mounted) return;
    await _refreshPipeline();
    await _reapply();
  }

  /// Pushes the change onto whatever is playing, so a mode can be judged
  /// against the picture rather than on the next episode.
  Future<void> _reapply() async {
    try {
      await ref.read(playerControllerProvider.notifier).applyAnime4kShaders();
    } catch (_) {
      // Nothing is playing, which is the common case from the settings page.
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      playerSettingsProvider.select(
        (value) => value.asData?.value ?? const PlayerSettings(),
      ),
    );
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final folder = settings.anime4kShaderDirectory.trim();
    final hasFolder = folder.isNotEmpty;

    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: const Text('Anime4K'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appText(
                  context,
                  english:
                      'Restores and upscales anime on the GPU while it '
                      'plays. Works with the built-in player only.',
                  arabic:
                      'يحسّن الصورة ويكبّرها على كرت الشاشة أثناء التشغيل. '
                      'يعمل مع المشغّل المدمج فقط.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),

              // --- the folder ------------------------------------------------
              Text(
                appText(
                  context,
                  english: 'Shader folder',
                  arabic: 'مجلد الشيدرات',
                ),
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              Text(
                hasFolder
                    ? folder
                    : appText(
                        context,
                        english:
                            'None yet. The app can fetch the official '
                            'release for you.',
                        arabic:
                            'لا يوجد بعد. يمكن للتطبيق تنزيل الإصدار '
                            'الرسمي نيابةً عنك.',
                      ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              if (_downloading)
                Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: _downloadProgress,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _downloadProgress == null
                          ? appText(
                              context,
                              english: 'Downloading...',
                              arabic: 'جارٍ التنزيل…',
                            )
                          : appText(
                              context,
                              english:
                                  'Downloading '
                                  '${(_downloadProgress! * 100).round()}%',
                              arabic:
                                  'جارٍ التنزيل '
                                  '${(_downloadProgress! * 100).round()}٪',
                            ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _downloadShaders,
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: Text(
                        hasFolder
                            ? appText(
                                context,
                                english: 'Download again',
                                arabic: 'إعادة التنزيل',
                              )
                            : appText(
                                context,
                                english: 'Download shaders',
                                arabic: 'تنزيل الشيدرات',
                              ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _chooseFolder,
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      label: Text(
                        hasFolder
                            ? appText(
                                context,
                                english: 'Change folder',
                                arabic: 'تغيير المجلد',
                              )
                            : appText(
                                context,
                                english: 'I already have them',
                                arabic: 'لديّ الملفات',
                              ),
                      ),
                    ),
                  ],
                ),
              if (_downloadError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _downloadError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              ],
              if (_downloaded != null && _downloadError == null) ...[
                const SizedBox(height: 8),
                Text(
                  appText(
                    context,
                    english: 'Downloaded $_downloaded shaders',
                    arabic: 'تم تنزيل $_downloaded ملفًا',
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (hasFolder) ...[
                const SizedBox(height: 8),
                _StatusLine(pipeline: _pipeline, checking: _checking),
              ],

              const Divider(height: 28),

              // --- on, then what kind ----------------------------------------
              //
              // Off used to be one option among seven modes, which made
              // switching the feature off read as choosing a kind of
              // enhancement. It is a state of the feature, not a flavour of
              // it, so it gets the switch and the modes appear underneath.
              SwitchListTile(
                value: settings.anime4kEnabled,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  appText(
                    context,
                    english: 'Enhance the picture',
                    arabic: 'تحسين الصورة',
                  ),
                  style: theme.textTheme.titleSmall,
                ),
                onChanged: (on) async {
                  final notifier = ref.read(playerSettingsProvider.notifier);
                  await notifier.setAnime4kEnabled(on);
                  // Turning it on with no pipeline chosen — or with one the
                  // player was told to stop — needs something to run.
                  if (on && settings.anime4kMode == Anime4kMode.off) {
                    await notifier.setAnime4kMode(
                      _lastMode == Anime4kMode.off ? Anime4kMode.a : _lastMode,
                    );
                  }
                  await _refreshPipeline();
                  await _reapply();
                },
              ),

              if (settings.anime4kEnabled) ...[
                const SizedBox(height: 8),
                Text(
                  appText(context, english: 'Mode', arabic: 'النمط'),
                  style: theme.textTheme.labelLarge,
                ),
                RadioGroup<Anime4kMode>(
                  groupValue: settings.anime4kMode,
                  onChanged: (value) async {
                    if (value == null) return;
                    _lastMode = value;
                    await ref
                        .read(playerSettingsProvider.notifier)
                        .setAnime4kMode(value);
                    await _refreshPipeline();
                    await _reapply();
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final mode in Anime4kMode.values)
                        if (mode != Anime4kMode.off)
                          RadioListTile<Anime4kMode>(
                            value: mode,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${appText(context, english: "Mode", arabic: "النمط")} ${mode.label}',
                            ),
                            subtitle: Text(_modeHint(context, mode)),
                          ),
                    ],
                  ),
                ),
              ],

              if (settings.anime4kEnabled) ...[
                const Divider(height: 28),
                Text(
                  appText(context, english: 'Quality', arabic: 'الجودة'),
                  style: theme.textTheme.labelLarge,
                ),
                Text(
                  appText(
                    context,
                    english: Platform.isAndroid || Platform.isIOS
                        ? 'On phones, start with S. Each step up roughly doubles '
                              'GPU work and can increase heat and battery use.'
                        : 'Each step up roughly doubles the work the GPU does.',
                    arabic: Platform.isAndroid || Platform.isIOS
                        ? 'على الهاتف ابدأ بحجم S. كل درجة أعلى تضاعف تقريبًا '
                              'عمل الـGPU وقد تزيد الحرارة واستهلاك البطارية.'
                        : 'كل درجة أعلى تضاعف تقريبًا الحِمل على كرت الشاشة.',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final quality in Anime4kQuality.values)
                      ChoiceChip(
                        label: Text(quality.suffix),
                        selected: settings.anime4kQuality == quality,
                        onSelected: (_) async {
                          await ref
                              .read(playerSettingsProvider.notifier)
                              .setAnime4kQuality(quality);
                          await _refreshPipeline();
                          await _reapply();
                        },
                      ),
                  ],
                ),
                const Divider(height: 28),
                Anime4kSamplePreview(
                  mode: settings.anime4kMode,
                  quality: settings.anime4kQuality,
                  shaderDirectory: settings.anime4kShaderDirectory,
                  titleColor: colors.onSurface,
                  bodyColor: colors.onSurfaceVariant,
                  fillColor: colors.surfaceContainerHighest,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop<void>(context),
          child: Text(appText(context, english: 'Done', arabic: 'تم')),
        ),
      ],
    );
  }

  String _modeHint(BuildContext context, Anime4kMode mode) {
    return switch (mode) {
      Anime4kMode.off => appText(
        context,
        english: 'The picture is left as the source made it',
        arabic: 'تُترك الصورة كما هي من المصدر',
      ),
      Anime4kMode.a => appText(
        context,
        english: 'For compressed sources — most of what streams',
        arabic: 'للمصادر المضغوطة — وهي أغلب ما يُبَث',
      ),
      Anime4kMode.b => appText(
        context,
        english: 'A gentler restore, when A over-sharpens',
        arabic: 'ترميم أخف، حين يبالغ النمط A في الحدة',
      ),
      Anime4kMode.c => appText(
        context,
        english: 'For sources that are already clean',
        arabic: 'للمصادر النظيفة أصلًا',
      ),
      Anime4kMode.aa => appText(
        context,
        english: 'A run twice — slower, for badly degraded sources',
        arabic: 'النمط A مرتين — أبطأ، للمصادر السيئة جدًا',
      ),
      Anime4kMode.bb => appText(
        context,
        english: 'B run twice',
        arabic: 'النمط B مرتين',
      ),
      Anime4kMode.ca => appText(
        context,
        english: 'C followed by a restore pass',
        arabic: 'النمط C يتبعه ترميم',
      ),
    };
  }
}

/// Says what the chosen folder can actually run.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.pipeline, required this.checking});

  final Anime4kPipeline? pipeline;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    if (checking) {
      return Text(
        appText(context, english: 'Reading…', arabic: 'جارٍ القراءة…'),
        style: theme.textTheme.bodySmall,
      );
    }
    final resolved = pipeline;
    if (resolved == null) return const SizedBox.shrink();

    if (resolved.files.isEmpty) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: colors.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              appText(
                context,
                english: 'No Anime4K shaders found in this folder',
                arabic: 'لا توجد ملفات Anime4K في هذا المجلد',
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ),
        ],
      );
    }

    final found = appText(
      context,
      english: '${resolved.files.length} shaders found',
      arabic: 'تم العثور على ${resolved.files.length} ملفات',
    );
    if (resolved.missing.isEmpty) {
      return Row(
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 16,
            color: colors.primary,
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(found, style: theme.textTheme.bodySmall)),
        ],
      );
    }
    return Text(
      '$found — ${appText(context, english: "missing", arabic: "ناقص")}: '
      '${resolved.missing.join(", ")}',
      style: theme.textTheme.bodySmall?.copyWith(
        color: colors.onSurfaceVariant,
      ),
    );
  }
}
