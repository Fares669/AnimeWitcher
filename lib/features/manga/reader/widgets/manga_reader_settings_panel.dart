import 'package:flutter/material.dart';

import '../manga_reader_settings.dart';

/// The reader's settings as Mihon lays them out: a card rising from the
/// foot of the screen with three tabs — the reading mode, the general
/// options and the custom filter — each a list of chip rows, checkboxes
/// and sliders, the same options in the same order as Mihon's.
///
/// The full list stays one tap away behind "all settings".
class MangaReaderSettingsPanel extends StatefulWidget {
  const MangaReaderSettingsPanel({
    super.key,
    required this.settings,
    required this.mode,
    required this.doublePage,
    required this.onMode,
    required this.onDoublePage,
    required this.onUpdate,
    required this.onOpenAllSettings,
    this.initialTab = MangaReaderPanelTab.mode,
    this.modeIsDefault = false,
    this.onDefaultMode,
    this.orientation,
    this.onOrientation,
    this.showVolumeKeys = false,
    this.touchDevice = true,
  });

  final MangaReaderSettings settings;

  /// The mode this manga is being read in, which can differ from the default.
  final MangaReaderMode mode;

  /// Whether two pages show side by side.
  final bool doublePage;

  final ValueChanged<MangaReaderMode> onMode;
  final ValueChanged<bool> onDoublePage;
  final void Function(MangaReaderSettings Function(MangaReaderSettings))
  onUpdate;
  final VoidCallback onOpenAllSettings;

  /// The tab open first.
  final MangaReaderPanelTab initialTab;

  /// This manga reads in the default mode, and how to go back to it.
  final bool modeIsDefault;
  final VoidCallback? onDefaultMode;

  /// This manga's own turning, null for the default; and how to change it,
  /// null where the screen does not turn, as on a computer.
  final MangaReaderOrientation? orientation;
  final ValueChanged<MangaReaderOrientation?>? onOrientation;

  /// Offered where there are volume keys to read with.
  final bool showVolumeKeys;

  /// A phone or tablet. A computer has no system bars to hide, no screen to
  /// keep awake while reading, and a right click for the page's actions, so
  /// those options are left out there.
  final bool touchDevice;

  @override
  State<MangaReaderSettingsPanel> createState() =>
      _MangaReaderSettingsPanelState();
}

/// Mihon's three tabs.
enum MangaReaderPanelTab { mode, general, filter }

/// The same mode turned the other way, or null when it has no direction.
MangaReaderMode? mangaReaderModeWithDirection(
  MangaReaderMode mode, {
  required bool rtl,
}) => switch (mode) {
  MangaReaderMode.pagedLtr || MangaReaderMode.pagedRtl =>
    rtl ? MangaReaderMode.pagedRtl : MangaReaderMode.pagedLtr,
  MangaReaderMode.horizontalContinuous ||
  MangaReaderMode.horizontalContinuousRtl =>
    rtl
        ? MangaReaderMode.horizontalContinuousRtl
        : MangaReaderMode.horizontalContinuous,
  _ => null,
};

/// A mode's name, as the reader has always called it.
String mangaReaderModeName(MangaReaderMode mode, {required bool arabic}) =>
    switch (mode) {
      MangaReaderMode.vertical => arabic ? 'عمودي' : 'Vertical',
      MangaReaderMode.pagedLtr => arabic ? 'من اليسار لليمين' : 'Left to right',
      MangaReaderMode.pagedRtl => arabic ? 'من اليمين لليسار' : 'Right to left',
      MangaReaderMode.verticalContinuous =>
        arabic ? 'عمودي مستمر' : 'Vertical continuous',
      MangaReaderMode.webtoon => arabic ? 'ويب تون' : 'Webtoon',
      MangaReaderMode.horizontalContinuous =>
        arabic ? 'أفقي مستمر' : 'Horizontal continuous',
      MangaReaderMode.horizontalContinuousRtl =>
        arabic ? 'أفقي مستمر (RTL)' : 'Horizontal continuous (RTL)',
    };

class _MangaReaderSettingsPanelState extends State<MangaReaderSettingsPanel> {
  late MangaReaderPanelTab _tab = widget.initialTab;

  @override
  void didUpdateWidget(covariant MangaReaderSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) _tab = widget.initialTab;
  }

  ColorScheme get _colors => Theme.of(context).colorScheme;

  bool get _ar =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
  String _t(String en, String ar) => _ar ? ar : en;

  void _update(MangaReaderSettings Function(MangaReaderSettings) change) =>
      widget.onUpdate(change);

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    return Material(
      key: const ValueKey<String>('manga-reader-settings-panel'),
      color: _colors.surfaceContainerHigh,
      elevation: 8,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _tabs(context),
            Divider(height: 1, color: _colors.outlineVariant),
            Flexible(
              child: SingleChildScrollView(
                key: ValueKey<MangaReaderPanelTab>(_tab),
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: switch (_tab) {
                  MangaReaderPanelTab.mode => _modeTab(),
                  MangaReaderPanelTab.general => _generalTab(),
                  MangaReaderPanelTab.filter => _filterTab(),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabs(BuildContext context) {
    final tabs = <(MangaReaderPanelTab, String)>[
      (MangaReaderPanelTab.mode, _t('Reading mode', 'وضع القراءة')),
      (MangaReaderPanelTab.general, _t('General', 'عام')),
      (MangaReaderPanelTab.filter, _t('Custom filter', 'فلتر مخصص')),
    ];
    return Row(
      children: <Widget>[
        for (final (tab, label) in tabs)
          Expanded(
            child: InkWell(
              key: ValueKey<String>('manga-reader-panel-tab-${tab.name}'),
              onTap: () => setState(() => _tab = tab),
              child: Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Column(
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _tab == tab
                            ? _colors.primary
                            : _colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      height: 3,
                      width: 64,
                      decoration: BoxDecoration(
                        color: _tab == tab
                            ? _colors.primary
                            : Colors.transparent,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Building blocks, as Mihon's sheet has them ─────────────────────────

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 10),
    child: Text(
      text,
      style: TextStyle(
        color: _colors.onSurface,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _subheading(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 10),
    child: Text(
      text,
      style: TextStyle(
        color: _colors.onSurfaceVariant,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _chips<T>({
    required List<(T, String)> options,
    required bool Function(T) isSelected,
    required String keyPrefix,
    required String Function(T) keyOf,
    required ValueChanged<T> onSelected,
  }) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: <Widget>[
      for (final (value, label) in options)
        FilterChip(
          key: ValueKey<String>('manga-reader-$keyPrefix-${keyOf(value)}'),
          label: Text(label),
          selected: isSelected(value),
          showCheckmark: false,
          onSelected: (_) => onSelected(value),
        ),
    ],
  );

  Widget _check({
    required String keyName,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => CheckboxListTile(
    key: ValueKey<String>('manga-reader-switch-$keyName'),
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(label, style: const TextStyle(fontSize: 15)),
    value: value,
    onChanged: (next) => onChanged(next ?? false),
  );

  /// Mihon's slider row: the name and the value above, the slider under.
  Widget _slider({
    required String keyName,
    required String label,
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label, style: const TextStyle(fontSize: 15))),
            Text(
              valueLabel,
              style: TextStyle(fontSize: 14, color: _colors.onSurfaceVariant),
            ),
          ],
        ),
        Slider(
          key: ValueKey<String>('manga-reader-slider-$keyName'),
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions ?? (max - min).round(),
          onChanged: onChanged,
        ),
      ],
    ),
  );

  // ── Reading mode ───────────────────────────────────────────────────────

  String _orientationLabel(MangaReaderOrientation value) => switch (value) {
    MangaReaderOrientation.free => _t('Free', 'حر'),
    MangaReaderOrientation.portrait => _t('Portrait', 'طولي'),
    MangaReaderOrientation.landscape => _t('Landscape', 'عرضي'),
    MangaReaderOrientation.lockedPortrait => _t('Locked portrait', 'طولي مقفل'),
    MangaReaderOrientation.lockedLandscape => _t(
      'Locked landscape',
      'عرضي مقفل',
    ),
    MangaReaderOrientation.reversePortrait => _t(
      'Reverse portrait',
      'طولي مقلوب',
    ),
  };

  Widget _modeTab() {
    final settings = widget.settings;
    final mode = widget.mode;
    final strip = mode.isContinuous;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _heading(_t('For this series', 'لهذه السلسلة')),
        _subheading(_t('Reading mode', 'وضع القراءة')),
        _chips<MangaReaderMode?>(
          options: <(MangaReaderMode?, String)>[
            if (widget.onDefaultMode != null)
              (null, _t('Default', 'الافتراضي')),
            for (final value in MangaReaderMode.values)
              (value, mangaReaderModeName(value, arabic: _ar)),
          ],
          isSelected: (value) => value == null
              ? widget.modeIsDefault
              : !widget.modeIsDefault && value == mode,
          keyPrefix: 'choice-mode',
          keyOf: (value) => value?.name ?? 'default',
          onSelected: (value) {
            if (value == null) {
              widget.onDefaultMode?.call();
            } else if (value != mode || widget.modeIsDefault) {
              widget.onMode(value);
            }
          },
        ),
        if (widget.onOrientation != null) ...<Widget>[
          _subheading(_t('Rotation', 'دوران الشاشة')),
          _chips<MangaReaderOrientation?>(
            options: <(MangaReaderOrientation?, String)>[
              (null, _t('Default', 'الافتراضي')),
              for (final value in MangaReaderOrientation.values)
                (value, _orientationLabel(value)),
            ],
            isSelected: (value) => value == widget.orientation,
            keyPrefix: 'orientation',
            keyOf: (value) => value?.name ?? 'default',
            onSelected: (value) => widget.onOrientation?.call(value),
          ),
        ],
        _heading(
          strip ? _t('Long strip', 'شريط طويل') : _t('Pager', 'الصفحات'),
        ),
        // Tap zones are for touch; a computer turns pages with the wheel and
        // the keys.
        if (widget.touchDevice) ...<Widget>[
          _subheading(_t('Tap zones', 'مناطق اللمس')),
          _chips<int>(
            options: <(int, String)>[
              (0, _t('Default', 'الافتراضي')),
              (1, _t('L shaped', 'حرف L')),
              (2, _t('Kindle-ish', 'مثل كيندل')),
              (3, _t('Edge', 'الحواف')),
              (4, _t('Right and Left', 'يمين ويسار')),
              (5, _t('Disabled', 'معطل')),
            ],
            isSelected: (value) => settings.navigationLayout == value,
            keyPrefix: 'tap-zones',
            keyOf: (value) => '$value',
            onSelected: (value) =>
                _update((s) => s.copyWith(navigationLayout: value)),
          ),
          _subheading(_t('Invert tap zones', 'عكس مناطق اللمس')),
          _chips<int>(
            options: <(int, String)>[
              (0, _t('None', 'بدون')),
              (1, _t('Horizontal', 'أفقي')),
              (2, _t('Vertical', 'عمودي')),
              (3, _t('Both', 'كلاهما')),
            ],
            isSelected: (value) => settings.tappingInversion == value,
            keyPrefix: 'invert-taps',
            keyOf: (value) => '$value',
            onSelected: (value) =>
                _update((s) => s.copyWith(tappingInversion: value)),
          ),
        ],
        if (strip) ..._stripOptions(settings) else ..._pagerOptions(settings),
      ],
    );
  }

  List<Widget> _stripOptions(MangaReaderSettings settings) => <Widget>[
    _slider(
      keyName: 'side-padding',
      label: _t('Side padding', 'الهامش الجانبي'),
      value: settings.webtoonSidePadding.toDouble(),
      min: 0,
      max: 25,
      divisions: 5,
      valueLabel: '${settings.webtoonSidePadding}%',
      onChanged: (value) =>
          _update((s) => s.copyWith(webtoonSidePadding: value.round())),
    ),
    _check(
      keyName: 'crop',
      label: _t('Crop borders', 'قص الحواف'),
      value: settings.cropBorders,
      onChanged: (value) => _update((s) => s.copyWith(cropBorders: value)),
    ),
    _check(
      keyName: 'split-wide',
      label: _t('Split wide pages', 'تقسيم الصفحات العريضة'),
      value: settings.splitWidePages,
      onChanged: (value) => _update((s) => s.copyWith(splitWidePages: value)),
    ),
    _check(
      keyName: 'rotate-wide',
      label: _t('Rotate wide pages to fit', 'تدوير الصفحات العريضة لتناسب'),
      value: settings.dualPageRotateToFit,
      onChanged: (value) =>
          _update((s) => s.copyWith(dualPageRotateToFit: value)),
    ),
    _check(
      keyName: 'double-tap-zoom',
      label: _t('Double tap to zoom', 'نقرتان للتكبير'),
      value: settings.webtoonDoubleTapZoomEnabled,
      onChanged: (value) =>
          _update((s) => s.copyWith(webtoonDoubleTapZoomEnabled: value)),
    ),
    _check(
      keyName: 'disable-zoom-out',
      label: _t('Disable zoom out', 'تعطيل التصغير'),
      value: settings.webtoonDisableZoomOut,
      onChanged: (value) =>
          _update((s) => s.copyWith(webtoonDisableZoomOut: value)),
    ),
    _check(
      keyName: 'page-gaps',
      label: _t('Gaps between pages', 'فواصل بين الصفحات'),
      value: settings.showPageGaps,
      onChanged: (value) => _update((s) => s.copyWith(showPageGaps: value)),
    ),
  ];

  List<Widget> _pagerOptions(MangaReaderSettings settings) => <Widget>[
    _subheading(_t('Scale type', 'مقياس الصورة')),
    _chips<MangaReaderScaleType>(
      options: <(MangaReaderScaleType, String)>[
        (MangaReaderScaleType.fitScreen, _t('Fit screen', 'ملء الشاشة')),
        (MangaReaderScaleType.stretch, _t('Stretch', 'تمديد')),
        (MangaReaderScaleType.fitWidth, _t('Fit width', 'ملاءمة العرض')),
        (MangaReaderScaleType.fitHeight, _t('Fit height', 'ملاءمة الارتفاع')),
        (
          MangaReaderScaleType.originalSize,
          _t('Original size', 'الحجم الأصلي'),
        ),
        (MangaReaderScaleType.smartFit, _t('Smart fit', 'ملاءمة ذكية')),
      ],
      isSelected: (value) => settings.scaleType == value,
      keyPrefix: 'choice-fit',
      keyOf: (value) => value.name,
      onSelected: (value) => _update((s) => s.copyWith(scaleType: value)),
    ),
    _subheading(_t('Zoom start position', 'موضع بدء التكبير')),
    _chips<int>(
      options: <(int, String)>[
        (0, _t('Left', 'اليسار')),
        (1, _t('Right', 'اليمين')),
        (2, _t('Center', 'الوسط')),
      ],
      isSelected: (value) => settings.zoomStartPosition == value,
      keyPrefix: 'zoom-start',
      keyOf: (value) => '$value',
      onSelected: (value) =>
          _update((s) => s.copyWith(zoomStartPosition: value)),
    ),
    const SizedBox(height: 8),
    _check(
      keyName: 'crop',
      label: _t('Crop borders', 'قص الحواف'),
      value: settings.cropBorders,
      onChanged: (value) => _update((s) => s.copyWith(cropBorders: value)),
    ),
    _check(
      keyName: 'landscape-zoom',
      label: _t('Zoom landscape image', 'تكبير الصور العريضة'),
      value: settings.landscapeZoom,
      onChanged: (value) => _update((s) => s.copyWith(landscapeZoom: value)),
    ),
    _check(
      keyName: 'navigate-pan',
      label: _t(
        'Pan wide images when tapping',
        'تحريك الصور العريضة عند النقر',
      ),
      value: settings.navigateToPan,
      onChanged: (value) => _update((s) => s.copyWith(navigateToPan: value)),
    ),
    _check(
      keyName: 'double-page',
      label: _t('Two pages side by side', 'صفحتان جنبًا إلى جنب'),
      value: widget.doublePage,
      onChanged: widget.onDoublePage,
    ),
    _check(
      keyName: 'split-wide',
      label: _t('Split wide pages', 'تقسيم الصفحات العريضة'),
      value: settings.splitWidePages,
      onChanged: (value) => _update((s) => s.copyWith(splitWidePages: value)),
    ),
    if (settings.splitWidePages || widget.doublePage)
      _check(
        keyName: 'invert-double',
        label: _t('Invert split pages', 'عكس ترتيب الصفحات المقسومة'),
        value: settings.dualPageInvert,
        onChanged: (value) => _update((s) => s.copyWith(dualPageInvert: value)),
      ),
    _check(
      keyName: 'rotate-wide',
      label: _t('Rotate wide pages to fit', 'تدوير الصفحات العريضة لتناسب'),
      value: settings.dualPageRotateToFit,
      onChanged: (value) =>
          _update((s) => s.copyWith(dualPageRotateToFit: value)),
    ),
    if (settings.dualPageRotateToFit)
      _check(
        keyName: 'rotate-wide-invert',
        label: _t(
          'Flip orientation of rotated pages',
          'قلب اتجاه الصفحات المدورة',
        ),
        value: settings.dualPageRotateToFitInvert,
        onChanged: (value) =>
            _update((s) => s.copyWith(dualPageRotateToFitInvert: value)),
      ),
  ];

  // ── General ────────────────────────────────────────────────────────────

  Widget _generalTab() {
    final settings = widget.settings;
    const navigatorModes = <MangaReaderMode>[
      MangaReaderMode.pagedLtr,
      MangaReaderMode.pagedRtl,
      MangaReaderMode.vertical,
      MangaReaderMode.webtoon,
      MangaReaderMode.verticalContinuous,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _heading(_t('Background color', 'لون الخلفية')),
        _chips<MangaReaderBackground>(
          options: <(MangaReaderBackground, String)>[
            (MangaReaderBackground.black, _t('Black', 'أسود')),
            (MangaReaderBackground.grey, _t('Gray', 'رمادي')),
            (MangaReaderBackground.white, _t('White', 'أبيض')),
            (MangaReaderBackground.automatic, _t('Auto', 'تلقائي')),
          ],
          isSelected: (value) => settings.background == value,
          keyPrefix: 'choice-background',
          keyOf: (value) => value.name,
          onSelected: (value) => _update((s) => s.copyWith(background: value)),
        ),
        const SizedBox(height: 8),
        _check(
          keyName: 'page-number',
          label: _t('Show page number', 'إظهار رقم الصفحة'),
          value: settings.showPageNumber,
          onChanged: (value) =>
              _update((s) => s.copyWith(showPageNumber: value)),
        ),
        _heading(
          _t('Use vertical chapter navigator in', 'استخدام المتصفح العمودي في'),
        ),
        _chips<MangaReaderMode>(
          options: <(MangaReaderMode, String)>[
            for (final value in navigatorModes)
              (value, mangaReaderModeName(value, arabic: _ar)),
          ],
          isSelected: settings.usesVerticalBar,
          keyPrefix: 'vertical-bar',
          keyOf: (value) => value.name,
          onSelected: (value) => _update((s) {
            final modes = <MangaReaderMode>{...s.verticalBarModes};
            if (!modes.remove(value)) modes.add(value);
            return s.copyWith(verticalBarModes: modes);
          }),
        ),
        const SizedBox(height: 8),
        _check(
          keyName: 'vertical-bar-left',
          label: _t(
            'Place vertical navigator on the left side',
            'وضع المتصفح العمودي على اليسار',
          ),
          value: settings.verticalBarLeft,
          onChanged: (value) =>
              _update((s) => s.copyWith(verticalBarLeft: value)),
        ),
        _slider(
          keyName: 'vertical-bar-height',
          label: _t('Vertical navigator height', 'ارتفاع المتصفح العمودي'),
          value: settings.verticalBarHeight.toDouble(),
          min: 50,
          max: 100,
          divisions: 10,
          valueLabel: '${settings.verticalBarHeight}',
          onChanged: (value) =>
              _update((s) => s.copyWith(verticalBarHeight: value.round())),
        ),
        if (widget.touchDevice) ...<Widget>[
          _check(
            keyName: 'fullscreen',
            label: _t('Fullscreen', 'ملء الشاشة'),
            value: settings.fullScreen,
            onChanged: (value) => _update((s) => s.copyWith(fullScreen: value)),
          ),
          _check(
            keyName: 'keep-on',
            label: _t('Keep screen on', 'إبقاء الشاشة مضاءة'),
            value: settings.keepScreenOn,
            onChanged: (value) =>
                _update((s) => s.copyWith(keepScreenOn: value)),
          ),
          _check(
            keyName: 'long-tap-actions',
            label: _t(
              'Show actions on long tap',
              'إظهار الإجراءات عند الضغط المطول',
            ),
            value: settings.showActionsOnLongTap,
            onChanged: (value) =>
                _update((s) => s.copyWith(showActionsOnLongTap: value)),
          ),
        ],
        _check(
          keyName: 'show-mode',
          label: _t('Show reading mode', 'إظهار وضع القراءة'),
          value: settings.showReadingMode,
          onChanged: (value) =>
              _update((s) => s.copyWith(showReadingMode: value)),
        ),
        if (widget.touchDevice)
          _check(
            keyName: 'tap-overlay',
            label: _t('Show tap zones overlay', 'إظهار مناطق اللمس عند الفتح'),
            value: settings.showNavigationOverlayOnStart,
            onChanged: (value) =>
                _update((s) => s.copyWith(showNavigationOverlayOnStart: value)),
          ),
        _check(
          keyName: 'animate',
          label: _t('Animate page transitions', 'تحريك الانتقال بين الصفحات'),
          value: settings.animatePageTransitions,
          onChanged: (value) =>
              _update((s) => s.copyWith(animatePageTransitions: value)),
        ),
        _check(
          keyName: 'flash',
          label: _t('Flash on page change', 'وميض عند تغيير الصفحة'),
          value: settings.flashOnPageChange,
          onChanged: (value) =>
              _update((s) => s.copyWith(flashOnPageChange: value)),
        ),
        if (settings.flashOnPageChange) ...<Widget>[
          _slider(
            keyName: 'flash-duration',
            label: _t('Flash duration', 'مدة الوميض'),
            value: settings.flashDurationMs.toDouble(),
            min: 50,
            max: 500,
            divisions: 9,
            valueLabel: '${settings.flashDurationMs} ms',
            onChanged: (value) =>
                _update((s) => s.copyWith(flashDurationMs: value.round())),
          ),
          _slider(
            keyName: 'flash-interval',
            label: _t('Flash every', 'الوميض كل'),
            value: settings.flashInterval.toDouble(),
            min: 1,
            max: 10,
            valueLabel: _t(
              '${settings.flashInterval} pages',
              '${settings.flashInterval} صفحات',
            ),
            onChanged: (value) =>
                _update((s) => s.copyWith(flashInterval: value.round())),
          ),
          _subheading(_t('Flash with', 'لون الوميض')),
          _chips<int>(
            options: <(int, String)>[
              (0, _t('Black', 'أسود')),
              (1, _t('White', 'أبيض')),
              (2, _t('Dim white', 'أبيض خافت')),
            ],
            isSelected: (value) => settings.flashColor == value,
            keyPrefix: 'flash-color',
            keyOf: (value) => '$value',
            onSelected: (value) =>
                _update((s) => s.copyWith(flashColor: value)),
          ),
          const SizedBox(height: 8),
        ],
        if (widget.showVolumeKeys) ...<Widget>[
          _check(
            keyName: 'volume-keys',
            label: _t('Volume keys', 'أزرار الصوت'),
            value: settings.readWithVolumeKeys,
            onChanged: (value) =>
                _update((s) => s.copyWith(readWithVolumeKeys: value)),
          ),
          if (settings.readWithVolumeKeys)
            _check(
              keyName: 'volume-keys-inverted',
              label: _t('Invert volume keys', 'عكس أزرار الصوت'),
              value: settings.readWithVolumeKeysInverted,
              onChanged: (value) =>
                  _update((s) => s.copyWith(readWithVolumeKeysInverted: value)),
            ),
        ],
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey<String>('manga-reader-all-settings'),
            onPressed: widget.onOpenAllSettings,
            icon: const Icon(Icons.settings_rounded, size: 18),
            label: Text(_t('All reader settings', 'كل إعدادات القارئ')),
          ),
        ),
      ],
    );
  }

  // ── Custom filter ──────────────────────────────────────────────────────

  Widget _filterTab() {
    final settings = widget.settings;
    final argb = settings.colorFilterValue;
    int channel(int shift) => (argb >> shift) & 0xFF;
    int withChannel(int color, int shift, int value) =>
        (color & ~(0xFF << shift)) | ((value & 0xFF) << shift);
    Widget channelSlider(String keyName, String label, int shift) => _slider(
      keyName: keyName,
      label: label,
      value: channel(shift).toDouble(),
      min: 0,
      max: 255,
      valueLabel: '${channel(shift)}',
      onChanged: (value) => _update(
        (s) => s.copyWith(
          colorFilterValue: withChannel(
            s.colorFilterValue,
            shift,
            value.round(),
          ),
        ),
      ),
    );
    String blendLabel(MangaReaderColorBlend blend) => switch (blend) {
      MangaReaderColorBlend.normal => _t('Default', 'الافتراضي'),
      MangaReaderColorBlend.multiply => _t('Multiply', 'ضرب'),
      MangaReaderColorBlend.screen => _t('Screen', 'تفتيح الشاشة'),
      MangaReaderColorBlend.overlay => _t('Overlay', 'تراكب'),
      MangaReaderColorBlend.lighten => _t('Lighten', 'تفتيح'),
      MangaReaderColorBlend.darken => _t('Darken', 'تغميق'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 8),
        _check(
          keyName: 'custom-brightness',
          label: _t('Custom brightness', 'سطوع مخصص'),
          value: settings.customBrightness,
          onChanged: (value) =>
              _update((s) => s.copyWith(customBrightness: value)),
        ),
        if (settings.customBrightness)
          _slider(
            keyName: 'brightness',
            label: _t('Brightness', 'السطوع'),
            value: settings.brightness.toDouble(),
            min: -75,
            max: 0,
            valueLabel: '${settings.brightness}',
            onChanged: (value) =>
                _update((s) => s.copyWith(brightness: value.round())),
          ),
        _check(
          keyName: 'color-filter',
          label: _t('Custom color filter', 'فلتر لون مخصص'),
          value: settings.colorFilter,
          onChanged: (value) => _update((s) => s.copyWith(colorFilter: value)),
        ),
        if (settings.colorFilter) ...<Widget>[
          channelSlider('tint-r', _t('Red', 'أحمر'), 16),
          channelSlider('tint-g', _t('Green', 'أخضر'), 8),
          channelSlider('tint-b', _t('Blue', 'أزرق'), 0),
          channelSlider('tint-strength', _t('Alpha', 'الشفافية'), 24),
          _subheading(_t('Color filter blend mode', 'طريقة مزج الفلتر')),
          _chips<MangaReaderColorBlend>(
            options: <(MangaReaderColorBlend, String)>[
              for (final blend in MangaReaderColorBlend.values)
                (blend, blendLabel(blend)),
            ],
            isSelected: (value) => settings.colorFilterMode == value,
            keyPrefix: 'blend',
            keyOf: (value) => value.name,
            onSelected: (value) =>
                _update((s) => s.copyWith(colorFilterMode: value)),
          ),
          const SizedBox(height: 8),
        ],
        _check(
          keyName: 'grayscale',
          label: _t('Grayscale', 'تدرج رمادي'),
          value: settings.grayscale,
          onChanged: (value) => _update((s) => s.copyWith(grayscale: value)),
        ),
        _check(
          keyName: 'inverted',
          label: _t('Inverted', 'ألوان معكوسة'),
          value: settings.invertedColors,
          onChanged: (value) =>
              _update((s) => s.copyWith(invertedColors: value)),
        ),
      ],
    );
  }
}
