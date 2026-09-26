import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/apple_liquid_glass.dart';

import 'manga_reader_settings.dart';
import 'manga_reader_settings_provider.dart';

/// The manga reader's own screen: the options below under a bar with a
/// reset button, for a phone, where the settings list links here.
class MangaReaderSettingsScreen extends ConsumerWidget {
  const MangaReaderSettingsScreen({super.key});

  String _t(BuildContext context, String en, String ar) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar'
      ? ar
      : en;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(mangaReaderSettingsProvider.notifier);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            automaticallyImplyLeading: false,
            centerTitle: true,
            leadingWidth: appleUsesPersistentLiquidGlassHeader ? 0 : 64,
            leading: appleUsesPersistentLiquidGlassHeader
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: AppleLiquidGlassBackButton(
                      size: 46,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
            title: ApplePersistentGlassHeaderScope(
              enabled: Navigator.of(context).canPop(),
              onBack: () => Navigator.of(context).maybePop(),
              backForegroundColor: colors.onSurface,
              backFallbackColor: colors.surfaceContainerHigh,
              trailingButtons: <AppleLiquidGlassToolbarButton>[
                AppleLiquidGlassToolbarButton(
                  icon: Icons.restart_alt_rounded,
                  tooltip: _t(context, 'Reset', 'إعادة ضبط'),
                  onPressed: notifier.reset,
                ),
              ],
              child: Text(_t(context, 'Manga Reader', 'قارئ المانجا')),
            ),
            actions: appleUsesPersistentLiquidGlassHeader
                ? const <Widget>[]
                : <Widget>[
                    IconButton(
                      tooltip: _t(context, 'Reset', 'إعادة ضبط'),
                      onPressed: notifier.reset,
                      icon: const Icon(Icons.restart_alt_rounded),
                    ),
                  ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: const <Widget>[MangaReaderSettingsOptions()],
      ),
    );
  }
}

/// Every reader option, laid out in place. The phone reaches them on their
/// own screen; a wide window's settings pane shows them in its reader group
/// directly, so nothing there needs opening to be changed.
class MangaReaderSettingsOptions extends ConsumerWidget {
  const MangaReaderSettingsOptions({super.key, this.showReset = false});

  /// Adds a reset button at the end, for a place without the screen's bar.
  final bool showReset;

  String _t(BuildContext context, String en, String ar) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar'
      ? ar
      : en;

  String _modeLabel(BuildContext context, MangaReaderMode mode) =>
      switch (mode) {
        MangaReaderMode.vertical => _t(context, 'Vertical', 'عمودي'),
        MangaReaderMode.pagedLtr => _t(
          context,
          'Left to right',
          'من اليسار لليمين',
        ),
        MangaReaderMode.pagedRtl => _t(
          context,
          'Right to left',
          'من اليمين لليسار',
        ),
        MangaReaderMode.verticalContinuous => _t(
          context,
          'Vertical continuous',
          'عمودي مستمر',
        ),
        MangaReaderMode.webtoon => _t(context, 'Webtoon', 'ويب تون'),
        MangaReaderMode.horizontalContinuous => _t(
          context,
          'Horizontal continuous',
          'أفقي مستمر',
        ),
        MangaReaderMode.horizontalContinuousRtl => _t(
          context,
          'Horizontal continuous (RTL)',
          'أفقي مستمر (RTL)',
        ),
      };

  String _scaleLabel(
    BuildContext context,
    MangaReaderScaleType type,
  ) => switch (type) {
    MangaReaderScaleType.fitScreen => _t(
      context,
      'Fit screen',
      'ملاءمة الشاشة',
    ),
    MangaReaderScaleType.stretch => _t(context, 'Stretch', 'تمديد'),
    MangaReaderScaleType.fitWidth => _t(context, 'Fit width', 'ملاءمة العرض'),
    MangaReaderScaleType.fitHeight => _t(
      context,
      'Fit height',
      'ملاءمة الارتفاع',
    ),
    MangaReaderScaleType.originalSize => _t(
      context,
      'Original size',
      'الحجم الأصلي',
    ),
    MangaReaderScaleType.smartFit => _t(context, 'Smart fit', 'ملاءمة ذكية'),
  };

  String _backgroundLabel(BuildContext context, MangaReaderBackground value) =>
      switch (value) {
        MangaReaderBackground.black => _t(context, 'Black', 'أسود'),
        MangaReaderBackground.grey => _t(context, 'Grey', 'رمادي'),
        MangaReaderBackground.white => _t(context, 'White', 'أبيض'),
        MangaReaderBackground.automatic => _t(context, 'Automatic', 'تلقائي'),
      };

  String _flashColorLabel(BuildContext context, int value) => switch (value) {
    1 => _t(context, 'White', 'أبيض'),
    2 => _t(context, 'Soft white', 'أبيض خفيف'),
    _ => _t(context, 'Black', 'أسود'),
  };

  Future<T?> _choose<T>({
    required BuildContext context,
    required String title,
    required T value,
    required List<T> values,
    required String Function(T value) label,
  }) => showDialog<T>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: <Widget>[
        for (final option in values)
          RadioListTile<T>(
            value: option,
            // TODO(flutter): migrate to RadioGroup when the app's
            // minimum Flutter SDK exposes the stable inherited API.
            // ignore: deprecated_member_use
            groupValue: value,
            title: Text(label(option)),
            // ignore: deprecated_member_use
            onChanged: (next) => Navigator.of(context).pop(next),
          ),
      ],
    ),
  );

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(mangaReaderSettingsProvider);
    final notifier = ref.read(mangaReaderSettingsProvider.notifier);
    final update = notifier.update;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _section(context, _t(context, 'Reading', 'القراءة')),
        ListTile(
          title: Text(_t(context, 'Reading mode', 'وضع القراءة')),
          subtitle: Text(_modeLabel(context, settings.defaultMode)),
          onTap: () async {
            final value = await _choose<MangaReaderMode>(
              context: context,
              title: _t(context, 'Reading mode', 'وضع القراءة'),
              value: settings.defaultMode,
              values: MangaReaderMode.values,
              label: (value) => _modeLabel(context, value),
            );
            if (value != null) {
              await update((s) => s.copyWith(defaultMode: value));
            }
          },
        ),
        ListTile(
          title: Text(_t(context, 'Scale type', 'طريقة الملاءمة')),
          subtitle: Text(_scaleLabel(context, settings.scaleType)),
          onTap: () async {
            final value = await _choose<MangaReaderScaleType>(
              context: context,
              title: _t(context, 'Scale type', 'طريقة الملاءمة'),
              value: settings.scaleType,
              values: MangaReaderScaleType.values,
              label: (value) => _scaleLabel(context, value),
            );
            if (value != null) {
              await update((s) => s.copyWith(scaleType: value));
            }
          },
        ),
        SwitchListTile(
          title: Text(_t(context, 'Crop borders', 'قص الحواف')),
          value: settings.cropBorders,
          onChanged: (value) => update((s) => s.copyWith(cropBorders: value)),
        ),
        ListTile(
          title: Text(_t(context, 'Preload pages', 'تحميل الصفحات مسبقًا')),
          subtitle: Slider(
            min: 0,
            max: 20,
            divisions: 20,
            value: settings.pagePreloadAmount.toDouble(),
            label: settings.pagePreloadAmount.toString(),
            onChanged: (value) =>
                update((s) => s.copyWith(pagePreloadAmount: value.toInt())),
          ),
        ),
        SwitchListTile(
          title: Text(
            _t(context, 'Animate page transitions', 'تحريك انتقال الصفحات'),
          ),
          value: settings.animatePageTransitions,
          onChanged: (value) =>
              update((s) => s.copyWith(animatePageTransitions: value)),
        ),
        ListTile(
          title: Text(
            _t(
              context,
              'Double-tap animation speed',
              'سرعة حركة النقر المزدوج',
            ),
          ),
          subtitle: SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              ButtonSegment(value: 0, label: Text(_t(context, 'Off', 'بدون'))),
              ButtonSegment(
                value: 1,
                label: Text(_t(context, 'Normal', 'عادي')),
              ),
              ButtonSegment(value: 2, label: Text(_t(context, 'Fast', 'سريع'))),
            ],
            selected: <int>{settings.doubleTapAnimationSpeed},
            onSelectionChanged: (values) => update(
              (s) => s.copyWith(doubleTapAnimationSpeed: values.first),
            ),
          ),
        ),

        _section(context, _t(context, 'Double page', 'صفحتان')),
        SwitchListTile(
          title: Text(_t(context, 'Automatic double page', 'صفحتان تلقائيًا')),
          subtitle: Text(
            _t(
              context,
              'Use two pages automatically in landscape',
              'استخدام صفحتين تلقائيًا بالوضع الأفقي',
            ),
          ),
          value: settings.doublePageAuto,
          onChanged: (value) =>
              update((s) => s.copyWith(doublePageAuto: value)),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Single first page', 'الصفحة الأولى منفردة')),
          value: settings.doublePageSingleFirstPage,
          onChanged: (value) =>
              update((s) => s.copyWith(doublePageSingleFirstPage: value)),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Invert double pages', 'عكس الصفحتين')),
          value: settings.dualPageInvert,
          onChanged: (value) =>
              update((s) => s.copyWith(dualPageInvert: value)),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Split wide pages', 'تقسيم الصفحات العريضة')),
          value: settings.splitWidePages,
          onChanged: (value) =>
              update((s) => s.copyWith(splitWidePages: value)),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Rotate to fit', 'التدوير للملاءمة')),
          value: settings.dualPageRotateToFit,
          onChanged: (value) =>
              update((s) => s.copyWith(dualPageRotateToFit: value)),
        ),
        if (settings.dualPageRotateToFit)
          SwitchListTile(
            title: Text(
              _t(context, 'Invert rotated pages', 'عكس الصفحات المدورة'),
            ),
            value: settings.dualPageRotateToFitInvert,
            onChanged: (value) =>
                update((s) => s.copyWith(dualPageRotateToFitInvert: value)),
          ),

        _section(context, _t(context, 'Display', 'العرض')),
        ListTile(
          title: Text(_t(context, 'Background', 'الخلفية')),
          subtitle: Text(_backgroundLabel(context, settings.background)),
          onTap: () async {
            final value = await _choose<MangaReaderBackground>(
              context: context,
              title: _t(context, 'Background', 'الخلفية'),
              value: settings.background,
              values: MangaReaderBackground.values,
              label: (value) => _backgroundLabel(context, value),
            );
            if (value != null) {
              await update((s) => s.copyWith(background: value));
            }
          },
        ),
        SwitchListTile(
          title: Text(_t(context, 'Full screen', 'ملء الشاشة')),
          value: settings.fullScreen,
          onChanged: (value) => update((s) => s.copyWith(fullScreen: value)),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Keep screen on', 'إبقاء الشاشة مضاءة')),
          value: settings.keepScreenOn,
          onChanged: (value) => update((s) => s.copyWith(keepScreenOn: value)),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Show page number', 'إظهار رقم الصفحة')),
          value: settings.showPageNumber,
          onChanged: (value) =>
              update((s) => s.copyWith(showPageNumber: value)),
        ),
        SwitchListTile(
          title: Text(
            _t(context, 'Show page gaps', 'إظهار الفواصل بين الصفحات'),
          ),
          value: settings.showPageGaps,
          onChanged: (value) => update((s) => s.copyWith(showPageGaps: value)),
        ),
        SwitchListTile(
          title: Text(
            _t(
              context,
              'Auto-read duplicate chapters',
              'تعليم الفصول المكررة كمقروءة تلقائيًا',
            ),
          ),
          value: settings.autoReadDuplicateChapters,
          onChanged: (value) =>
              update((s) => s.copyWith(autoReadDuplicateChapters: value)),
        ),
        ListTile(
          title: Text(
            '${_t(context, 'Webtoon side padding', 'هوامش الويب تون')}: '
            '${settings.webtoonSidePadding}%',
          ),
          subtitle: Slider(
            min: 0,
            max: 50,
            divisions: 50,
            value: settings.webtoonSidePadding.toDouble(),
            onChanged: (value) =>
                update((s) => s.copyWith(webtoonSidePadding: value.toInt())),
          ),
        ),

        _section(context, _t(context, 'Navigation & zoom', 'التنقل والتكبير')),
        SwitchListTile(
          title: Text(_t(context, 'Use page tap zones', 'استخدام مناطق النقر')),
          value: settings.usePageTapZones,
          onChanged: (value) =>
              update((s) => s.copyWith(usePageTapZones: value)),
        ),
        ListTile(
          title: Text(_t(context, 'Navigation layout', 'تخطيط مناطق التنقل')),
          subtitle: Slider(
            min: 0,
            max: 5,
            divisions: 5,
            value: settings.navigationLayout.toDouble(),
            label: settings.navigationLayout.toString(),
            onChanged: (value) =>
                update((s) => s.copyWith(navigationLayout: value.toInt())),
          ),
        ),
        ListTile(
          title: Text(_t(context, 'Tap inversion', 'عكس النقر')),
          subtitle: Slider(
            min: 0,
            max: 3,
            divisions: 3,
            value: settings.tappingInversion.toDouble(),
            label: settings.tappingInversion.toString(),
            onChanged: (value) =>
                update((s) => s.copyWith(tappingInversion: value.toInt())),
          ),
        ),
        SwitchListTile(
          title: Text(
            _t(context, 'Navigate while zoomed', 'التنقل أثناء التكبير'),
          ),
          value: settings.navigateToPan,
          onChanged: (value) => update((s) => s.copyWith(navigateToPan: value)),
        ),
        ListTile(
          title: Text(
            _t(context, 'Reader hide threshold', 'عتبة إخفاء أدوات القارئ'),
          ),
          subtitle: Slider(
            min: 0,
            max: 3,
            divisions: 3,
            value: settings.readerHideThreshold.toDouble(),
            label: settings.readerHideThreshold.toString(),
            onChanged: (value) =>
                update((s) => s.copyWith(readerHideThreshold: value.toInt())),
          ),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Landscape zoom', 'تكبير الوضع الأفقي')),
          value: settings.landscapeZoom,
          onChanged: (value) => update((s) => s.copyWith(landscapeZoom: value)),
        ),
        if (settings.landscapeZoom)
          ListTile(
            title: Text(
              _t(context, 'Zoom start position', 'بداية موضع التكبير'),
            ),
            subtitle: Slider(
              min: 0,
              max: 2,
              divisions: 2,
              value: settings.zoomStartPosition.toDouble(),
              onChanged: (value) =>
                  update((s) => s.copyWith(zoomStartPosition: value.toInt())),
            ),
          ),
        SwitchListTile(
          title: Text(
            _t(
              context,
              'Show navigation overlay on start',
              'إظهار شرح التنقل عند البدء',
            ),
          ),
          value: settings.showNavigationOverlayOnStart,
          onChanged: (value) =>
              update((s) => s.copyWith(showNavigationOverlayOnStart: value)),
        ),

        _section(context, _t(context, 'Webtoon', 'ويب تون')),
        SwitchListTile(
          title: Text(_t(context, 'Disable zoom out', 'منع التصغير')),
          value: settings.webtoonDisableZoomOut,
          onChanged: (value) =>
              update((s) => s.copyWith(webtoonDisableZoomOut: value)),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Double tap to zoom', 'نقر مزدوج للتكبير')),
          value: settings.webtoonDoubleTapZoomEnabled,
          onChanged: (value) =>
              update((s) => s.copyWith(webtoonDoubleTapZoomEnabled: value)),
        ),
        SwitchListTile(
          title: Text(_t(context, 'Auto scroll', 'تمرير تلقائي')),
          value: settings.autoScrollEnabled,
          onChanged: (value) =>
              update((s) => s.copyWith(autoScrollEnabled: value)),
        ),
        if (settings.autoScrollEnabled)
          ListTile(
            title: Text(
              '${_t(context, 'Auto-scroll speed', 'سرعة التمرير')}: '
              '${settings.autoScrollSpeed.toStringAsFixed(0)}',
            ),
            subtitle: Slider(
              min: 2,
              max: 30,
              divisions: 28,
              value: settings.autoScrollSpeed.clamp(2, 30).toDouble(),
              onChanged: (value) =>
                  update((s) => s.copyWith(autoScrollSpeed: value)),
            ),
          ),

        _section(
          context,
          _t(context, 'Page-change flash', 'وميض تغيير الصفحة'),
        ),
        SwitchListTile(
          title: Text(
            _t(context, 'Flash on page change', 'وميض عند تغيير الصفحة'),
          ),
          value: settings.flashOnPageChange,
          onChanged: (value) =>
              update((s) => s.copyWith(flashOnPageChange: value)),
        ),
        if (settings.flashOnPageChange)
          ListTile(
            title: Text(_t(context, 'Flash color', 'لون الوميض')),
            subtitle: Text(_flashColorLabel(context, settings.flashColor)),
            onTap: () async {
              final value = await _choose<int>(
                context: context,
                title: _t(context, 'Flash color', 'لون الوميض'),
                value: settings.flashColor,
                values: const <int>[0, 1, 2],
                label: (value) => _flashColorLabel(context, value),
              );
              if (value != null) {
                await update((s) => s.copyWith(flashColor: value));
              }
            },
          ),
        if (settings.flashOnPageChange) ...<Widget>[
          ListTile(
            title: Text(
              '${_t(context, 'Flash duration', 'مدة الوميض')}: '
              '${settings.flashDurationMs} ms',
            ),
            subtitle: Slider(
              min: 50,
              max: 500,
              divisions: 9,
              value: settings.flashDurationMs.toDouble(),
              onChanged: (value) =>
                  update((s) => s.copyWith(flashDurationMs: value.toInt())),
            ),
          ),
          ListTile(
            title: Text(
              '${_t(context, 'Flash interval', 'فاصل الوميض')}: '
              '${settings.flashInterval}',
            ),
            subtitle: Slider(
              min: 1,
              max: 10,
              divisions: 9,
              value: settings.flashInterval.toDouble(),
              onChanged: (value) =>
                  update((s) => s.copyWith(flashInterval: value.toInt())),
            ),
          ),
        ],
        if (showReset)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey<String>('manga-reader-settings-reset'),
                onPressed: notifier.reset,
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(_t(context, 'Reset', 'إعادة ضبط')),
              ),
            ),
          ),
      ],
    );
  }
}
