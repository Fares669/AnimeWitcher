import 'package:flutter/material.dart';

import '../../../../core/extensions/base_provider.dart';

/// One of the main categories the sheet can switch between, such as anime
/// or manga, shown in its header.
class ProviderSearchFilterCategory {
  final String value;
  final String label;
  final IconData icon;

  /// Said where the tabs would be when this category has nothing to
  /// filter by; null says just that.
  final String? noFiltersNote;

  const ProviderSearchFilterCategory({
    required this.value,
    required this.label,
    required this.icon,
    this.noFiltersNote,
  });
}

class ProviderSearchFilterDialog extends StatefulWidget {
  final ProviderSearchFilterOptions options;
  final ProviderSearchFilters initialValue;

  /// The main categories, picked in the header. Without them the sheet
  /// filters the one list it was opened for.
  final List<ProviderSearchFilterCategory> categories;

  /// Which of [categories] [options] belongs to.
  final String? category;

  /// The filters a category offers, loaded when it is picked. A category
  /// with none shows a note instead of the tabs.
  final Future<ProviderSearchFilterOptions> Function(String category)?
  optionsFor;

  /// Told the chosen category when Apply is pressed.
  final ValueChanged<String>? onCategoryApplied;

  const ProviderSearchFilterDialog({
    super.key,
    required this.options,
    required this.initialValue,
    this.categories = const <ProviderSearchFilterCategory>[],
    this.category,
    this.optionsFor,
    this.onCategoryApplied,
    this.asSheet = false,
  });

  /// Shown by [showProviderSearchFilterSheet]: the whole screen, risen from
  /// the bottom, with a handle to drag it back down.
  final bool asSheet;

  @override
  State<ProviderSearchFilterDialog> createState() =>
      _ProviderSearchFilterDialogState();
}

class _ProviderSearchFilterDialogState
    extends State<ProviderSearchFilterDialog> {
  late Set<String> _statuses;
  late Set<String> _types;
  late Set<String> _ageRatings;
  late Set<String> _years;
  late Set<String> _seasons;
  late Set<String> _genres;
  String? _category;
  bool _allYears = false;
  final Map<String, Future<ProviderSearchFilterOptions>> _optionsByCategory =
      {};

  /// Years shown before "more": the list runs back decades.
  static const int _yearsShown = 5;

  bool get _isArabic =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  String _t(String english, String arabic) => _isArabic ? arabic : english;

  bool get _seasonRequiresYear => _seasons.isNotEmpty && _years.isEmpty;

  @override
  void initState() {
    super.initState();
    _statuses = {...widget.initialValue.statuses};
    _types = {...widget.initialValue.types};
    _ageRatings = {...widget.initialValue.ageRatings};
    _years = {...widget.initialValue.years};
    _seasons = {...widget.initialValue.seasons};
    _genres = {...widget.initialValue.genres};
    _category = widget.category;
    if (_category != null) {
      _optionsByCategory[_category!] = Future.value(widget.options);
    }
  }

  Future<ProviderSearchFilterOptions> _optionsOf(String category) =>
      _optionsByCategory.putIfAbsent(
        category,
        () =>
            widget.optionsFor?.call(category) ??
            Future.value(const ProviderSearchFilterOptions()),
      );

  void _pickCategory(String category) {
    if (category == _category) return;
    setState(() => _category = category);
  }

  void _apply() {
    final category = _category;
    if (category != null) widget.onCategoryApplied?.call(category);
    Navigator.of(context).pop(_value);
  }

  void _toggle(Set<String> target, String value) {
    setState(() {
      if (!target.add(value)) target.remove(value);
    });
  }

  void _toggleSeason(String value) {
    setState(() {
      if (_seasons.contains(value)) {
        _seasons.clear();
      } else {
        _seasons
          ..clear()
          ..add(value);
      }
    });
  }

  void _clearAll() {
    setState(() {
      _statuses.clear();
      _types.clear();
      _ageRatings.clear();
      _years.clear();
      _seasons.clear();
      _genres.clear();
    });
  }

  /// The filters of the category on screen, once they have loaded.
  ProviderSearchFilterOptions? _shownOptions;

  /// What is chosen, kept to what the category on screen offers: choices
  /// carried over from another category (an anime type, say, on manga)
  /// would otherwise filter out everything while showing nowhere.
  ProviderSearchFilters get _value {
    final options = _shownOptions;
    Set<String> keep(Set<String> chosen, List<String>? offered) =>
        offered == null ? {...chosen} : chosen.where(offered.contains).toSet();
    return ProviderSearchFilters(
      statuses: keep(_statuses, options?.statuses),
      types: keep(_types, options?.types),
      ageRatings: keep(_ageRatings, options?.ageRatings),
      years: keep(_years, options?.years),
      seasons: keep(_seasons, options?.seasons),
      genres: keep(_genres, options?.genres),
      sort: widget.initialValue.sort,
    );
  }

  /// Back on the left, the title between, reset on the right — in either
  /// reading direction.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final count = _value.count;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: EdgeInsets.fromLTRB(4, widget.asSheet ? 14 : 4, 6, 2),
        // The title sits in the middle of the sheet, whatever the widths of
        // the buttons either side of it.
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 100),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      _t('Search filters', 'فلاتر البحث'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(50),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          color: colors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Row(
              children: [
                IconButton(
                  key: const ValueKey<String>('filterBack'),
                  tooltip: _t('Back', 'رجوع'),
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                TextButton(
                  key: const ValueKey<String>('filterReset'),
                  onPressed: _value.isEmpty ? null : _clearAll,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.error,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Text(
                    _t('Reset', 'إعادة الضبط'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The main categories as one row of pills sharing the width, all in view
  /// at once; on a narrow phone the icons go so the names keep their room.
  Widget _categoryStrip(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final count = widget.categories.length;
    return Padding(
      key: const ValueKey<String>('filterCategoryStrip'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final each = (constraints.maxWidth - 4 * (count - 1)) / count;
          final icons = each >= 78;
          return Row(
            children: [
              for (var i = 0; i < count; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: _CategoryPill(
                    key: ValueKey<String>(
                      'filterCategory-${widget.categories[i].value}',
                    ),
                    category: widget.categories[i],
                    selected: widget.categories[i].value == _category,
                    accent: colors.primary,
                    showIcon: icons,
                    onTap: () => _pickCategory(widget.categories[i].value),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// A category with nothing to filter says so where the cards would be.
  Widget _noFiltersNote(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    String? note;
    for (final category in widget.categories) {
      if (category.value == _category) note = category.noFiltersNote;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_off_outlined,
              size: 40,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              note ??
                  _t('This section has no filters', 'لا توجد فلاتر لهذا القسم'),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// The small groups two to a row where there is room, then year and
  /// genres the full width: their lists are long.
  Widget _cards(BuildContext context, ProviderSearchFilterOptions options) {
    final small = <Widget>[
      if (options.statuses.isNotEmpty)
        _FilterCard(
          key: const ValueKey<String>('filterCard-status'),
          title: _t('Status', 'الحالة'),
          child: _ChipWrap(
            values: options.statuses,
            selected: _statuses,
            onToggle: (value) => _toggle(_statuses, value),
          ),
        ),
      if (options.types.isNotEmpty)
        _FilterCard(
          key: const ValueKey<String>('filterCard-type'),
          title: _t('Type', 'النوع'),
          child: _ChipWrap(
            values: options.types,
            selected: _types,
            onToggle: (value) => _toggle(_types, value),
          ),
        ),
      if (options.seasons.isNotEmpty)
        _FilterCard(
          key: const ValueKey<String>('filterCard-season'),
          title: _t('Season', 'الموسم'),
          note: _seasonRequiresYear
              ? _t('Choose a year with the season', 'اختر سنة مع الموسم')
              : null,
          child: _ChipWrap(
            values: options.seasons,
            selected: _seasons,
            onToggle: _toggleSeason,
          ),
        ),
      if (options.ageRatings.isNotEmpty)
        _FilterCard(
          key: const ValueKey<String>('filterCard-age'),
          title: _t('Age rating', 'التصنيف العمري'),
          child: _ChipWrap(
            values: options.ageRatings,
            selected: _ageRatings,
            onToggle: (value) => _toggle(_ageRatings, value),
          ),
        ),
    ];
    final years = _allYears
        ? options.years
        : options.years.take(_yearsShown).toList(growable: false);
    // Years picked beyond the first few stay in view.
    final shownYears = <String>[
      ...years,
      for (final year in _years)
        if (!years.contains(year) && options.years.contains(year)) year,
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // The list's own padding comes off the width first.
        final width = constraints.maxWidth - 24;
        final twoColumns = width >= 330;
        return ListView(
          key: const ValueKey<String>('filterCards'),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          children: [
            // Two to a row, each pair as tall as its taller card, so no
            // gap opens under the shorter one.
            if (twoColumns)
              for (var i = 0; i < small.length; i += 2)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: i + 2 < small.length ? 8 : 0,
                  ),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: small[i]),
                        const SizedBox(width: 8),
                        Expanded(
                          child: i + 1 < small.length
                              ? small[i + 1]
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                )
            else
              for (final card in small)
                Padding(padding: const EdgeInsets.only(bottom: 8), child: card),
            if (options.years.isNotEmpty) ...[
              const SizedBox(height: 8),
              _FilterCard(
                key: const ValueKey<String>('filterCard-year'),
                title: _t('Release year', 'سنة الإصدار'),
                multiple: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Five years to a row, the newest five first.
                    AnimatedSize(
                      key: const ValueKey<String>(
                        'filter-year-size-transition',
                      ),
                      duration: const Duration(milliseconds: 240),
                      reverseDuration: const Duration(milliseconds: 190),
                      curve: Curves.easeOutCubic,
                      alignment: AlignmentDirectional.topStart,
                      clipBehavior: Clip.hardEdge,
                      child: _ChipWrap(
                        values: shownYears,
                        selected: _years,
                        columns: _yearsShown,
                        onToggle: (value) => _toggle(_years, value),
                      ),
                    ),
                    if (options.years.length > _yearsShown)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 34),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              setState(() => _allYears = !_allYears),
                          child: Text(
                            _allYears
                                ? _t('Show less', 'عرض أقل')
                                : _t('Show more', 'عرض المزيد'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (options.genres.isNotEmpty) ...[
              const SizedBox(height: 8),
              _FilterCard(
                key: const ValueKey<String>('filterCard-genres'),
                title: _t('Genres', 'التصنيفات'),
                multiple: true,
                child: _ChipWrap(
                  values: options.genres,
                  selected: _genres,
                  onToggle: (value) => _toggle(_genres, value),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The big Apply bar along the bottom.
  Widget _applyBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final count = _value.count;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            key: const ValueKey<String>('filterApply'),
            onPressed: _seasonRequiresYear ? null : _apply,
            style: FilledButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: colors.onPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              count > 0
                  ? '${_t('Apply', 'تطبيق')} ($count)'
                  : _t('Apply', 'تطبيق'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    // A phone gets the whole screen; anything larger a tall window.
    final phone = viewport.shortestSide < 600;

    final body = Material(
      color: colors.surface,
      child: FutureBuilder<ProviderSearchFilterOptions>(
        // Picking a category loads its filters once; the cards wait for
        // them rather than showing the last category's.
        key: ValueKey<String?>(_category),
        future: _category == null
            ? Future.value(widget.options)
            : _optionsOf(_category!),
        initialData: _category == null || _category == widget.category
            ? widget.options
            : null,
        builder: (context, snapshot) {
          final options = snapshot.data;
          if (options != null) _shownOptions = options;
          final loading =
              options == null &&
              snapshot.connectionState != ConnectionState.done;
          final hasFilters = options != null && !options.isEmpty;
          return SafeArea(
            bottom: false,
            child: Column(
              children: [
                _header(context),
                if (widget.categories.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _categoryStrip(context),
                  ),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : hasFilters
                      ? _cards(context, options)
                      : _noFiltersNote(context),
                ),
                _applyBar(context),
              ],
            ),
          );
        },
      ),
    );

    if (widget.asSheet) {
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Stack(
          children: [
            body,
            // The handle, over the space above the header.
            PositionedDirectional(
              top: MediaQuery.paddingOf(context).top + 4,
              start: 0,
              end: 0,
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (phone) return Dialog.fullscreen(child: body);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: (viewport.height * 0.86).clamp(320.0, 900.0),
        ),
        child: body,
      ),
    );
  }
}

/// Opens the filters as a phone's sheet: up from the bottom to fill the
/// screen, dragged or swiped back down to close, as the library's filters.
/// [builder] gives the [ProviderSearchFilterDialog], with `asSheet` set.
Future<ProviderSearchFilters?> showProviderSearchFilterSheet({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final media = MediaQuery.of(context);
  final height = media.size.height - media.padding.top;
  return showModalBottomSheet<ProviderSearchFilters>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    constraints: const BoxConstraints(),
    builder: (context) => SizedBox(height: height, child: builder(context)),
  );
}

/// One group of choices on its own card, a title above, "multiple" beside
/// it where several can be picked.
class _FilterCard extends StatelessWidget {
  const _FilterCard({
    super.key,
    required this.title,
    required this.child,
    this.multiple = false,
    this.note,
  });

  final String title;
  final Widget child;
  final bool multiple;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final arabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (multiple) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(50),
                  ),
                  child: Text(
                    arabic ? 'متعدد' : 'Multiple',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          child,
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(
              note!,
              style: TextStyle(
                fontSize: 12,
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Choices as pills that wrap onto as many lines as they need.
class _ChipWrap extends StatelessWidget {
  const _ChipWrap({
    required this.values,
    required this.selected,
    required this.onToggle,
    this.columns,
  });

  final List<String> values;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  /// Equal-width rows of this many instead of wrapping by length.
  final int? columns;

  static const double _gap = 6;

  Widget _chip(BuildContext context, String value) {
    final colors = Theme.of(context).colorScheme;
    final on = selected.contains(value);
    return Material(
      key: ValueKey<String>('filterChip-$value'),
      color: on
          ? colors.primary.withValues(alpha: 0.18)
          : colors.surfaceContainerHighest,
      shape: StadiumBorder(
        side: BorderSide(
          color: on
              ? colors.primary.withValues(alpha: 0.6)
              : Colors.transparent,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => onToggle(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Text(
            value,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              color: on ? colors.primary : colors.onSurface,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final perRow = columns;
    if (perRow == null) {
      return Wrap(
        spacing: _gap,
        runSpacing: _gap,
        children: [for (final value in values) _chip(context, value)],
      );
    }
    return Column(
      children: [
        for (var i = 0; i < values.length; i += perRow)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : _gap),
            child: Row(
              children: [
                for (var j = i; j < i + perRow; j++) ...[
                  if (j > i) const SizedBox(width: _gap),
                  Expanded(
                    child: j < values.length
                        ? _chip(context, values[j])
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _CategoryPill extends StatelessWidget {
  final ProviderSearchFilterCategory category;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;
  final bool showIcon;

  const _CategoryPill({
    super.key,
    required this.category,
    required this.selected,
    required this.accent,
    required this.onTap,
    this.showIcon = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? accent : colors.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? accent.withValues(alpha: 0.16)
            : colors.onSurface.withValues(alpha: 0.05),
        shape: StadiumBorder(
          side: BorderSide(
            color: selected
                ? accent.withValues(alpha: 0.55)
                : colors.onSurfaceVariant.withValues(alpha: 0.14),
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            // A long name shrinks to fit rather than pushing the row wider.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showIcon) ...[
                    Icon(category.icon, size: 15, color: foreground),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    category.label,
                    maxLines: 1,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
