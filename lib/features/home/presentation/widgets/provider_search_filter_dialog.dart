import 'package:flutter/material.dart';

import '../../../../shared/widgets/apple_liquid_glass.dart';

import '../../../../core/extensions/base_provider.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';

class ProviderSearchFilterDialog extends StatefulWidget {
  final ProviderSearchFilterOptions options;
  final ProviderSearchFilters initialValue;

  const ProviderSearchFilterDialog({
    super.key,
    required this.options,
    required this.initialValue,
  });

  @override
  State<ProviderSearchFilterDialog> createState() =>
      _ProviderSearchFilterDialogState();
}

class _ProviderSearchFilterDialogState extends State<ProviderSearchFilterDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late Set<String> _statuses;
  late Set<String> _types;
  late Set<String> _ageRatings;
  late Set<String> _years;
  late Set<String> _seasons;
  late Set<String> _genres;

  bool get _isArabic =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  bool get _seasonRequiresYear => _seasons.isNotEmpty && _years.isEmpty;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _statuses = {...widget.initialValue.statuses};
    _types = {...widget.initialValue.types};
    _ageRatings = {...widget.initialValue.ageRatings};
    _years = {...widget.initialValue.years};
    _seasons = {...widget.initialValue.seasons};
    _genres = {...widget.initialValue.genres};
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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

  ProviderSearchFilters get _value => ProviderSearchFilters(
    statuses: {..._statuses},
    types: {..._types},
    ageRatings: {..._ageRatings},
    years: {..._years},
    seasons: {..._seasons},
    genres: {..._genres},
    sort: widget.initialValue.sort,
  );

  List<_FilterTabSpec> get _tabs => [
    _FilterTabSpec(
      icon: Icons.local_offer_outlined,
      label: _isArabic ? 'التصنيفات' : 'Genres',
      active: _genres.isNotEmpty,
    ),
    _FilterTabSpec(
      icon: Icons.calendar_today_outlined,
      label: _isArabic ? 'السنة' : 'Year',
      active: _years.isNotEmpty || _seasons.isNotEmpty,
    ),
    _FilterTabSpec(
      icon: Icons.shield_outlined,
      label: _isArabic ? 'العمر' : 'Age',
      active: _ageRatings.isNotEmpty,
    ),
    _FilterTabSpec(
      icon: Icons.category_outlined,
      label: _isArabic ? 'النوع' : 'Type',
      active: _types.isNotEmpty,
    ),
    _FilterTabSpec(
      icon: Icons.wifi_tethering_rounded,
      label: _isArabic ? 'الحالة' : 'Status',
      active: _statuses.isNotEmpty,
    ),
  ];

  List<Widget> _optionViews({required bool compactLandscape}) {
    final genreColumns = compactLandscape ? 5 : 3;
    final pairColumns = compactLandscape ? 4 : 2;
    return [
      _MultiSelectGrid(
        values: widget.options.genres,
        selected: _genres,
        onToggle: (value) => _toggle(_genres, value),
        crossAxisCount: genreColumns,
        compact: true,
        dense: compactLandscape,
      ),
      _SeasonYearGrid(
        seasons: widget.options.seasons,
        years: widget.options.years,
        selectedSeasons: _seasons,
        selectedYears: _years,
        onSeasonToggle: _toggleSeason,
        onYearToggle: (value) => _toggle(_years, value),
        crossAxisCount: compactLandscape ? 5 : 4,
        dense: compactLandscape,
      ),
      _MultiSelectGrid(
        values: widget.options.ageRatings,
        selected: _ageRatings,
        onToggle: (value) => _toggle(_ageRatings, value),
        crossAxisCount: pairColumns,
        dense: compactLandscape,
      ),
      _MultiSelectGrid(
        values: widget.options.types,
        selected: _types,
        onToggle: (value) => _toggle(_types, value),
        crossAxisCount: pairColumns,
        dense: compactLandscape,
      ),
      _MultiSelectGrid(
        values: widget.options.statuses,
        selected: _statuses,
        onToggle: (value) => _toggle(_statuses, value),
        crossAxisCount: pairColumns,
        dense: compactLandscape,
      ),
    ];
  }

  Widget _header(BuildContext context, {required bool compact}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 20,
        compact ? 8 : 20,
        compact ? 4 : 8,
        compact ? 8 : 20,
      ),
      child: Row(
        children: [
          Icon(
            Icons.tune_rounded,
            color: colors.primary,
            size: compact ? 22 : 28,
          ),
          const SizedBox(width: LayoutConstants.spacingSm),
          Expanded(
            child: Text(
              _isArabic ? 'فلاتر البحث' : 'Search filters',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  (compact
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.headlineSmall)
                      ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          if (_value.isNotEmpty)
            Container(
              margin: const EdgeInsetsDirectional.only(end: 4),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Text(
                '${_value.count}',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
            visualDensity: compact
                ? VisualDensity.compact
                : VisualDensity.standard,
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : LayoutConstants.spacingMd,
        compact ? 6 : LayoutConstants.spacingMd,
        compact ? 12 : LayoutConstants.spacingMd,
        compact ? 8 : LayoutConstants.spacingMd,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_seasonRequiresYear)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _isArabic
                          ? 'اختر سنة مع الموسم'
                          : 'Choose a year with the season',
                      style: TextStyle(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Flexible(
                child: TextButton.icon(
                  onPressed: _value.isEmpty ? null : _clearAll,
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: Text(
                    _isArabic ? 'مسح الكل' : 'Clear all',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _seasonRequiresYear
                      ? null
                      : () => Navigator.of(context).pop(_value),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                    padding: EdgeInsets.symmetric(vertical: compact ? 10 : 16),
                    minimumSize: Size(0, compact ? 40 : 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _isArabic ? 'تطبيق' : 'Apply',
                    style: TextStyle(
                      fontSize: compact ? 14 : 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _horizontalTabs(BuildContext context, {required bool spread}) {
    final colors = Theme.of(context).colorScheme;
    return TabBar(
      controller: _tabController,
      isScrollable: !spread,
      tabAlignment: spread ? TabAlignment.fill : TabAlignment.start,
      indicatorColor: colors.primary,
      labelColor: colors.primary,
      unselectedLabelColor: colors.onSurfaceVariant,
      labelPadding: spread ? const EdgeInsets.symmetric(horizontal: 4) : null,
      tabs: [
        for (final tab in _tabs)
          _FilterTab(icon: tab.icon, label: tab.label, active: tab.active),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final isHandsetLandscape = context.isHandsetLandscape;
    final insetH = isHandsetLandscape ? 12.0 : 16.0;
    // Landscape phones have little vertical room; use a tight inset so the
    // sheet can grow into the empty bands above and below instead of sitting
    // as a short strip in the middle.
    final insetV = isHandsetLandscape ? 4.0 : 28.0;
    final availableHeight = (viewport.height - insetV * 2)
        .clamp(160.0, 720.0)
        .toDouble();
    final dialogHeight = isHandsetLandscape
        ? availableHeight
        : (viewport.height * 0.82).clamp(180.0, availableHeight).toDouble();
    final maxWidth = isHandsetLandscape
        ? (viewport.width - insetH * 2).clamp(280.0, 840.0)
        : 560.0;

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: insetH, vertical: insetV),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(
          width: double.infinity,
          height: dialogHeight,
          child: AppleLiquidGlassSurface(
            borderRadius: BorderRadius.circular(isHandsetLandscape ? 20 : 28),
            style: 'regular',
            interactive: true,
            fallbackColor: colors.surfaceContainerHigh.withValues(alpha: 0.96),
            fallbackBorder: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.34),
            ),
            child: Material(
              color: Colors.transparent,
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: theme.dividerColor),
                      ),
                    ),
                    child: Column(
                      children: [
                        _header(context, compact: isHandsetLandscape),
                        _horizontalTabs(context, spread: isHandsetLandscape),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: _optionViews(
                        compactLandscape: isHandsetLandscape,
                      ),
                    ),
                  ),
                  _footer(context, compact: isHandsetLandscape),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterTabSpec {
  final IconData icon;
  final String label;
  final bool active;

  const _FilterTabSpec({
    required this.icon,
    required this.label,
    required this.active,
  });
}

class _FilterTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;

  const _FilterTab({
    required this.icon,
    required this.label,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Tab(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 18),
                if (active)
                  const Positioned(
                    right: -3,
                    top: -3,
                    child: CircleAvatar(
                      radius: 4,
                      backgroundColor: Colors.redAccent,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 5),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _SeasonYearGrid extends StatelessWidget {
  final List<String> seasons;
  final List<String> years;
  final Set<String> selectedSeasons;
  final Set<String> selectedYears;
  final ValueChanged<String> onSeasonToggle;
  final ValueChanged<String> onYearToggle;
  final int crossAxisCount;
  final bool dense;

  const _SeasonYearGrid({
    required this.seasons,
    required this.years,
    required this.selectedSeasons,
    required this.selectedYears,
    required this.onSeasonToggle,
    required this.onYearToggle,
    this.crossAxisCount = 4,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final values = <String>[...seasons, ...years];

    return GridView.builder(
      padding: EdgeInsets.all(dense ? 8 : LayoutConstants.spacingMd),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: dense ? 3.2 : 1.85,
        crossAxisSpacing: dense ? 6 : 8,
        mainAxisSpacing: dense ? 6 : 10,
      ),
      itemCount: values.length,
      itemBuilder: (context, index) {
        final isSeason = index < seasons.length;
        final value = values[index];
        final isSelected = isSeason
            ? selectedSeasons.contains(value)
            : selectedYears.contains(value);

        return InkWell(
          onTap: () => isSeason ? onSeasonToggle(value) : onYearToggle(value),
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected
                  ? colors.primary.withValues(alpha: 0.2)
                  : colors.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected
                    ? colors.primary
                    : colors.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 17,
                  color: isSelected
                      ? colors.primary
                      : colors.onSurfaceVariant.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: isSelected ? colors.primary : colors.onSurface,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MultiSelectGrid extends StatelessWidget {
  final List<String> values;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final int crossAxisCount;
  final bool compact;
  final bool dense;

  const _MultiSelectGrid({
    required this.values,
    required this.selected,
    required this.onToggle,
    required this.crossAxisCount,
    this.compact = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return GridView.builder(
      padding: EdgeInsets.all(dense ? 8 : LayoutConstants.spacingMd),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: dense
            ? (compact ? 3.4 : 3.8)
            : (compact ? 2.05 : 2.5),
        crossAxisSpacing: dense ? 6 : 10,
        mainAxisSpacing: dense ? 6 : 10,
      ),
      itemCount: values.length,
      itemBuilder: (context, index) {
        final value = values[index];
        final isSelected = selected.contains(value);

        return InkWell(
          onTap: () => onToggle(value),
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected
                  ? colors.primary.withValues(alpha: 0.2)
                  : colors.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected
                    ? colors.primary
                    : colors.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: compact ? 17 : 19,
                  color: isSelected
                      ? colors.primary
                      : colors.onSurfaceVariant.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 11.5 : 13,
                      color: isSelected ? colors.primary : colors.onSurface,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
