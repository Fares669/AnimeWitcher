import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../manga_reader_settings.dart';
import '../manga_reader_settings_provider.dart';

class MangaReaderQuickSettings extends ConsumerStatefulWidget {
  const MangaReaderQuickSettings({
    super.key,
    required this.currentMode,
    required this.mangaId,
    required this.onModeChanged,
    required this.onAutoScrollChanged,
    required this.onOpenAllSettings,
  });

  final MangaReaderMode currentMode;
  final String mangaId;
  final ValueChanged<MangaReaderMode> onModeChanged;
  final void Function(bool enabled, double speed) onAutoScrollChanged;
  final VoidCallback onOpenAllSettings;

  @override
  ConsumerState<MangaReaderQuickSettings> createState() =>
      _MangaReaderQuickSettingsState();
}

class _MangaReaderQuickSettingsState
    extends ConsumerState<MangaReaderQuickSettings> {
  late MangaReaderMode _mode = widget.currentMode;

  bool get _continuous => _mode.isContinuous;

  String _t(String en, String ar) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar'
          ? ar
          : en;

  String _modeLabel(MangaReaderMode mode) => switch (mode) {
        MangaReaderMode.vertical => _t('Vertical', 'عمودي'),
        MangaReaderMode.pagedLtr => _t('Left to right', 'من اليسار لليمين'),
        MangaReaderMode.pagedRtl => _t('Right to left', 'من اليمين لليسار'),
        MangaReaderMode.verticalContinuous =>
          _t('Vertical continuous', 'عمودي مستمر'),
        MangaReaderMode.webtoon => _t('Webtoon', 'ويب تون'),
        MangaReaderMode.horizontalContinuous =>
          _t('Horizontal continuous', 'أفقي مستمر'),
        MangaReaderMode.horizontalContinuousRtl =>
          _t('Horizontal continuous (RTL)', 'أفقي مستمر (RTL)'),
      };

  String _scaleLabel(MangaReaderScaleType value) => switch (value) {
        MangaReaderScaleType.fitScreen => _t('Fit screen', 'ملاءمة الشاشة'),
        MangaReaderScaleType.stretch => _t('Stretch', 'تمديد'),
        MangaReaderScaleType.fitWidth => _t('Fit width', 'ملاءمة العرض'),
        MangaReaderScaleType.fitHeight => _t('Fit height', 'ملاءمة الارتفاع'),
        MangaReaderScaleType.originalSize => _t('Original size', 'الحجم الأصلي'),
        MangaReaderScaleType.smartFit => _t('Smart fit', 'ملاءمة ذكية'),
      };

  String _tapInversionLabel(int value) => switch (value) {
        1 => _t('Horizontal', 'أفقي'),
        2 => _t('Vertical', 'عمودي'),
        3 => _t('Both', 'كلاهما'),
        _ => _t('None', 'بدون'),
      };

  String _zoomStartLabel(int value) => switch (value) {
        0 => _t('Left', 'يسار'),
        1 => _t('Right', 'يمين'),
        _ => _t('Center', 'وسط'),
      };

  Future<void> _update(
    MangaReaderSettings Function(MangaReaderSettings value) transform,
  ) =>
      ref.read(mangaReaderSettingsProvider.notifier).update(transform);

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(mangaReaderSettingsProvider);
    return DefaultTabController(
      length: 3,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: Column(
          children: <Widget>[
            TabBar(
              tabs: <Tab>[
                Tab(text: _t('Reading', 'القراءة')),
                Tab(text: _t('General', 'عام')),
                Tab(text: _t('Filter', 'الفلتر')),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _readingTab(settings),
                  _generalTab(settings),
                  _filterTab(settings),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readingTab(MangaReaderSettings settings) {
    final auto = settings.autoScrollForManga(widget.mangaId);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        ListTile(
          title: Text(_t('Reading mode', 'وضع القراءة')),
          trailing: DropdownButton<MangaReaderMode>(
            value: _mode,
            items: <DropdownMenuItem<MangaReaderMode>>[
              for (final mode in MangaReaderMode.values)
                DropdownMenuItem(
                  value: mode,
                  child: Text(_modeLabel(mode)),
                ),
            ],
            onChanged: (mode) {
              if (mode == null || mode == _mode) return;
              setState(() => _mode = mode);
              widget.onModeChanged(mode);
            },
          ),
        ),
        SwitchListTile(
          title: Text(_t('Crop borders', 'قص الحواف')),
          value: settings.cropBorders,
          onChanged: (value) =>
              _update((s) => s.copyWith(cropBorders: value)),
        ),
        if (_continuous) ...<Widget>[
          SwitchListTile(
            title: Text(_t('Disable zoom out', 'تعطيل التصغير')),
            value: settings.webtoonDisableZoomOut,
            onChanged: (value) =>
                _update((s) => s.copyWith(webtoonDisableZoomOut: value)),
          ),
          SwitchListTile(
            title: Text(_t('Double-tap zoom', 'تكبير بالنقر المزدوج')),
            value: settings.webtoonDoubleTapZoomEnabled,
            onChanged: (value) => _update(
              (s) => s.copyWith(webtoonDoubleTapZoomEnabled: value),
            ),
          ),
        ] else
          SwitchListTile(
            title: Text(_t('Navigate while zoomed', 'التنقل أثناء التكبير')),
            subtitle: Text(
              _t(
                'Pan to the edge before turning the page',
                'حرّك الصورة للحافة قبل الانتقال للصفحة',
              ),
            ),
            value: settings.navigateToPan,
            onChanged: (value) =>
                _update((s) => s.copyWith(navigateToPan: value)),
          ),
        SwitchListTile(
          title: Text(_t('Split wide pages', 'تقسيم الصفحات العريضة')),
          value: settings.splitWidePages,
          onChanged: (value) =>
              _update((s) => s.copyWith(splitWidePages: value)),
        ),
        if (settings.splitWidePages)
          SwitchListTile(
            title: Text(_t('Invert split order', 'عكس ترتيب التقسيم')),
            value: settings.dualPageInvert,
            onChanged: (value) =>
                _update((s) => s.copyWith(dualPageInvert: value)),
          ),
        SwitchListTile(
          title: Text(_t('Rotate wide pages to fit', 'تدوير الصفحات العريضة')),
          value: settings.dualPageRotateToFit,
          onChanged: (value) =>
              _update((s) => s.copyWith(dualPageRotateToFit: value)),
        ),
        if (settings.dualPageRotateToFit)
          SwitchListTile(
            title: Text(_t('Invert rotation', 'عكس اتجاه التدوير')),
            value: settings.dualPageRotateToFitInvert,
            onChanged: (value) => _update(
              (s) => s.copyWith(dualPageRotateToFitInvert: value),
            ),
          ),
        SwitchListTile(
          title: Text(_t('Single first page', 'الصفحة الأولى منفردة')),
          value: settings.doublePageSingleFirstPage,
          onChanged: (value) => _update(
            (s) => s.copyWith(doublePageSingleFirstPage: value),
          ),
        ),
        SwitchListTile(
          title: Text(_t('Automatic double page', 'صفحتان تلقائيًا')),
          value: settings.doublePageAuto,
          onChanged: (value) =>
              _update((s) => s.copyWith(doublePageAuto: value)),
        ),
        if (!_continuous)
          SwitchListTile(
            title: Text(_t('Landscape zoom', 'تكبير الصفحات العريضة')),
            value: settings.landscapeZoom,
            onChanged: (value) =>
                _update((s) => s.copyWith(landscapeZoom: value)),
          ),
        if (!_continuous && settings.landscapeZoom)
          ListTile(
            title: Text(_t('Zoom start position', 'بداية التكبير')),
            trailing: DropdownButton<int>(
              value: settings.zoomStartPosition,
              items: <DropdownMenuItem<int>>[
                for (final value in const <int>[0, 1, 2])
                  DropdownMenuItem(
                    value: value,
                    child: Text(_zoomStartLabel(value)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  unawaited(
                    _update((s) => s.copyWith(zoomStartPosition: value)),
                  );
                }
              },
            ),
          ),
        SwitchListTile(
          title: Text(_t('Use page tap zones', 'استخدام مناطق النقر')),
          value: settings.usePageTapZones,
          onChanged: (value) =>
              _update((s) => s.copyWith(usePageTapZones: value)),
        ),
        SwitchListTile(
          title: Text(_t('Keep screen on', 'إبقاء الشاشة مضاءة')),
          value: settings.keepScreenOn,
          onChanged: (value) =>
              _update((s) => s.copyWith(keepScreenOn: value)),
        ),
        if (_continuous)
          SwitchListTile(
            title: Text(_t('Show page gaps', 'إظهار الفواصل بين الصفحات')),
            value: settings.showPageGaps,
            onChanged: (value) =>
                _update((s) => s.copyWith(showPageGaps: value)),
          ),
        if (_continuous)
          ListTile(
            title: Text(
              '${_t('Side padding', 'الهوامش الجانبية')}: '
              '${settings.webtoonSidePadding}%',
            ),
            subtitle: Slider(
              min: 0,
              max: 50,
              divisions: 50,
              value: settings.webtoonSidePadding.toDouble(),
              onChanged: (value) => unawaited(
                _update(
                  (s) => s.copyWith(webtoonSidePadding: value.round()),
                ),
              ),
            ),
          ),
        if (_continuous)
          SwitchListTile(
            secondary: Icon(
              auto.enabled ? Icons.timer_rounded : Icons.timer_outlined,
            ),
            title: Text(_t('Auto scroll', 'التمرير التلقائي')),
            value: auto.enabled,
            onChanged: (enabled) =>
                widget.onAutoScrollChanged(enabled, auto.speed),
          ),
        if (_continuous && auto.enabled)
          ListTile(
            title: Text(
              '${_t('Auto-scroll speed', 'سرعة التمرير')}: '
              '${auto.speed.toStringAsFixed(0)}',
            ),
            subtitle: Slider(
              min: 2,
              max: 30,
              divisions: 28,
              value: auto.speed.clamp(2, 30),
              onChanged: (speed) =>
                  widget.onAutoScrollChanged(true, speed),
            ),
          ),
      ],
    );
  }

  Widget _generalTab(MangaReaderSettings settings) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        ListTile(
          title: Text(_t('Scale type', 'طريقة الملاءمة')),
          trailing: DropdownButton<MangaReaderScaleType>(
            value: settings.scaleType,
            items: <DropdownMenuItem<MangaReaderScaleType>>[
              for (final value in MangaReaderScaleType.values)
                DropdownMenuItem(
                  value: value,
                  child: Text(_scaleLabel(value)),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                unawaited(_update((s) => s.copyWith(scaleType: value)));
              }
            },
          ),
        ),
        ListTile(
          title: Text(
            '${_t('Navigation layout', 'تخطيط التنقل')}: '
            '${settings.navigationLayout}',
          ),
          subtitle: Slider(
            min: 0,
            max: 5,
            divisions: 5,
            value: settings.navigationLayout.toDouble(),
            onChanged: (value) => unawaited(
              _update((s) => s.copyWith(navigationLayout: value.round())),
            ),
          ),
        ),
        ListTile(
          title: Text(_t('Tap inversion', 'عكس مناطق النقر')),
          trailing: DropdownButton<int>(
            value: settings.tappingInversion,
            items: <DropdownMenuItem<int>>[
              for (final value in const <int>[0, 1, 2, 3])
                DropdownMenuItem(
                  value: value,
                  child: Text(_tapInversionLabel(value)),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                unawaited(
                  _update((s) => s.copyWith(tappingInversion: value)),
                );
              }
            },
          ),
        ),
        SwitchListTile(
          title: Text(_t('Flash on page change', 'وميض عند تغيير الصفحة')),
          value: settings.flashOnPageChange,
          onChanged: (value) =>
              _update((s) => s.copyWith(flashOnPageChange: value)),
        ),
        if (settings.flashOnPageChange) ...<Widget>[
          ListTile(
            title: Text(_t('Flash color', 'لون الوميض')),
            trailing: DropdownButton<int>(
              value: settings.flashColor,
              items: <DropdownMenuItem<int>>[
                DropdownMenuItem(value: 0, child: Text(_t('Black', 'أسود'))),
                DropdownMenuItem(value: 1, child: Text(_t('White', 'أبيض'))),
                DropdownMenuItem(
                  value: 2,
                  child: Text(_t('Soft white', 'أبيض خفيف')),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  unawaited(_update((s) => s.copyWith(flashColor: value)));
                }
              },
            ),
          ),
          ListTile(
            title: Text(
              '${_t('Flash interval', 'فاصل الوميض')}: '
              '${settings.flashInterval}',
            ),
            subtitle: Slider(
              min: 1,
              max: 10,
              divisions: 9,
              value: settings.flashInterval.toDouble(),
              onChanged: (value) => unawaited(
                _update((s) => s.copyWith(flashInterval: value.round())),
              ),
            ),
          ),
          ListTile(
            title: Text(
              '${_t('Flash duration', 'مدة الوميض')}: '
              '${settings.flashDurationMs} ms',
            ),
            subtitle: Slider(
              min: 50,
              max: 500,
              divisions: 9,
              value: settings.flashDurationMs.toDouble(),
              onChanged: (value) => unawaited(
                _update((s) => s.copyWith(flashDurationMs: value.round())),
              ),
            ),
          ),
        ],
        SwitchListTile(
          title: Text(
            _t(
              'Show navigation overlay on start',
              'إظهار مخطط التنقل عند البدء',
            ),
          ),
          value: settings.showNavigationOverlayOnStart,
          onChanged: (value) => _update(
            (s) => s.copyWith(showNavigationOverlayOnStart: value),
          ),
        ),
        ListTile(
          title: Text(
            '${_t('Reader hide threshold', 'عتبة إخفاء الأدوات')}: '
            '${settings.readerHideThreshold}',
          ),
          subtitle: Slider(
            min: 0,
            max: 3,
            divisions: 3,
            value: settings.readerHideThreshold.toDouble(),
            onChanged: (value) => unawaited(
              _update((s) => s.copyWith(readerHideThreshold: value.round())),
            ),
          ),
        ),
        SwitchListTile(
          title: Text(_t('Full screen', 'ملء الشاشة')),
          value: settings.fullScreen,
          onChanged: (value) =>
              _update((s) => s.copyWith(fullScreen: value)),
        ),
        SwitchListTile(
          title: Text(_t('Show page number', 'إظهار رقم الصفحة')),
          value: settings.showPageNumber,
          onChanged: (value) =>
              _update((s) => s.copyWith(showPageNumber: value)),
        ),
        SwitchListTile(
          title: Text(
            _t('Animate page transitions', 'تحريك انتقال الصفحات'),
          ),
          value: settings.animatePageTransitions,
          onChanged: (value) => _update(
            (s) => s.copyWith(animatePageTransitions: value),
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.settings_rounded),
          title: Text(_t('All reader settings', 'كل إعدادات القارئ')),
          onTap: widget.onOpenAllSettings,
        ),
      ],
    );
  }

  Widget _filterTab(MangaReaderSettings settings) {
    Widget slider({
      required String title,
      required double value,
      required double min,
      required double max,
      required double reset,
      required ValueChanged<double> onChanged,
    }) {
      return ListTile(
        title: Row(
          children: <Widget>[
            Expanded(child: Text(title)),
            Text(value.toStringAsFixed(1)),
            if ((value - reset).abs() > .01)
              IconButton(
                tooltip: _t('Reset', 'إعادة ضبط'),
                onPressed: () => onChanged(reset),
                icon: const Icon(Icons.replay_rounded, size: 18),
              ),
          ],
        ),
        subtitle: Slider(
          min: min,
          max: max,
          value: value.clamp(min, max),
          onChanged: onChanged,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        SwitchListTile(
          title: Text(_t('Invert colors', 'عكس الألوان')),
          value: settings.invertColors,
          onChanged: (value) =>
              _update((s) => s.copyWith(invertColors: value)),
        ),
        SwitchListTile(
          title: Text(_t('Grayscale', 'تدرج رمادي')),
          value: settings.grayscale,
          onChanged: (value) =>
              _update((s) => s.copyWith(grayscale: value)),
        ),
        slider(
          title: _t('Brightness', 'السطوع'),
          value: settings.brightness,
          min: -1,
          max: 1,
          reset: 0,
          onChanged: (value) =>
              unawaited(_update((s) => s.copyWith(brightness: value))),
        ),
        slider(
          title: _t('Contrast', 'التباين'),
          value: settings.contrast,
          min: 0,
          max: 2,
          reset: 1,
          onChanged: (value) =>
              unawaited(_update((s) => s.copyWith(contrast: value))),
        ),
        slider(
          title: _t('Saturation', 'التشبع'),
          value: settings.saturation,
          min: 0,
          max: 2,
          reset: 1,
          onChanged: (value) =>
              unawaited(_update((s) => s.copyWith(saturation: value))),
        ),
        const Divider(),
        SwitchListTile(
          title: Text(_t('Custom color filter', 'فلتر لون مخصص')),
          value: settings.enableCustomColorFilter,
          onChanged: (value) => _update(
            (s) => s.copyWith(enableCustomColorFilter: value),
          ),
        ),
        if (settings.enableCustomColorFilter)
          ListTile(
            title: Text(_t('Blend mode', 'وضع المزج')),
            trailing: DropdownButton<MangaReaderColorBlendMode>(
              value: settings.colorFilterBlendMode,
              items: <DropdownMenuItem<MangaReaderColorBlendMode>>[
                for (final mode in MangaReaderColorBlendMode.values)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(mode.name),
                  ),
              ],
              onChanged: (mode) {
                if (mode != null) {
                  unawaited(
                    _update((s) => s.copyWith(colorFilterBlendMode: mode)),
                  );
                }
              },
            ),
          ),
      ],
    );
  }
}
