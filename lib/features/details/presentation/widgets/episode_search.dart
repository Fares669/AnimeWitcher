/// Finding one episode in a list of a thousand.
///
/// A long-running series runs to four figures, and scrolling to episode 847
/// is not a thing anyone should have to do. The control is a single glyph
/// until it is asked for, so a twelve-episode season is not made to carry a
/// search box it will never need.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/utils/digit_normalization.dart';

import '../../../../core/utils/localized_text.dart';
import '../../../../shared/widgets/apple_liquid_glass.dart';
import 'details_hero_actions.dart';

/// What the viewer is looking for, for as long as the page is open.
///
/// Reset when a details page opens: a number typed for one series means
/// nothing on the next, and arriving at an anime already filtered down to
/// four episodes reads as a broken list rather than a remembered search.
final ValueNotifier<String> episodeSearchQuery = ValueNotifier<String>('');

/// Converts localized digits to ASCII so a typed episode number can match.
String normalizeDigits(String input) => normalizeLocalizedDigits(input);

/// Whether one episode answers [query].
///
/// Digits match the episode number from its start — "12" finds 12, and also
/// 120 and 1200, which is what someone typing their way toward a number in a
/// long series wants to see. Anything else is matched against the title, so a
/// half-remembered name works too.
bool episodeMatchesQuery({
  required int number,
  required String name,
  required String query,
}) => EpisodeSearchQuery(query).matches(number, name);

/// A normalized query shared by every row scanned for one search.
class EpisodeSearchQuery {
  EpisodeSearchQuery(String query)
    : _needle = normalizeDigits(query).trim().toLowerCase();

  static final _digits = RegExp(r'^\d+$');
  final String _needle;
  late final bool _numberPrefix = _digits.hasMatch(_needle);

  bool get isEmpty => _needle.isEmpty;

  bool matches(int number, String name) {
    if (isEmpty) return true;
    return _numberPrefix
        ? number.toString().startsWith(_needle)
        : name.toLowerCase().contains(_needle);
  }
}

/// A glyph that opens into a field, and closes again when left empty.
class EpisodeSearchButton extends StatefulWidget {
  const EpisodeSearchButton({super.key, this.height = 38});

  final double height;

  @override
  State<EpisodeSearchButton> createState() => _EpisodeSearchButtonState();
}

class _EpisodeSearchButtonState extends State<EpisodeSearchButton> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _controller.text = episodeSearchQuery.value;
    _open = _controller.text.isNotEmpty;
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// An empty field that has been left alone folds back into its glyph, so
  /// the toolbar does not keep a box nobody is using.
  void _onFocusChanged() {
    if (!_focusNode.hasFocus && _controller.text.isEmpty && _open) {
      setState(() => _open = false);
    }
  }

  void _close() {
    _controller.clear();
    episodeSearchQuery.value = '';
    setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = appText(
      context,
      english: 'Find an episode',
      arabic: 'ابحث عن حلقة',
    );

    return AppleLiquidGlassSurface(
      borderRadius: BorderRadius.circular(widget.height / 2),
      // No blur: this control sits below the artwork, on the page's own flat
      // background, where a blur costs a per-frame layer and returns a
      // blurred copy of one colour. The chips over the hero keep theirs.
      fallbackBlur: false,
      fallbackColor: kDetailsHeroGlassFallback,
      fallbackBorder: BorderSide(
        color: colors.onSurfaceVariant.withValues(alpha: 0.12),
      ),
      child: SizedBox(
        height: widget.height,
        child: _open
            ? _buildField(context, colors, label)
            : Tooltip(
                message: label,
                child: Semantics(
                  button: true,
                  label: label,
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () {
                        setState(() => _open = true);
                        _focusNode.requestFocus();
                      },
                      child: SizedBox.square(
                        dimension: widget.height,
                        child: Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildField(BuildContext context, ColorScheme colors, String label) {
    return SizedBox(
      width: 168,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.search_rounded, size: 17, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              // A number pad on a phone: the field is for episode numbers
              // first, and reaching one should not start with a keyboard of
              // letters.
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.search,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(24),
              ],
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: label,
                hintStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
              onChanged: (value) => episodeSearchQuery.value = value,
              onSubmitted: (_) => _focusNode.unfocus(),
            ),
          ),
          Tooltip(
            message: appText(context, english: 'Clear', arabic: 'مسح'),
            child: IconButton(
              onPressed: _close,
              iconSize: 17,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              icon: Icon(Icons.close_rounded, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
