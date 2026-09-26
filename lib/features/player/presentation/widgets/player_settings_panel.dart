import 'package:flutter/material.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import 'package:animewitcher/features/player/data/anime4k.dart';

/// The desktop player's settings panel: one ⚙ button opens it above the
/// bar, and the picture and speed choices live in it as tabs instead of as a
/// row of separate buttons.
///
/// A tab is drawn only when it has something to change: the picture tab for
/// Anime4K and the picture size, the speed tab where the source can be sped
/// up. Each is also hidden by its own switch in "player controls".
class PlayerSettingsPanel extends StatefulWidget {
  const PlayerSettingsPanel({
    super.key,
    required this.showAnime4k,
    required this.anime4kMode,
    required this.onAnime4kMode,
    required this.showResize,
    required this.resizeIndex,
    required this.resizeLabels,
    required this.onResize,
    required this.showSpeed,
    required this.speed,
    required this.maxSpeed,
    required this.onSpeed,
    this.qualityLabel,
    this.loadQualityChoices,
  });

  final bool showAnime4k;
  final Anime4kMode anime4kMode;
  final ValueChanged<Anime4kMode> onAnime4kMode;

  final bool showResize;
  final int resizeIndex;
  final List<String> resizeLabels;
  final ValueChanged<int> onResize;

  final bool showSpeed;
  final double speed;
  final double maxSpeed;
  final ValueChanged<double> onSpeed;

  /// What is playing now, shown on the quality row; null hides the row.
  final String? qualityLabel;

  /// Every source the episode has, fetched when the quality list opens —
  /// the same list the picker before playback shows.
  final Future<List<PlayerPanelChoice>> Function()? loadQualityChoices;

  /// Whether the panel has anything to show; the ⚙ button is left out
  /// when it would open an empty panel.
  static bool hasContent({
    required bool showAnime4k,
    required bool showResize,
    required bool showSpeed,
    bool hasQuality = false,
  }) => showAnime4k || showResize || showSpeed || hasQuality;

  @override
  State<PlayerSettingsPanel> createState() => _PlayerSettingsPanelState();
}

enum _Tab { picture, speed }

/// A sub-list the picture tab opens from one of its rows.
enum _Sub { none, size, quality }

/// One entry in a list the panel opens: a label, whether it is the current
/// one, and what choosing it does.
class PlayerPanelChoice {
  const PlayerPanelChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.sectionLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? sectionLabel;
}

class _PlayerSettingsPanelState extends State<PlayerSettingsPanel> {
  late _Tab _tab = _tabs.first;
  _Sub _sub = _Sub.none;

  /// The quality list, fetched once per opening of the panel.
  Future<List<PlayerPanelChoice>>? _qualityFuture;

  List<_Tab> get _tabs => [
    if (widget.showAnime4k || widget.showResize || widget.qualityLabel != null)
      _Tab.picture,
    if (widget.showSpeed) _Tab.speed,
  ];

  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  void _back() => setState(() => _sub = _Sub.none);

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (tabs.isEmpty) return const SizedBox.shrink();
    if (!tabs.contains(_tab)) _tab = tabs.first;
    final accent = Theme.of(context).colorScheme.primary;
    final arabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    return Directionality(
      textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xEE141412),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: _sub != _Sub.none
              ? _buildSubList(context, accent)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        for (final tab in tabs) ...[
                          _TabLabel(
                            label: switch (tab) {
                              _Tab.picture => appText(
                                context,
                                english: 'Picture',
                                arabic: 'الصورة',
                              ),
                              _Tab.speed => appText(
                                context,
                                english: 'Speed',
                                arabic: 'السرعة',
                              ),
                            },
                            selected: tab == _tab,
                            accent: accent,
                            onTap: () => setState(() => _tab = tab),
                          ),
                          const SizedBox(width: 16),
                        ],
                      ],
                    ),
                    Divider(
                      color: Colors.white.withValues(alpha: 0.1),
                      height: 18,
                    ),
                    ...switch (_tab) {
                      _Tab.picture => [
                        if (widget.showAnime4k) ...[
                          _RowLabel('Anime4K'),
                          _Chips<Anime4kMode>(
                            values: [
                              for (final mode in Anime4kMode.values)
                                if (mode != Anime4kMode.off) mode,
                              Anime4kMode.off,
                            ],
                            selected: widget.anime4kMode,
                            label: (mode) => mode == Anime4kMode.off
                                ? appText(
                                    context,
                                    english: 'Off',
                                    arabic: 'إيقاف',
                                  )
                                : mode.label,
                            accent: accent,
                            onSelected: widget.onAnime4kMode,
                          ),
                          const SizedBox(height: 12),
                        ],
                        // Size and quality are a row each — the name, the current
                        // value and › — opening a short list of their own.
                        if (widget.showResize)
                          _ValueRow(
                            label: appText(
                              context,
                              english: 'Size',
                              arabic: 'الحجم',
                            ),
                            value:
                                widget.resizeLabels[widget.resizeIndex.clamp(
                                  0,
                                  widget.resizeLabels.length - 1,
                                )],
                            onTap: () => setState(() => _sub = _Sub.size),
                          ),
                        if (widget.qualityLabel != null)
                          _ValueRow(
                            label: appText(
                              context,
                              english: 'Quality',
                              arabic: 'الجودة',
                            ),
                            value: widget.qualityLabel!,
                            onTap: () => setState(() => _sub = _Sub.quality),
                          ),
                      ],
                      _Tab.speed => [
                        _Chips<double>(
                          values: [
                            for (final speed in _speeds)
                              if (speed <= widget.maxSpeed + 0.001) speed,
                          ],
                          selected: widget.speed,
                          label: (speed) =>
                              '${speed.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}x',
                          accent: accent,
                          onSelected: widget.onSpeed,
                        ),
                      ],
                    },
                  ],
                ),
        ),
      ),
    );
  }
}

extension on _PlayerSettingsPanelState {
  /// The list a row opens: a way back, then each option with the current
  /// one ticked. Choosing one applies it and returns to the rows.
  Widget _buildSubList(BuildContext context, Color accent) {
    final (title, choices) = switch (_sub) {
      _Sub.size => (
        appText(context, english: 'Size', arabic: 'الحجم'),
        <PlayerPanelChoice>[
          for (var i = 0; i < widget.resizeLabels.length; i++)
            PlayerPanelChoice(
              label: widget.resizeLabels[i],
              selected: i == widget.resizeIndex,
              onTap: () => widget.onResize(i),
            ),
        ],
      ),
      _ => (appText(context, english: 'Quality', arabic: 'الجودة'), null),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _back(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Icon(
                  Icons.chevron_left_rounded,
                  color: Colors.white70,
                  size: 20,
                  textDirection: TextDirection.ltr,
                ),
                const SizedBox(width: 4),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        Divider(color: Colors.white.withValues(alpha: 0.1), height: 14),
        if (choices != null)
          _choiceList(choices, accent)
        else
          FutureBuilder<List<PlayerPanelChoice>>(
            future: _qualityFuture ??=
                widget.loadQualityChoices?.call() ??
                Future.value(const <PlayerPanelChoice>[]),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(18),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                );
              }
              final loaded = snapshot.data ?? const <PlayerPanelChoice>[];
              if (loaded.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    appText(
                      context,
                      english: 'No other sources for this episode',
                      arabic: 'لا توجد مصادر أخرى لهذه الحلقة',
                    ),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                );
              }
              return _choiceList(loaded, accent);
            },
          ),
      ],
    );
  }

  Widget _choiceList(List<PlayerPanelChoice> list, Color accent) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        // A phone on its side is short: the list scrolls within it.
        maxHeight: (MediaQuery.sizeOf(context).height * 0.4).clamp(
          120.0,
          260.0,
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < list.length; index++) ...[
              if (list[index].sectionLabel != null &&
                  (index == 0 ||
                      list[index - 1].sectionLabel !=
                          list[index].sectionLabel))
                Padding(
                  padding: EdgeInsets.only(
                    top: index == 0 ? 2 : 12,
                    bottom: 4,
                  ),
                  child: Text(
                    list[index].sectionLabel!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  list[index].onTap();
                  _back();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      if (list[index].sectionLabel != null) ...[
                        Icon(
                          Icons.play_circle_outline_rounded,
                          color: list[index].selected
                              ? accent
                              : Colors.white70,
                          size: 24,
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          list[index].label,
                          style: TextStyle(
                            color: list[index].selected
                                ? accent
                                : Colors.white,
                            fontSize: 13,
                            fontWeight: list[index].selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (list[index].selected &&
                          list[index].sectionLabel == null)
                        Icon(Icons.check_rounded, color: accent, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A setting's name, its current value and ›, opening its list.
class _ValueRow extends StatelessWidget {
  const _ValueRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Directionality.of(context) == TextDirection.rtl
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.65),
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? accent : Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _RowLabel extends StatelessWidget {
  const _RowLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Chips<T> extends StatelessWidget {
  const _Chips({
    required this.values,
    required this.selected,
    required this.label,
    required this.accent,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final Color accent;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final value in values)
          InkWell(
            onTap: () => onSelected(value),
            borderRadius: BorderRadius.circular(99),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: value == selected
                    ? accent
                    : Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                label(value),
                style: TextStyle(
                  color: value == selected ? Colors.black : Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A key's name in a small outlined box, drawn under a desktop player
/// button so its shortcut can be learned by looking.
class PlayerKeyHint extends StatelessWidget {
  const PlayerKeyHint(this.keyName, {super.key});

  final String keyName;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
      ),
      child: Text(
        keyName,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.75),
          fontSize: 9,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
    );
  }
}
