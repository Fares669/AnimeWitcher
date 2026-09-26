import 'package:flutter/material.dart';

import '../../../../core/utils/layout_constants.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

/// A run of settings under a quiet heading, each setting a rounded tile of
/// its own with a little space between them.
///
/// The tiles carry their controls on the row — a switch, a value, a row of
/// choices underneath — so most settings change where they are read rather
/// than behind a dialog.
class SettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingsGroup({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                4,
                LayoutConstants.spacingLg,
                4,
                LayoutConstants.spacingSm,
              ),
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.75),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}

/// The colour of a settings tile: a step up from the page, taken from the
/// theme so each theme draws its own.
Color settingsTileColor(ColorScheme colors) =>
    Color.alphaBlend(colors.onSurface.withValues(alpha: 0.06), colors.surface);

/// A row of pill choices under a setting, one of them chosen — for settings
/// with a handful of values, picked where they are read.
class SettingsChoices<T> extends StatelessWidget {
  const SettingsChoices({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.swatch,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onSelected;

  /// A colour shown as a dot before each choice's name, as the themes have.
  final Color Function(T value)? swatch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          ChoiceChip(
            avatar: swatch == null
                ? null
                : _SwatchDot(color: swatch!(value), ring: colors.onSurface),
            label: Text(label(value)),
            selected: value == selected,
            onSelected: (_) => onSelected(value),
            showCheckmark: false,
            backgroundColor: colors.onSurface.withValues(alpha: 0.08),
            selectedColor: colors.primary,
            labelStyle: TextStyle(
              color: value == selected ? colors.onPrimary : colors.onSurface,
              fontWeight: FontWeight.w700,
            ),
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(99),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          ),
      ],
    );
  }
}

class _SwatchDot extends StatelessWidget {
  const _SwatchDot({required this.color, required this.ring});

  final Color color;
  final Color ring;

  @override
  Widget build(BuildContext context) => Container(
    width: 16,
    height: 16,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: ring.withValues(alpha: 0.35)),
    ),
  );
}

class SettingsTile extends StatefulWidget {
  final IconData icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isLast;
  final bool isBeta;
  final FocusNode? focusNode;

  /// Shown under the row inside the same tile: a row of choices, say, so a
  /// setting with a few values is picked where it is read.
  final Widget? below;

  const SettingsTile({
    super.key,
    required this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isLast = false,
    this.isBeta = false,
    this.focusNode,
    this.below,
  });

  @override
  State<SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<SettingsTile> {
  bool _isFocused = false;

  /// Longest a subtitle can be and still read as the setting's current value.
  ///
  /// "داكن", "10 ثانية", "3 دقيقة" are values and belong on the pill at the
  /// end of the row, where a column of them can be read down. A sentence
  /// explaining what a switch does is not a value and stays under its title,
  /// where it has the width to be read.
  static const int _valueLengthLimit = 28;

  bool get _showsValuePill {
    final subtitle = widget.subtitle?.trim();
    if (subtitle == null || subtitle.isEmpty) return false;
    // A row with its own control has its answer there already.
    if (widget.trailing != null) return false;
    return subtitle.length <= _valueLengthLimit && !subtitle.contains('\n');
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: settingsTileColor(Theme.of(context).colorScheme),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              // Passive observer — we want the inner ListTile's InkWell to remain
              // the actual focus target (it's what handles onTap when OK is
              // pressed). hasFocus on this node reflects "any descendant focused"
              // so onFocusChange still fires when the tile is reached.
              focusNode: widget.focusNode,
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (f) {
                setState(() => _isFocused = f);
                if (f) {
                  // Center the focused setting row in the viewport.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    final ctx = FocusManager.instance.primaryFocus?.context;
                    final ro = ctx?.findRenderObject();
                    if (ctx != null && ctx.mounted && ro != null) {
                      Scrollable.maybeOf(ctx)?.position.ensureVisible(
                        ro,
                        alignment: 0.5,
                        duration: const Duration(milliseconds: 380),
                        curve: Curves.fastOutSlowIn,
                      );
                    }
                  });
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _isFocused
                      ? primary.withValues(alpha: 0.22)
                      : Colors.transparent,
                  border: Border.all(
                    color: _isFocused ? primary : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ListTile(
                    focusColor: Colors.transparent,
                    hoverColor: primary.withValues(alpha: 0.10),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: LayoutConstants.spacingMd,
                      vertical: LayoutConstants.spacingXs,
                    ),
                    leading:
                        widget.leading ??
                        SizedBox.square(
                          dimension: 24,
                          child: Icon(widget.icon, color: primary, size: 21),
                        ),
                    minLeadingWidth: 24,
                    title: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            widget.title,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: onSurface,
                                ),
                          ),
                        ),
                        if (widget.isBeta) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary
                                  .withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              appText(
                                context,
                                english: 'BETA',
                                arabic: 'تجريبي',
                              ),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: _showsValuePill
                        ? null
                        : widget.subtitle != null
                        ? Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              widget.subtitle!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    height: 1.35,
                                  ),
                            ),
                          )
                        : null,
                    trailing: _showsValuePill
                        ? _ValuePill(text: widget.subtitle!)
                        : widget.trailing ??
                              Icon(
                                Directionality.of(context) == TextDirection.rtl
                                    ? Icons.chevron_left_rounded
                                    : Icons.chevron_right_rounded,
                                size: 20,
                              ),
                    onTap: widget.onTap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.below case final below?)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(56, 0, 16, 14),
                child: below,
              ),
          ],
        ),
      ),
    );
  }
}

/// A setting's current value, at the end of its row.
class _ValuePill extends StatelessWidget {
  const _ValuePill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 168),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: colors.onSurface.withValues(alpha: 0.85)),
      ),
    );
  }
}
